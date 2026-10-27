// PocketTerm's server on Supabase: the REST paths of packages/pocketterm_server/PROTOCOL.md under
// /functions/v1/pocketterm/v1/…, for one owner, in one project. State lives in Postgres (the pocketterm schema,
// reached only through the service-role pocketterm_* functions in supabase/migrations), images and files sealed
// in the private Storage bucket pocketterm-blobs, and the live channel is Realtime broadcast on private topics:
// POST /v1/live/token mints a device a 10-minute Realtime token (ES256, with the key the setup imported as the
// project's JWT signing key, PT_REALTIME_JWK), which RLS on realtime.messages checks against the devices still
// signed in. Two endpoints the PocketTerm server doesn't have: POST /v1/setup/new (a computer makes a new setup
// link: the hosted server prints its own) and POST /v1/live/token. POST /v1/tick is pg_cron's minute.
//
// Deployed without JWT verification: callers present PocketTerm device tokens, checked here. No dependencies.

const VERSION = "0.1.7";
const PROTOCOL = 1;
const MAX_JSON = 64 * 1024;
const MAX_BLOB = 20 * 1024 * 1024;
const BUCKET = "pocketterm-blobs";
const LIVE_TOKEN_SECONDS = 600;
const DEFAULT_RELAY = "https://push.danyzmaj.com/v1/push";
const DEFAULT_RELAY_KEY = "VjwMi0GtvYoVT3Q9FlENy/dQOVe0vuqU8K4t+fw3fHc=";

const DESKTOP_PLATFORMS = ["macos", "windows", "linux"];
const PHONE_PLATFORMS = ["ios", "android"];
const ACTIVITY_STATES = ["working", "needs", "done", "ended"];
const ACTIVITY_KINDS = ["question", "approval", "plan"];
const DESKTOP_ID = /^[a-z0-9]{8}$/;
const BLOB_PATH = /^[A-Za-z0-9-]{1,64}$/;
const SESSION_KEY = /^[\w.:/-]{1,64}$/;
const ROUTED_KEY = /^[a-z0-9]{8}\/[\w.:/-]{1,55}$/;
const FCM_TOKEN = /^[A-Za-z0-9_:\-]{100,4096}$/;
const PUSH_TAG = /^[A-Za-z0-9_-]{11}$/;
const SESSION_TAG = /^[A-Za-z0-9_-]{22}$/;
const MAX_ENC = 3000;
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const PAIRING_CODE_LENGTH = 28;

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

// Configuration ------------------------------------------------------------------------------------------------

const env = (name: string) => Deno.env.get(name) ?? "";
const supabaseUrl = env("SUPABASE_URL").replace(/\/+$/, "");

/// The service key: the legacy service_role JWT, else the project's first secret key.
function serviceKey(): string {
  if (env("SUPABASE_SERVICE_ROLE_KEY")) return env("SUPABASE_SERVICE_ROLE_KEY");
  try {
    const keys = JSON.parse(env("SUPABASE_SECRET_KEYS") || "{}") as Record<string, string>;
    return keys.default ?? Object.values(keys)[0] ?? "";
  } catch {
    return "";
  }
}

/// The key apps reach Realtime with (it isn't secret): set by the setup, else the project's own.
function publishableKey(): string {
  if (env("PT_PUBLISHABLE_KEY")) return env("PT_PUBLISHABLE_KEY");
  try {
    const keys = JSON.parse(env("SUPABASE_PUBLISHABLE_KEYS") || "{}") as Record<string, string>;
    const key = keys.default ?? Object.values(keys)[0];
    if (key) return key;
  } catch {
    // Below.
  }
  return env("SUPABASE_ANON_KEY");
}

function serviceHeaders(): Record<string, string> {
  const key = serviceKey();
  // A secret key (sb_secret_…) goes only as apikey; the gateway turns it into a JWT.
  return key.startsWith("sb_") ? { apikey: key } : { apikey: key, authorization: `Bearer ${key}` };
}

// Answers ------------------------------------------------------------------------------------------------------

class Fail extends Error {
  constructor(readonly status: number, readonly code: string, message: string, readonly retryAfter?: number) {
    super(message);
  }
}

const bad = (message: string) => new Fail(400, "bad_request", message);

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

function unknownEndpoint(): Fail {
  return new Fail(
    404,
    "not_found",
    `No such endpoint on this server (PocketTerm on Supabase ${VERSION}). If the app is newer than the server, ` +
      "set PocketTerm up on Supabase again from a computer to update it.",
  );
}

