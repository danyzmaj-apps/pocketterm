// The push relay: the one service that can reach Apple's push service and
// Firebase Cloud Messaging for PocketTerm, because it holds the publisher's APNs
// key and Firebase service account. Every PocketTerm server sends its pushes
// through it. A notification's text was sealed on the user's computer with that
// computer's channel key, which only the phones that scanned its code hold; the
// whole request is sealed again to the relay's own key (seal.ts), so the network
// between a server and the relay sees only ciphertext.
//
// POST /v1/push with a sealed body {v: 1, epk, n, c}; opened, it is one of:
//
// iPhones (APNs; no platform field):
//   {"token": hex, "kind": "terminal", "enc": base64, "desktop"?: computer id, "collapse"?: string}
//   {"token": hex, "kind": "liveactivity", "event": "update"|"end",
//    "state": {"state": "working"|"needs"|"done"|"ended", "since": unix seconds,
//              "kind"?: "question"|"approval"|"plan"}}
// Android phones (FCM HTTP v1, a data-only message the app shows itself):
//   {"platform": "android", "token": FCM registration token,
//    "kind": "terminal", "enc": base64, "desktop"?: computer id, "collapse"?: string}
//   {"platform": "android", "token": FCM registration token,
//    "kind": "activity", "enc": base64 (the state, sealed by the computer), "desktop": computer id, "collapse"?: string}
//   {"platform": "android", "token": FCM registration token,
//    "kind": "activity", "session": coding session key, "state": {"state": "ended", "since"}, "collapse"?: string}
//    (an end, which the server sends when the computer has gone quiet and can't seal it)
//   → 200 sent · 410 the phone is gone (uninstalled, signed out): forget it ·
//     429 over a rate limit (Retry-After) · 501 FCM not configured here · 4xx/5xx otherwise
//
// The phone opens enc with the key of the computer named by desktop (d in the
// push); without one it shows a generic "PocketTerm" alert.
//
// Trust: any caller may use it (self-hosted servers have no credentials of the
// publisher's), so whoever knows a device token can make that phone show a
// generic "PocketTerm" alert, or move or end one of its Live Activities, and
// nothing more: the real text needs the key only the user's computer and phones
// hold. Rate limits (limits.ts) keep floods cheap: per caller address, per
// device token, and fewer still for a caller whose tokens keep turning out
// unknown or malformed.
//
// An iPhone's Live Activity push (a coding session on the Lock Screen) can't
// be encrypted: the iPhone's notification extension never sees it. So it
// carries only a state, rebuilt here from checked fields, never anything
// passed through. An Android phone's comes sealed by the computer, except a
// plain end, which says nothing but that the session is over.
//
// Stores nothing; never logs a token, an address or a body.

import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { encodeBase64Url } from "jsr:@std/encoding@1/base64url";
import {
  assertion,
  exchange,
  type FcmData,
  fcmGone,
  fcmMessage,
  fcmToken,
  importPrivateKey,
  parseServiceAccount,
  type ServiceAccount,
} from "./fcm.ts";
import { callerOf, Keyer, relayLimits } from "./limits.ts";
import { type RelayKey, unseal } from "./seal.ts";

export type Config = {
  /** The APNs .p8's contents (PEM). */
  apnsKey: string;
  apnsKeyId: string;
  apnsTeamId: string;
  /** The app's bundle id. */
  apnsTopic: string;
  /** The Firebase service account's JSON; without it Android pushes answer 501. */
  fcmServiceAccount?: string;
  /** The relay's own key pair, which senders seal their requests to. */
  key: RelayKey;
};

/** What one push came to, for metrics and the log: never the token or the body. */
export type Outcome = { platform: "ios" | "android" | "none"; status: number };

export type Push = (req: Request) => Promise<{ res: Response; outcome: Outcome }>;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const tooMany = () =>
  new Response(JSON.stringify({ error: "Too many pushes; try again in a minute" }), {
    status: 429,
    headers: { "content-type": "application/json", "retry-after": "60" },
  });

