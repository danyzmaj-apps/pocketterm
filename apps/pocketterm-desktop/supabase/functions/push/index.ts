// Push notifications to the user's phones, through the publisher's relay
// (functions/relay holds the APNs key and the Firebase service account).
// A notification's text is sealed on the computer with its channel key
// (the one only that computer and the phones that scanned its code hold), so
// this function and the relay only ever see ciphertext. iPhones go through
// APNs, Android phones through FCM. Deployed --no-verify-jwt: the user's
// token is checked here.
//
//   POST {"action": "register", "token", "label"?, "platform"?}
//                                                           user token: this phone; platform: ios (default,
//                                                           token: the APNs device token, hex) | android
//                                                           (token: the FCM registration token)
//   POST {"action": "unregister", "token"}                  user token: signed out
//   POST {"action": "notify", "desktop", "enc", "collapse"?}
//                                                           user token: e.g. a coding session finished on the
//                                                           computer [desktop] (its 8-character id); enc:
//                                                           base64(nonce 12 ‖ ciphertext ‖ tag 16), AES-256-GCM
//                                                           with the computer's channel key over JSON
//                                                           {title, body, session?, state?}, AAD
//                                                           "pocketterm/v1|push|<desktop>"; collapse: the coding
//                                                           session (its routed key) a newer push replaces
//
// Live Activities (a coding session followed on the phone) carry a state and
// nothing else: no title, no text, so they aren't encrypted (an iPhone's
// notification extension never sees them, Apple shows them as sent). An
// iPhone's activity has its own push token; an Android phone follows each
// session with its FCM token (one row per session).
//
//   POST {"action": "activity_register", "token", "session", "platform"?}
//                                                             user token: an activity's push token (ios) or
//                                                             the phone's FCM token (android)
//   POST {"action": "activity_end", "token", "session"?}      user token: that activity is over (only that
//                                                             session's, when given)
//   POST {"action": "activity", "session", "state", "kind"?}  user token: the computer, on a session's change;
//        state: working | needs | done | ended, kind: question | approval | plan (needs only)
import { createClient } from "jsr:@supabase/supabase-js@2";
import { decodeBase64 } from "jsr:@std/encoding@1/base64";

const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// The publisher's relay; a fork with its own APNs key points this elsewhere.
const relay = Deno.env.get("PUSH_RELAY_URL") ?? "https://iemvfkcpmgdkupwnnewg.supabase.co/functions/v1/relay";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** [s] cut to at most [max] UTF-16 units, never through a character: half of one is valid JSON for neither Postgres nor the iPhone's JSONDecoder. */
const clip = (s: string, max: number) => s.slice(0, /[\uD800-\uDBFF]/.test(s[max - 1] ?? "") ? max - 1 : max);

/** The coding session a push is about: its terminal window's key (`kitty-<pid>/<window id>`, `tmux:default/3` …) or `pid:<pid>` (at most 64: also a collapse id). */
const sessionKey = (v: unknown) => (typeof v === "string" && /^[\w.:/-]{1,64}$/.test(v) ? v : undefined);

/** APNs tokens are hex; a Live Activity's is longer than a device's. */
const apnsToken = (v: unknown, max = 200): v is string =>
  typeof v === "string" && new RegExp(`^[0-9a-f]{64,${max}}$`).test(v);

/** FCM registration tokens: an Android phone's, for its notifications and its followed sessions alike. */
const fcmToken = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_:\-]{100,4096}$/.test(v);

const platforms = ["ios", "android"] as const;
type Platform = (typeof platforms)[number];

/** The relay's answer to one push; a 410 means the phone is gone. */
async function relayPost(body: Record<string, unknown>): Promise<Response | null> {
  const res = await fetch(relay, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }).catch((e) => {
    console.error("relay unreachable", e);
    return null;
  });
  if (res && !res.ok && res.status !== 410) console.error("relay", res.status, await res.text());
  return res;
}

const activityStates = ["working", "needs", "done", "ended"] as const;
const activityKinds = ["question", "approval", "plan"] as const;
type ActivityState = (typeof activityStates)[number];
type ActivityKind = (typeof activityKinds)[number];

/** Moves every Live Activity of [userId]'s coding [session] to [state] (ended: ends them). */
async function activity(userId: string, session: string, state: ActivityState, kind?: ActivityKind): Promise<number> {
  const { data: rows } = await admin
    .from("activity_tokens")
    .select("token, platform")
    .eq("user_id", userId)
    .eq("session", session);
  const now = Date.now();
  const live = { state, since: Math.floor(now / 1000), ...(state === "needs" && kind ? { kind } : {}) };
  let sent = 0;
  for (const { token, platform } of rows ?? []) {
    const res = platform === "android"
      ? await relayPost({ platform: "android", token, kind: "activity", session, state: live, collapse: session })
      : await relayPost({ token, kind: "liveactivity", event: state === "ended" ? "end" : "update", state: live });
    // An Android token is the phone's: gone, it follows no session any more.
    if (res?.status === 410) await admin.from("activity_tokens").delete().eq("token", token);
    else if (res?.ok) sent++;
  }
  // An ended activity takes no more pushes.
  if (state === "ended") await admin.from("activity_tokens").delete().eq("user_id", userId).eq("session", session);
  return sent;
}