/// Runs one of the migrations' pocketterm_* functions; what it returns, or its {fail} as a [Fail].
async function rpc<T = Record<string, unknown>>(name: string, args: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { ...serviceHeaders(), "content-type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) {
    console.error(`rpc ${name}: ${res.status} ${text}`);
    throw new Fail(500, "internal", "Something went wrong on the server.");
  }
  const out = text ? JSON.parse(text) : null;
  if (out && typeof out === "object" && "fail" in out) {
    const f = out.fail as { status: number; error: string; message: string; retry_after?: number };
    throw new Fail(f.status, f.error, f.message, f.retry_after);
  }
  return out as T;
}

// Secrets ------------------------------------------------------------------------------------------------------

function randomBytes(n: number): Uint8Array<ArrayBuffer> {
  return crypto.getRandomValues(new Uint8Array(n));
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function base64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function fromBase64(text: string): Uint8Array<ArrayBuffer> {
  const s = atob(text.replaceAll("-", "+").replaceAll("_", "/"));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

/// A bearer secret: 32 random bytes, base64url without padding (43 characters).
const newToken = () => base64url(randomBytes(32));

function newId(length = 16): string {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  let id = "";
  // 252 = 7 × 36: no bias.
  while (id.length < length) {
    for (const b of randomBytes(length)) if (b < 252 && id.length < length) id += chars[b % 36];
  }
  return id;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

function newPairingCode(): string {
  const chars = Array.from(randomBytes(PAIRING_CODE_LENGTH), (b) => CROCKFORD[b & 31]).join("");
  return chars.match(/.{4}/g)!.join("-");
}

const normalizePairingCode = (code: string) =>
  code.toUpperCase().replace(/[^0-9A-Z]/g, "").replaceAll("O", "0").replace(/[IL]/g, "1");

// Callers ------------------------------------------------------------------------------------------------------

/// What the redeem throttle counts the caller as: the address Supabase's edge saw (the first in
/// X-Forwarded-For), an IPv4-mapped IPv6 address as its IPv4 one, any other IPv6 address as its /64.
function callerKey(req: Request): string {
  const address = (req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0] ?? "")
    .trim();
  if (!address.includes(":")) return address || "unknown";
  const [head, tail = ""] = address.toLowerCase().split("::");
  const left = head ? head.split(":") : [];
  const right = address.includes("::") && tail ? tail.split(":") : [];
  const last = (right.length ? right : left).at(-1) ?? "";
  if (last.includes(".") && [...left, ...right.slice(0, -1)].join(":").replace(/0/g, "").replace(/:/g, "") === "ffff") {
    return last;
  }
  const groups = address.includes("::")
    ? [...left, ...Array(8 - left.length - right.length).fill("0"), ...right]
    : left;
  return `${groups.slice(0, 4).map((g) => parseInt(g || "0", 16).toString(16)).join(":")}::/64`;
}

/// The device token's SHA-256, or 401.
async function bearer(req: Request): Promise<string> {
  const header = req.headers.get("authorization") ?? "";
  if (!header.startsWith("Bearer ")) {
    throw new Fail(401, "unauthorized", "Sign in again: this device is not signed in to the server.");
  }
  return await sha256Hex(header.slice(7).trim());
}

async function readJson(req: Request): Promise<Record<string, unknown>> {
  const length = Number(req.headers.get("content-length") ?? "0");
  if (length > MAX_JSON) throw new Fail(413, "too_large", `A request body is at most ${MAX_JSON} bytes.`);
  const bytes = await readLimited(req, MAX_JSON, () =>
    new Fail(413, "too_large", `A request body is at most ${MAX_JSON} bytes.`));
  if (bytes.length === 0) return {};
  try {
    const body = JSON.parse(new TextDecoder().decode(bytes));
    if (body && typeof body === "object" && !Array.isArray(body)) return body;
  } catch {
    // Below.
  }
  throw bad("The body must be a JSON object.");
}

/// A redeem's body: one that isn't JSON reads as `{}`, so it fails (and counts) like a missing field.
async function redeemBody(req: Request): Promise<Record<string, unknown>> {
  try {
    return await readJson(req);
  } catch (e) {
    if (e instanceof Fail && e.status === 413) throw e;
    return {};
  }
}

async function readLimited(req: Request, max: number, tooLarge: () => Fail): Promise<Uint8Array<ArrayBuffer>> {
  if (!req.body) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of req.body) {
    size += chunk.length;
    if (size > max) throw tooLarge();
    chunks.push(chunk);
  }
  const out = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

const clip = (s: string, max: number) => {
  if (s.length <= max) return s;
  const last = s.charCodeAt(max - 1);
  return s.slice(0, last >= 0xd800 && last <= 0xdbff ? max - 1 : max);
};

const label = (body: Record<string, unknown>) => typeof body.label === "string" ? clip(body.label, 80) : "";

function platform(body: Record<string, unknown>, allowed: string[]): string {
  const p = body.platform;
  if (typeof p !== "string" || !allowed.includes(p)) throw bad(`platform must be ${allowed.join(", ")}.`);
  return p;
}

// The live channel's token -------------------------------------------------------------------------------------

let signingKey: { key: CryptoKey; kid: string } | null = null;

async function liveSigningKey(): Promise<{ key: CryptoKey; kid: string }> {
  if (signingKey) return signingKey;
  const raw = env("PT_REALTIME_JWK");
  if (!raw) {
    throw new Fail(500, "internal", "The live channel isn't set up on this project: set PocketTerm up on it again.");
  }
  const jwk = JSON.parse(raw) as JsonWebKey & { kid?: string };
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return signingKey = { key, kid: jwk.kid ?? "" };
}

/// A Realtime token for [device]: role authenticated (RLS on realtime.messages applies), pt_device names the
/// device for pocketterm.live_ok, and sub is a UUID made from the device id (there is no auth.users row).
async function liveToken(device: string): Promise<{ token: string; expires: number }> {
  const { key, kid } = await liveSigningKey();
  const now = Math.floor(Date.now() / 1000);
  const hex = (await sha256Hex(`pocketterm-device|${device}`)).slice(0, 32);
  const sub = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20)}`;
  const exp = now + LIVE_TOKEN_SECONDS;
  const header = { alg: "ES256", typ: "JWT", kid };
  const claims = { role: "authenticated", aud: "authenticated", sub, pt_device: device, iat: now, exp };
  const enc = (o: unknown) => base64url(new TextEncoder().encode(JSON.stringify(o)));
  const input = `${enc(header)}.${enc(claims)}`;
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input)),
  );
  return { token: `${input}.${base64url(signature)}`, expires: exp };
}

// Push: sealed to the relay's X25519 key (apps/pocketterm-relay/src/seal.ts) -----------------------------------

const relayUrl = env("PUSH_RELAY_URL") || DEFAULT_RELAY;
const relayKey = fromBase64(env("PUSH_RELAY_KEY") || DEFAULT_RELAY_KEY);

async function sealForRelay(plain: Uint8Array<ArrayBuffer>): Promise<Record<string, unknown>> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]) as CryptoKeyPair;
  const epk = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const relayPublic = await crypto.subtle.importKey("raw", relayKey, { name: "X25519" }, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "X25519", public: relayPublic }, pair.privateKey, 256);
  const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const salt = new Uint8Array([...epk, ...relayKey]);
  const key = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info: new TextEncoder().encode("pocketterm-relay/v1") },
    hkdf,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const nonce = randomBytes(12);
  const c = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, plain));
  return { v: 1, kid: base64(relayKey).slice(0, 11), epk: base64(epk), n: base64(nonce), c: base64(c) };
}

/// Sends [bodies] to the relay in the background (after the answer): no request waits on it. A relay that can't
/// be reached, answers 5xx or 429 is tried again after 2, 4, 8 … seconds (429: its Retry-After), up to 5 tries
/// within 2 minutes; a 410 forgets the token.
function relay(bodies: Record<string, unknown>[]) {
  if (bodies.length === 0) return;
  background(Promise.all(bodies.map(deliver)));
}

async function deliver(body: Record<string, unknown>) {
  const started = Date.now();
  for (let attempt = 1; attempt <= 5; attempt++) {
    let status: number | null = null;
    let retryAfter: number | null = null;
    try {
      const sealed = await sealForRelay(new TextEncoder().encode(JSON.stringify(body)));
      const res = await fetch(relayUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(sealed),
        signal: AbortSignal.timeout(20000),
      });
      status = res.status;
      retryAfter = Number(res.headers.get("retry-after")) || null;
      const text = await res.text();
      if (status >= 300 && status !== 410) console.error(`relay ${status} ${text}`);
    } catch (e) {
      console.error(`relay unreachable: ${e}`);
    }
    if (status === 410) {
      if (typeof body.token === "string") await rpc("pocketterm_gone", { p_push_token: body.token }).catch(() => {});
      return;
    }
    if (status !== null && status !== 429 && (status < 500 || status === 501)) return;
    const wait = retryAfter ? Math.min(Math.max(retryAfter, 1), 60) * 1000 : 2000 * 2 ** (attempt - 1);
    if (attempt === 5 || Date.now() - started + wait > 120000) return;
    const { promise, resolve } = Promise.withResolvers<void>();
    setTimeout(resolve, wait);
    await promise;
  }
}

function background(p: Promise<unknown>) {
  const quiet = p.catch((e) => console.error(`background: ${e}`));
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(quiet);
}

type ActivityRow = { token: string; session: string; platform: string; ref: string | null };

/// The relay bodies that move [rows]' Live Activities to [live] (an end, or a state) as the hosted server's
/// _sendActivity does: an iPhone gets the state alone, an Android phone [enc] (or a plain end).
function activityPushes(rows: ActivityRow[], live: Record<string, unknown>, enc?: string, tag?: string) {
  const ended = live.state === "ended";
  const out: Record<string, unknown>[] = [];
  for (const t of rows) {
    if (t.platform !== "android") {
      out.push({ token: t.token, kind: "liveactivity", event: ended ? "end" : "update", state: live });
    } else if (t.ref == null) {
      continue;
    } else if (ended) {
      out.push({ platform: "android", token: t.token, kind: "activity", ref: t.ref, state: live });
    } else if (enc != null && tag != null) {
      out.push({ platform: "android", token: t.token, kind: "activity", enc, tag, ref: t.ref });
    }
  }
  return out;
}

const endedState = () => ({ state: "ended", since: Math.floor(Date.now() / 1000) });

function sealed(v: unknown): v is string {
  if (typeof v !== "string" || v.length > MAX_ENC) return false;
  try {
    return fromBase64(v).length > 12 + 16;
  } catch {
    return false;
  }
}

const apnsToken = (v: unknown, max: number) => typeof v === "string" && new RegExp(`^[0-9a-f]{64,${max}}$`).test(v);

async function push(action: string, body: Record<string, unknown>, token: string): Promise<unknown> {
  const p = body.platform ?? "ios";
  if (p !== "ios" && p !== "android") throw bad("platform must be ios or android.");
  const t = body.token;
  switch (action) {
    case "register":
      if (p === "android" ? typeof t !== "string" || !FCM_TOKEN.test(t) : !apnsToken(t, 200)) {
        throw bad(p === "android" ? "token must be the FCM registration token." : "token must be the APNs device token (hex).");
      }
      break;
    case "unregister":
    case "activity_end":
      if (body.session != null && (typeof body.session !== "string" || !SESSION_KEY.test(body.session))) {
        throw bad("session must be a coding session key.");
      }
      break;
    case "notify": {
      if (typeof body.tag !== "string" || !PUSH_TAG.test(body.tag)) throw bad("tag must be the computer's push tag.");
      if (!sealed(body.enc)) throw bad(`enc must be the sealed notification, base64, at most ${MAX_ENC}.`);
      const c = body.collapse;
      if (c != null && (typeof c !== "string" || !SESSION_TAG.test(c))) {
        throw bad("collapse must be the coding session's push tag.");
      }
      break;
    }
    case "activity_register":
      if (p === "android") {
        if (typeof t !== "string" || !FCM_TOKEN.test(t)) throw bad("token must be the FCM registration token.");
        if (typeof body.ref !== "string" || !SESSION_TAG.test(body.ref)) throw bad("ref must be the session's push tag.");
      } else if (!apnsToken(t, 400)) {
        throw bad("token must be the activity's push token (hex).");
      }
      if (typeof body.session !== "string" || !ROUTED_KEY.test(body.session)) {
        throw bad("session must be a routed session key, <desktop id>/<key>.");
      }
      break;
    case "activity": {
      if (typeof body.session !== "string" || !ROUTED_KEY.test(body.session)) {
        throw bad("session must be a routed session key, <desktop id>/<key>.");
      }
      if (!ACTIVITY_STATES.includes(body.state as string)) throw bad(`state must be ${ACTIVITY_STATES.join(", ")}.`);
      if (body.kind != null && !ACTIVITY_KINDS.includes(body.kind as string)) {
        throw bad(`kind must be ${ACTIVITY_KINDS.join(", ")}.`);
      }
      if (body.tag != null && (typeof body.tag !== "string" || !PUSH_TAG.test(body.tag))) {
        throw bad("tag must be the computer's push tag.");
      }
      if (body.enc != null && (body.tag == null || !sealed(body.enc))) {
        throw bad(`enc must be the sealed state, base64, at most ${MAX_ENC}, with tag.`);
      }
      break;
    }
    default:
      throw unknownEndpoint();
  }
  const clean = { ...body, platform: p, label: typeof body.label === "string" ? clip(body.label, 80) : undefined };
  const out = await rpc<{
    result?: unknown;
    notify?: { token: string; platform: string }[];
    activity?: ActivityRow[];
    live?: Record<string, unknown>;
  }>("pocketterm_push", { p_token: token, p_action: action, p_body: clean });
  if (out.notify) {
    relay(out.notify.map((n) => ({
      ...(n.platform === "android" ? { platform: "android" } : {}),
      token: n.token,
      kind: "terminal",
      enc: body.enc,
      tag: body.tag,
      ...(body.collapse != null ? { collapse: body.collapse } : {}),
    })));
    return { sent: out.notify.length };
  }
  if (out.activity && out.live) {
    // The state as the database kept it for the iPhones' refresh (pocketterm_put_desktop).
    const { enc, tag } = body as { enc?: string; tag?: string };
    const bodies = activityPushes(out.activity, out.live, enc, tag);
    relay(bodies);
    return { sent: bodies.length };
  }
  return out.result;
}

// Blobs --------------------------------------------------------------------------------------------------------

async function deleteBlobs(paths: string[]) {
  if (paths.length === 0) return;
  const res = await fetch(`${supabaseUrl}/storage/v1/object/${BUCKET}`, {
    method: "DELETE",
    headers: { ...serviceHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ prefixes: paths }),
  });
  await res.body?.cancel();
}

/// Storage answers a missing or taken object with its own statusCode in the body (older versions with 400).
async function storageStatus(res: Response): Promise<number> {
  if (res.ok) return res.status;
  const text = await res.text();
  try {
    const s = Number(JSON.parse(text).statusCode);
    if (s >= 400) return s;
  } catch {
    // Below.
  }
  return res.status;
}

async function blob(req: Request, path: string, token: string): Promise<Response> {
  if (!BLOB_PATH.test(path)) throw bad("A blob path is 1 to 64 characters A-Z, a-z, 0-9 and -.");
  const object = `${supabaseUrl}/storage/v1/object/${BUCKET}/${path}`;
  const tooLarge = () => new Fail(413, "too_large", `That file is too large: the most is ${MAX_BLOB / 1048576} MB.`);
  switch (req.method) {
    case "PUT": {
      await rpc("pocketterm_whoami", { p_token: token });
      if (Number(req.headers.get("content-length") ?? "0") > MAX_BLOB) throw tooLarge();
      const bytes = await readLimited(req, MAX_BLOB, tooLarge);
      // Its place first (409 taken, 429 or 507 over a cap), then the bytes.
      await rpc("pocketterm_blob_reserve", { p_token: token, p_path: path, p_size: bytes.length });
      let status: number;
      try {
        const res = await fetch(object, {
          method: "POST",
          headers: { ...serviceHeaders(), "content-type": "application/octet-stream", "x-upsert": "false" },
          body: bytes,
        });
        status = await storageStatus(res);
      } catch (e) {
        console.error(`storage put: ${e}`);
        status = 0;
      }
      if (status >= 200 && status < 300) return json(201, { path });
      await rpc("pocketterm_blob_gone", { p_path: path });
      if (status === 409) throw new Fail(409, "conflict", "That blob path is taken.");
      if (status === 413) throw tooLarge();
      console.error(`storage put ${status}`);
      throw new Fail(507, "storage", `Couldn't save the upload: Supabase Storage answered ${status || "nothing"}.`);
    }
    case "GET": {
      const fresh = await rpc<boolean>("pocketterm_blob_fresh", { p_token: token, p_path: path });
      const res = fresh ? await fetch(object, { headers: serviceHeaders() }) : null;
      if (!res?.ok) {
        const status = res ? await storageStatus(res) : 404;
        if (status === 404 || status === 400) throw new Fail(404, "not_found", "No such blob: it ran out or was downloaded.");
        throw new Fail(500, "internal", "Something went wrong on the server.");
      }
      // Deleted once it has gone out in full; kept for another try otherwise.
      let sent = 0;
      const total = Number(res.headers.get("content-length") ?? "-1");
      const counted = res.body!.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
        transform(chunk, controller) {
          sent += chunk.length;
          controller.enqueue(chunk);
        },
        flush() {
          if (total < 0 || sent === total) {
            background(Promise.all([deleteBlobs([path]), rpc("pocketterm_blob_gone", { p_path: path })]));
          }
        },
      }));
      const headers: Record<string, string> = { "content-type": "application/octet-stream" };
      if (total >= 0) headers["content-length"] = `${total}`;
      return new Response(counted, { status: 200, headers });
    }
    case "DELETE":
      await rpc("pocketterm_whoami", { p_token: token });
      await Promise.all([deleteBlobs([path]), rpc("pocketterm_blob_gone", { p_path: path })]);
      return json(200, { ok: true });
    default:
      throw new Fail(405, "method_not_allowed", "/v1/blobs/:path takes PUT, GET or DELETE.");
  }
}

