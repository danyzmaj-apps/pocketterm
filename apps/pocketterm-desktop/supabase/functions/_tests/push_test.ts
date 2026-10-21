// functions/push: what a server hands the relay. A notification arrives
// sealed by the computer and leaves exactly as it came.
import { assertEquals } from "jsr:@std/assert@1";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import { handlerOf, json, network, post, sent, supabaseEnv } from "./harness.ts";

const relayUrl = "https://relay.test/functions/v1/relay";
const push = await handlerOf(() => import("../push/index.ts"), { ...supabaseEnv, PUSH_RELAY_URL: relayUrl });

const user = { id: "00000000-0000-0000-0000-00000000000a", email: "owner@example.com", app_metadata: {} };
const signedIn = { authorization: "Bearer user-token" };
const iphone = "a".repeat(64);
const pixel = "f".repeat(160);
const activity = "b".repeat(160);
const desktop = "k3x9m2qa";
/** What a computer sealed: nonce 12 ‖ ciphertext ‖ tag 16, opaque here. */
const enc = encodeBase64(crypto.getRandomValues(new Uint8Array(12 + 40 + 16)));

/** A server with an iPhone and an Android phone, both following coding session "s1". */
function server() {
  network((req) => {
    const url = new URL(req.url);
    if (req.url.startsWith(relayUrl)) return json({ ok: true });
    if (url.pathname === "/auth/v1/user") return json(user);
    if (url.pathname === "/rest/v1/push_devices" && req.method === "POST") return new Response(null, { status: 201 });
    if (url.pathname === "/rest/v1/push_devices") {
      return json([{ token: iphone, platform: "ios" }, { token: pixel, platform: "android" }]);
    }
    if (url.pathname === "/rest/v1/activity_tokens") {
      return json([{ token: activity, platform: "ios" }, { token: pixel, platform: "android" }]);
    }
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
}

const toRelay = () => sent.filter((r) => r.url.href === relayUrl).map((r) => JSON.parse(r.body));

Deno.test("a computer's sealed alert reaches every phone untouched, with the computer it came from", async () => {
  server();
  const res = await push(post({ action: "notify", desktop, enc, collapse: `${desktop}/s1` }, signedIn));
  assertEquals(await res.json(), { sent: 2 });
  assertEquals(toRelay(), [
    { token: iphone, kind: "terminal", enc, desktop, collapse: `${desktop}/s1` },
    { platform: "android", token: pixel, kind: "terminal", enc, desktop, collapse: `${desktop}/s1` },
  ]);
});

Deno.test("an alert moves no Live Activity: the computer says so itself", async () => {
  server();
  await push(post({ action: "notify", desktop, enc, collapse: "s1", state: "done" }, signedIn));
  assertEquals(toRelay().map((b) => b.kind), ["terminal", "terminal"]);
});

Deno.test("a Live Activity push carries only the session's state, to iPhones and Android phones alike", async () => {
  server();
  const res = await push(post({ action: "activity", session: "s1", state: "needs", kind: "plan" }, signedIn));
  assertEquals(await res.json(), { sent: 2 });
  const [ios, android] = toRelay();
  assertEquals(ios.token, activity);
  assertEquals(ios.kind, "liveactivity");
  assertEquals(ios.event, "update");
  assertEquals(ios.state.state, "needs");
  assertEquals(ios.state.kind, "plan");
  assertEquals(android.platform, "android");
  assertEquals(android.token, pixel);
  assertEquals(android.kind, "activity");
  assertEquals(android.session, "s1");
  assertEquals(android.collapse, "s1");
  assertEquals(android.state, ios.state);
  assertEquals("enc" in android, false);
});

Deno.test("malformed requests are refused before anything reaches the relay", async () => {
  const cases: Record<string, unknown>[] = [
    { action: "register", token: "not-hex" },
    { action: "register", platform: "android", token: iphone },
    { action: "register", platform: "symbian", token: iphone },
    { action: "activity_register", token: activity, session: "not a session key" },
    { action: "activity", session: "s1", state: "exploded" },
    { action: "notify", enc },
    { action: "notify", desktop: "Not-An-Id", enc },
    { action: "notify", desktop },
    { action: "notify", desktop, enc: "not base64!" },
    { action: "notify", desktop, enc: encodeBase64(new Uint8Array(28)) }, // a nonce and a tag, no text
    { action: "notify", desktop, enc: encodeBase64(new Uint8Array(2400)) }, // past what the relay takes
    { action: "notify", desktop, enc, collapse: "x".repeat(65) },
    { action: "notify", title: "Claude finished", body: "Done." }, // plain text is never forwarded
  ];
  for (const body of cases) {
    server();
    assertEquals((await push(post(body, signedIn))).status, 400, JSON.stringify(body));
    assertEquals(toRelay().length, 0);
  }
});

Deno.test("registering a phone stores its token and nothing secret", async () => {
  server();
  const res = await push(post({ action: "register", token: iphone, label: "Dany's iPhone", key: "c2VjcmV0" }, signedIn));
  assertEquals(res.status, 200);
  const row = JSON.parse(sent.find((r) => r.url.pathname === "/rest/v1/push_devices" && r.method === "POST")!.body);
  assertEquals(row.token, iphone);
  assertEquals(row.platform, "ios");
  assertEquals("key" in row, false);
});

Deno.test("ending a Live Activity with a bad session key ends none of the token's others", async () => {
  const deletes = () => sent.filter((r) => r.method === "DELETE").map((r) => r.url.searchParams);
  server();
  const bad = await push(post({ action: "activity_end", token: activity, session: "x".repeat(65) }, signedIn));
  assertEquals(bad.status, 400);
  assertEquals(deletes().length, 0);

  server();
  await push(post({ action: "activity_end", token: activity, session: "s1" }, signedIn));
  assertEquals(deletes().map((q) => q.get("session")), ["eq.s1"]);

  server();
  await push(post({ action: "activity_end", token: activity }, signedIn));
  assertEquals(deletes().map((q) => q.get("session")), [null], "no session: every one this token follows");
});

Deno.test("nothing without a sign-in", async () => {
  network((req) => {
    const { pathname } = new URL(req.url);
    if (pathname === "/auth/v1/user") return json({ msg: "bad jwt" }, 401);
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
  assertEquals((await push(post({ action: "notify", desktop, enc }, { authorization: "Bearer forged" }))).status, 401);
  assertEquals((await push(post({ action: "register", token: iphone }, { authorization: "Bearer forged" }))).status, 401);
});

/** A lone surrogate: half a character, which Postgres refuses in JSON. */
const halfCharacter = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

Deno.test("a long label is cut between characters, never through one", async () => {
  server();
  assertEquals((await push(post({ action: "register", token: iphone, label: `a${"😀".repeat(40)}` }, signedIn))).status, 200);
  const row = JSON.parse(sent.find((r) => r.url.pathname === "/rest/v1/push_devices" && r.method === "POST")!.body);
  assertEquals(halfCharacter.test(row.label), false, "no half character reaches the database");
});

Deno.test("a body that isn't an object is refused, not a crash", async () => {
  server();
  assertEquals((await push(post("null", signedIn))).status, 400);
});