// FCM takes 4 KB of data in all; APNs 4 KB of payload.
const maxEnc = 3000;
// The sealed request: the largest plain body (an FCM token is up to 4 KB, plus enc) and base64's growth.
const maxSealed = 16_384;

// What shows if the phone can't open it (a computer whose code it never
// scanned, or a key reset since): no content.
const fallback = "Terminal";

const activityStates = ["working", "needs", "done", "ended"];
const activityKinds = ["question", "approval", "plan"];

/** The relay's POST /v1/push handler for [config]. */
export function relay(config: Config): Push {
  const limits = relayLimits();
  // Rate-limit keys are HMACs under a random salt that changes every day: the
  // counters never hold an address or a token, and yesterday's can't be linked to today's.
  const keyer = new Keyer();

  // The .p8 is PEM: base64 PKCS#8 between the BEGIN/END lines.
  const signingKey = crypto.subtle.importKey(
    "pkcs8",
    decodeBase64(config.apnsKey.replace(/-----[A-Z ]+-----/g, "").replace(/\s/g, "")),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  // Keep a bad key from becoming an unhandled rejection before the first push awaits it.
  signingKey.catch(() => {});

  // Apple wants a fresh provider token at most hourly and at least every 20 min
  // apart; one per 40 min, reused across requests.
  let jwt: { token: string; at: number } | null = null;

  async function providerToken(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (jwt && now - jwt.at < 40 * 60) return jwt.token;
    const part = (o: unknown) => encodeBase64Url(new TextEncoder().encode(JSON.stringify(o)));
    const unsigned = `${part({ alg: "ES256", kid: config.apnsKeyId })}.${part({ iss: config.apnsTeamId, iat: now })}`;
    const sig = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await signingKey,
      new TextEncoder().encode(unsigned),
    );
    const token = `${unsigned}.${encodeBase64Url(new Uint8Array(sig))}`;
    jwt = { token, at: now };
    return token;
  }

  // Google's access tokens last an hour; one per 50 min, reused.
  let fcm: { sa: ServiceAccount; key: CryptoKey; token?: string; until?: number } | null = null;

  /** The service account and a live access token, or what's missing (a 501). */
  type FcmAccess = { sa: ServiceAccount; token: string } | string;

  async function fcmAccess(): Promise<FcmAccess> {
    if (!fcm) {
      if (!config.fcmServiceAccount) return "FCM is not configured: this relay can't reach Android phones";
      const sa = parseServiceAccount(config.fcmServiceAccount);
      if (typeof sa === "string") return sa;
      fcm = { sa, key: await importPrivateKey(sa.private_key) };
    }
    const now = Math.floor(Date.now() / 1000);
    if (!fcm.token || !fcm.until || now >= fcm.until) {
      const got = await exchange(await assertion(fcm.sa, fcm.key, now));
      fcm.token = got.token;
      fcm.until = now + Math.min(50 * 60, got.expiresIn - 60);
    }
    return { sa: fcm.sa, token: fcm.token };
  }

  /** Counts a push to [token]; false once that device had its share this minute. */
  async function tokenAllowed(token: string): Promise<boolean> {
    return limits.token.take(await keyer.key(token));
  }

  /** An Android phone's push, through FCM. */
  async function android(body: Record<string, unknown>): Promise<Response> {
    if (!fcmToken(body.token)) return json(400, { error: "token must be an FCM registration token" });
    let data: FcmData;
    if (body.kind === "terminal") {
      const alert = sealedAlert(body);
      if (typeof alert === "string") return json(400, { error: alert });
      data = { kind: "terminal", ...alert };
    } else if (body.kind === "activity" && body.enc !== undefined) {
      // A followed session's state, sealed by the computer like an alert: the phone opens it with that computer's key.
      const sealed = sealedAlert(body);
      if (typeof sealed === "string") return json(400, { error: sealed });
      if (!sealed.d) return json(400, { error: "desktop must be the computer id whose key opens enc" });
      data = { kind: "activity", ...sealed };
    } else if (body.kind === "activity") {
      if (typeof body.session !== "string" || !/^[\w.:/-]{1,64}$/.test(body.session)) {
        return json(400, { error: "session must be a coding session key" });
      }
      const s = activityState(body.state);
      if (typeof s === "string") return json(400, { error: s });
      // Anything but an end goes sealed (enc).
      if (s.state !== "ended") return json(400, { error: "an Android session update must be sealed (enc)" });
      // FCM data is strings only; the app takes since in ms.
      data = { kind: "activity", session: body.session, state: s.state, since: String(s.since * 1000) };
    } else {
      return json(400, { error: "kind must be terminal or activity" });
    }
    const collapse = typeof body.collapse === "string" && body.collapse.length <= 64 ? body.collapse : undefined;
    if (!(await tokenAllowed(body.token))) return tooMany();

    let access: FcmAccess;
    try {
      access = await fcmAccess();
    } catch (e) {
      return json(502, { error: `${e instanceof Error ? e.message : e}` });
    }
    if (typeof access === "string") return json(501, { error: access });
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${access.sa.project_id}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${access.token}`, "content-type": "application/json" },
      body: JSON.stringify(fcmMessage(body.token, data, collapse)),
    });
    if (res.ok) return json(200, { ok: true });
    const answer: unknown = await res.json().catch(() => null);
    // A token Google no longer takes: the next request mints a new one.
    if (res.status === 401 && fcm) fcm.token = undefined;
    if (fcmGone(res.status, answer)) return json(410, { gone: true });
    return json(502, { error: `FCM ${res.status}` });
  }

  /** An iPhone's push, through APNs. */
  async function ios(body: Record<string, unknown>): Promise<Response> {
    const live = body.kind === "liveactivity";
    // A Live Activity's token is longer than a device's.
    if (typeof body.token !== "string" || !new RegExp(`^[0-9a-f]{64,${live ? 400 : 200}}$`).test(body.token)) {
      return json(400, { error: "token must be an APNs device token" });
    }

    let payload: string;
    const headers: Record<string, string> = {};
    if (live) {
      const push = liveActivity(body);
      if (typeof push === "string") return json(400, { error: push });
      payload = push.payload;
      headers["apns-topic"] = `${config.apnsTopic}.push-type.liveactivity`;
      headers["apns-push-type"] = "liveactivity";
      headers["apns-priority"] = push.priority;
    } else {
      if (body.kind !== "terminal") return json(400, { error: "kind must be terminal or liveactivity" });
      const alert = sealedAlert(body);
      if (typeof alert === "string") return json(400, { error: alert });
      payload = JSON.stringify({
        aps: {
          alert: { title: "PocketTerm", body: fallback },
          sound: "default",
          // The iPhone's notification extension opens enc into the real text.
          "mutable-content": 1,
        },
        ...alert,
      });
      headers["apns-topic"] = config.apnsTopic;
      headers["apns-push-type"] = "alert";
      headers["apns-priority"] = "10";
      if (typeof body.collapse === "string" && body.collapse.length <= 64) headers["apns-collapse-id"] = body.collapse;
    }
    if (!(await tokenAllowed(body.token))) return tooMany();
    headers.authorization = `bearer ${await providerToken()}`;

    // Release builds talk to production, ones run from Xcode / flutter run to
    // the sandbox; a token from the other one is a BadDeviceToken here.
    for (const host of ["api.push.apple.com", "api.sandbox.push.apple.com"]) {
      const res = await fetch(`https://${host}/3/device/${body.token}`, { method: "POST", headers, body: payload });
      if (res.ok) return json(200, { ok: true });
      const answer: unknown = await res.json().catch(() => null);
      const reason = answer && typeof answer === "object" && "reason" in answer && typeof answer.reason === "string"
        ? answer.reason
        : "";
      if (res.status === 410 || reason === "Unregistered") return json(410, { gone: true });
      if (reason !== "BadDeviceToken") return json(502, { error: `APNs ${res.status} ${reason}` });
    }
    return json(410, { gone: true });
  }

  return async (req) => {
    const caller = callerOf(req);
    const callerKey = caller ? await keyer.key(caller) : null;
    if (callerKey && (limits.bad.full(callerKey) || !limits.caller.take(callerKey))) {
      return { res: tooMany(), outcome: { platform: "none", status: 429 } };
    }
    const sealed = await req.text().catch(() => "");
    const plain = sealed.length <= maxSealed ? await unseal(config.key, sealed) : null;
    let body: unknown = null;
    if (plain) {
      try {
        body = JSON.parse(new TextDecoder().decode(plain));
      } catch { /* answered below */ }
    }
    let res: Response;
    let platform: Outcome["platform"] = "none";
    if (!plain) {
      res = json(400, { error: "the body must be sealed to this relay's key (v1)" });
    } else if (!body || typeof body !== "object" || Array.isArray(body)) {
      res = json(400, { error: "the sealed body must be a JSON object" });
    } else {
      const push = body as Record<string, unknown>;
      if (push.platform === "android") {
        platform = "android";
        res = await android(push);
      } else if (push.platform === undefined || push.platform === "ios") {
        platform = "ios";
        res = await ios(push);
      } else {
        res = json(400, { error: "platform must be ios or android" });
      }
    }
    // Malformed requests and tokens no phone has: what guessing looks like.
    if (callerKey && (res.status === 400 || res.status === 410)) limits.bad.take(callerKey);
    return { res, outcome: { platform, status: res.status } };
  };
}