/** A computer's 8-character id (desktops.id). */
const desktopId = (v: unknown): v is string => typeof v === "string" && /^[a-z0-9]{8}$/.test(v);

/** The relay takes at most 3000 base64 characters (FCM's 4 KB of data in all). */
const maxEnc = 3000;

/** A sealed notification: base64 of nonce 12 ‖ ciphertext ‖ tag 16, at least one byte of text. */
function sealed(v: unknown): v is string {
  if (typeof v !== "string" || v.length > maxEnc) return false;
  try {
    return decodeBase64(v).length > 12 + 16;
  } catch {
    return false;
  }
}

/** Sends [enc], sealed on computer [desktop], to every phone of [userId]; forgets the ones Apple or Google say are gone. */
async function send(userId: string, desktop: string, enc: string, collapse?: string): Promise<number> {
  const { data: devices } = await admin.from("push_devices").select("token, platform").eq("user_id", userId);
  let sent = 0;
  for (const d of devices ?? []) {
    const res = await relayPost({
      ...(d.platform === "android" ? { platform: "android" } : {}),
      token: d.token,
      kind: "terminal",
      enc,
      desktop,
      // Lets a newer push for the same coding session replace an older one.
      collapse,
    });
    if (res?.status === 410) await admin.from("push_devices").delete().eq("token", d.token);
    else if (res?.ok) sent++;
  }
  return sent;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const body = (await req.json().catch(() => null)) ?? {};

  const jwt = req.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
  const { data: auth } = await admin.auth.getUser(jwt);
  if (!auth.user) return json(401, { error: "Sign in first" });
  const user = auth.user.id;

  const platform: Platform | undefined = body.platform == null ? "ios" : platforms.find((p) => p === body.platform);
  if (!platform) return json(400, { error: "platform must be ios or android" });

  if (body.action === "register") {
    if (platform === "android") {
      if (!fcmToken(body.token)) return json(400, { error: "token must be the FCM registration token" });
    } else if (!apnsToken(body.token)) return json(400, { error: "token must be the APNs device token (hex)" });
    const { error } = await admin.from("push_devices").upsert({
      token: body.token,
      user_id: user,
      label: typeof body.label === "string" ? clip(body.label, 80) : "",
      platform,
      updated_at: new Date().toISOString(),
    });
    if (error) return json(500, { error: error.message });
    return json(200, { ok: true });
  }

  if (body.action === "unregister") {
    await admin.from("push_devices").delete().eq("token", body.token).eq("user_id", user);
    // An Android phone's sessions follow its device token.
    await admin.from("activity_tokens").delete().eq("token", body.token).eq("user_id", user);
    return json(200, { ok: true });
  }

  if (body.action === "notify") {
    if (!desktopId(body.desktop)) return json(400, { error: "desktop must be the computer's id" });
    if (!sealed(body.enc)) return json(400, { error: `enc must be the sealed notification, base64, at most ${maxEnc}` });
    if (body.collapse != null && !sessionKey(body.collapse)) {
      return json(400, { error: "collapse must be a coding session key" });
    }
    return json(200, { sent: await send(user, body.desktop, body.enc, sessionKey(body.collapse)) });
  }

  if (body.action === "activity_register") {
    const session = sessionKey(body.session);
    if (platform === "android") {
      if (!fcmToken(body.token)) return json(400, { error: "token must be the FCM registration token" });
    } else if (!apnsToken(body.token, 400)) return json(400, { error: "token must be the activity's push token (hex)" });
    if (!session) return json(400, { error: "session must be a coding session key" });
    // A token another user registered stays theirs.
    const { data: other } = await admin
      .from("activity_tokens")
      .select("user_id")
      .eq("token", body.token)
      .neq("user_id", user)
      .limit(1);
    if (other?.length) return json(409, { error: "token belongs to someone else" });
    // An iPhone's activity follows one session for good.
    if (platform === "ios") {
      await admin.from("activity_tokens").delete().eq("token", body.token).neq("session", session);
    }
    const { error } = await admin
      .from("activity_tokens")
      .upsert(
        { token: body.token, user_id: user, session, platform, updated_at: new Date().toISOString() },
        { onConflict: "token,session" },
      );
    if (error) return json(500, { error: error.message });
    return json(200, { ok: true });
  }

  if (body.action === "activity_end") {
    // No session ends every one this token follows; a bad one ends none.
    const session = sessionKey(body.session);
    if (body.session != null && !session) return json(400, { error: "session must be a coding session key" });
    if (typeof body.token === "string") {
      let ended = admin.from("activity_tokens").delete().eq("token", body.token).eq("user_id", user);
      if (session) ended = ended.eq("session", session);
      await ended;
    }
    return json(200, { ok: true });
  }

  if (body.action === "activity") {
    const session = sessionKey(body.session);
    if (!session) return json(400, { error: "session must be a coding session key" });
    const state = activityStates.find((s) => s === body.state);
    if (!state) return json(400, { error: `state must be ${activityStates.join(", ")}` });
    const kind = body.kind == null ? undefined : activityKinds.find((k) => k === body.kind);
    if (body.kind != null && !kind) return json(400, { error: `kind must be ${activityKinds.join(", ")}` });
    return json(200, { sent: await activity(user, session, state, kind) });
  }

  return json(400, {
    error: "action must be register, unregister, notify, activity_register, activity_end or activity",
  });
});