// Routes -------------------------------------------------------------------------------------------------------

let tickUrlSaid = 0;

/// Tells the database where pg_cron reaches this function: at most every 10 minutes per instance (a database
/// set up anew learns it again).
function sayTickUrl() {
  if (Date.now() - tickUrlSaid < 600000 || !supabaseUrl) return;
  tickUrlSaid = Date.now();
  background(rpc("pocketterm_tick_url", { p_url: `${supabaseUrl}/functions/v1/pocketterm/v1/tick` }));
}

async function route(req: Request): Promise<Response> {
  const url = new URL(req.url);
  // /pocketterm/v1/… here (Supabase takes /functions/v1 off), /functions/v1/pocketterm/v1/… elsewhere.
  const at = url.pathname.indexOf("/v1/", url.pathname.indexOf("pocketterm"));
  const parts = at < 0 ? [] : url.pathname.slice(at + 4).split("/").filter((s) => s.length > 0);
  const m = req.method;
  const only = (method: string) => {
    if (m !== method) throw new Fail(405, "method_not_allowed", `/v1/${parts.join("/")} takes ${method}.`);
  };
  const key = parts.join("/");
  if (key !== "health" && key !== "tick") sayTickUrl();

  switch (true) {
    case key === "health":
      only("GET");
      return json(200, { pocketterm: PROTOCOL, version: VERSION, time: new Date().toISOString(), backend: "supabase" });
    case key === "setup/redeem": {
      only("POST");
      const body = await redeemBody(req);
      const p = typeof body.platform === "string" && DESKTOP_PLATFORMS.includes(body.platform) ? body.platform : null;
      const token = newToken();
      const out = await rpc("pocketterm_setup_redeem", {
        p_caller: callerKey(req),
        p_setup_hash: typeof body.setup === "string" ? await sha256Hex(body.setup) : null,
        p_id: newId(),
        p_token_hash: await sha256Hex(token),
        p_label: label(body),
        p_platform: p,
      });
      return json(200, { token, ...out });
    }
    case key === "pair/redeem": {
      only("POST");
      const body = await redeemBody(req);
      const p = typeof body.platform === "string" && PHONE_PLATFORMS.includes(body.platform) ? body.platform : null;
      const code = typeof body.code === "string" ? normalizePairingCode(body.code) : "";
      const token = newToken();
      const out = await rpc("pocketterm_pair_redeem", {
        p_caller: callerKey(req),
        p_code_hash: code.length === PAIRING_CODE_LENGTH ? await sha256Hex(code) : "-",
        p_id: newId(),
        p_token_hash: await sha256Hex(token),
        p_label: label(body),
        p_platform: p,
      });
      return json(200, { token, ...out });
    }
    case key === "setup/new": {
      only("POST");
      const setup = newToken();
      await rpc("pocketterm_setup_new", { p_token: await bearer(req), p_setup_hash: await sha256Hex(setup) });
      return json(200, { setup });
    }
    case key === "pair": {
      only("POST");
      const code = newPairingCode();
      const out = await rpc<{ expires: string }>("pocketterm_pair", {
        p_token: await bearer(req),
        p_code_hash: await sha256Hex(normalizePairingCode(code)),
      });
      return json(200, { code, expires: out.expires });
    }
    case key === "me":
      only("GET");
      return json(200, await rpc("pocketterm_me", { p_token: await bearer(req) }));
    case key === "desktops":
      only("GET");
      return json(200, await rpc("pocketterm_desktops", { p_token: await bearer(req) }));
    case parts.length === 2 && parts[0] === "desktops": {
      const token = await bearer(req);
      const id = parts[1];
      if (m === "PUT") {
        await rpc("pocketterm_whoami", { p_token: token });
        if (!DESKTOP_ID.test(id)) throw bad("The computer's id must be 8 characters a-z, 0-9.");
        const body = await readJson(req);
        if (typeof body.name !== "string") throw bad("name must be a string.");
        const { refresh, ...desktop } = await rpc<{ refresh: { token: string; state: unknown }[] }>(
          "pocketterm_put_desktop",
          { p_token: token, p_id: id, p_name: clip(body.name, 80), p_platform: platform(body, DESKTOP_PLATFORMS) },
        );
        // The iPhones following its sessions get their last state again before it goes stale (the relay stamps
        // a new stale-date), quietly: nothing changed.
        relay(refresh.map((r) => ({
          token: r.token,
          kind: "liveactivity",
          event: "update",
          state: r.state,
          quiet: true,
        })));
        return json(200, desktop);
      }
      if (m === "DELETE") {
        const out = await rpc<{ end: ActivityRow[] }>("pocketterm_delete_desktop", { p_token: token, p_id: id });
        relay(activityPushes(out.end, endedState()));
        return json(200, { ok: true });
      }
      throw new Fail(405, "method_not_allowed", `/v1/desktops/${id} takes PUT or DELETE.`);
    }
    case key === "devices":
      only("GET");
      return json(200, await rpc("pocketterm_devices", { p_token: await bearer(req) }));
    case parts.length === 2 && parts[0] === "devices": {
      only("DELETE");
      const out = await rpc<{ end: ActivityRow[] }>("pocketterm_drop_device", {
        p_token: await bearer(req),
        p_id: parts[1],
      });
      relay(activityPushes(out.end, endedState()));
      return json(200, { ok: true });
    }
    case key === "erase": {
      only("POST");
      const out = await rpc<{ end: ActivityRow[]; blobs: string[] }>("pocketterm_erase", { p_token: await bearer(req) });
      relay(activityPushes(out.end, endedState()));
      await deleteBlobs(out.blobs);
      return json(200, { ok: true });
    }
    case parts.length === 2 && parts[0] === "blobs":
      return await blob(req, parts[1], await bearer(req));
    case parts.length === 2 && parts[0] === "push": {
      only("POST");
      const token = await bearer(req);
      return json(200, await push(parts[1], await readJson(req), token));
    }
    case key === "live/token": {
      only("POST");
      const out = await rpc<{ device: { id: string } }>("pocketterm_whoami", { p_token: await bearer(req) });
      const live = await liveToken(out.device.id);
      return json(200, { token: live.token, expires: live.expires, apikey: publishableKey() });
    }
    case key === "tick": {
      only("POST");
      const out = await rpc<{ end: ActivityRow[]; blobs: string[] }>("pocketterm_sweep", {
        p_secret: req.headers.get("x-pocketterm-tick") ?? "",
      });
      relay(activityPushes(out.end, endedState()));
      await deleteBlobs(out.blobs);
      return json(200, { ended: out.end.length, blobs: out.blobs.length });
    }
    case key === "ws":
      throw new Fail(
        404,
        "not_found",
        "PocketTerm on Supabase has no WebSocket of its own: the live channel is Supabase Realtime (POST /v1/live/token).",
      );
    default:
      throw unknownEndpoint();
  }
}

Deno.serve(async (req) => {
  try {
    return await route(req);
  } catch (e) {
    if (e instanceof Fail) {
      return json(
        e.status,
        { error: e.code, message: e.message },
        e.retryAfter ? { "retry-after": `${e.retryAfter}` } : {},
      );
    }
    console.error(`${req.method} ${new URL(req.url).pathname}: ${e instanceof Error ? e.stack : e}`);
    return json(500, { error: "internal", message: "Something went wrong on the server." });
  }
});