/**
 * A sealed alert's fields for the phone from a checked body: enc, and d (the
 * computer whose key opens it) when the server named one. A string says what's wrong.
 */
function sealedAlert(body: Record<string, unknown>): { enc: string; d?: string } | string {
  if (typeof body.enc !== "string" || body.enc.length > maxEnc) return "enc missing or too long";
  if (body.desktop === undefined) return { enc: body.enc };
  if (typeof body.desktop !== "string" || !/^[a-z0-9]{8}$/.test(body.desktop)) return "desktop must be a computer id";
  return { enc: body.enc, d: body.desktop };
}

/** A session's state from a checked {state, since: unix seconds, kind?}; a string says what's wrong. */
function activityState(s: unknown): { state: string; since: number; kind?: string } | string {
  if (!s || typeof s !== "object") return "state missing";
  const { state, since, kind } = s as Record<string, unknown>;
  if (typeof state !== "string" || !activityStates.includes(state)) return "state.state must be a known state";
  const now = Math.floor(Date.now() / 1000);
  if (typeof since !== "number" || !Number.isFinite(since) || since < now - 7 * 86400 || since > now + 3600) {
    return "state.since must be a recent unix time";
  }
  if (kind !== undefined && (typeof kind !== "string" || !activityKinds.includes(kind) || state !== "needs")) {
    return "state.kind must be a known kind, with needs";
  }
  return { state, since: Math.floor(since), ...(kind ? { kind } : {}) };
}

/** A Live Activity's push from a checked body; a string says what's wrong. */
function liveActivity(body: Record<string, unknown>): { payload: string; priority: string } | string {
  const s = activityState(body.state);
  if (typeof s === "string") return s;
  if (body.event !== "update" && body.event !== "end") return "event must be update or end";
  const now = Math.floor(Date.now() / 1000);
  const aps: Record<string, unknown> = { timestamp: now, event: body.event, "content-state": s };
  // Gone from the Lock Screen 10 minutes after it ended; otherwise stale (the
  // phone shows it as such) after 3 minutes without news: the server updates a live session more often.
  if (body.event === "end") aps["dismissal-date"] = now + 600;
  else aps["stale-date"] = now + 180;
  // Apple rations priority 10; working can wait.
  return { payload: JSON.stringify({ aps }), priority: s.state === "working" ? "5" : "10" };
}
