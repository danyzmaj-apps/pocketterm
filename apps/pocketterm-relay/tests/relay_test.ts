// The relay: what reaches APNs and FCM, what never does, and its rate limits.
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { type Config, relay as makeRelay } from "../src/relay.ts";
import { json, network, pem, post as sealedPost, sent, testKey } from "./harness.ts";

const config: Config = {
  apnsKey: await pem({ name: "ECDSA", namedCurve: "P-256" }),
  apnsKeyId: "KEYID12345",
  apnsTeamId: "TEAM123456",
  apnsTopic: "com.example.pocketterm",
  keys: [await testKey()],
};
// let: a test swaps in a relay with an FCM service account.
let push = makeRelay(config);
const relay = async (req: Promise<Request>) => (await push(await req)).res;
const post = (body: unknown, headers: Record<string, string> = {}) => sealedPost(config.keys[0], body, headers);

/** A device token of [n] hex digits, distinct per [seed]. */
const hex = (seed: number, n = 64) => seed.toString(16).padStart(n, "0");
const now = () => Math.floor(Date.now() / 1000);

const apns = (status = 200, reason?: string) => () =>
  reason ? json({ reason }, status) : new Response(null, { status });

Deno.test("an iPhone alert goes to APNs with generic text, the ciphertext and its computer", async () => {
  network(apns());
  const res = await relay(
    post({ token: hex(1), kind: "terminal", enc: "c2VhbGVk", desktop: "k3x9m2qa", collapse: "s1" }),
  );
  assertEquals(res.status, 200);
  assertEquals(sent.length, 1);
  const [push] = sent;
  assertEquals(push.url.href, `https://api.push.apple.com/3/device/${hex(1)}`);
  assertEquals(push.headers.get("apns-topic"), "com.example.pocketterm");
  assertEquals(push.headers.get("apns-push-type"), "alert");
  assertEquals(push.headers.get("apns-collapse-id"), "s1");
  assertMatch(push.headers.get("authorization") ?? "", /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assertEquals(JSON.parse(push.body), {
    aps: { alert: { title: "PocketTerm", body: "Terminal" }, sound: "default", "mutable-content": 1 },
    enc: "c2VhbGVk",
    d: "k3x9m2qa",
  });
});

Deno.test("a server from before end-to-end encryption still reaches its phones", async () => {
  network(apns());
  assertEquals((await relay(post({ token: hex(10), kind: "terminal", enc: "c2VhbGVk" }))).status, 200);
  const { d, enc } = JSON.parse(sent[0].body);
  assertEquals([d, enc], [undefined, "c2VhbGVk"]);
});

Deno.test("a sandbox token is tried on the sandbox after production calls it bad", async () => {
  network((req) => (new URL(req.url).host === "api.push.apple.com" ? apns(400, "BadDeviceToken")() : apns()()));
  const res = await relay(post({ token: hex(2), kind: "terminal", enc: "x" }));
  assertEquals(res.status, 200);
  assertEquals(sent.map((r) => r.url.host), ["api.push.apple.com", "api.sandbox.push.apple.com"]);
});

Deno.test("a token Apple calls gone answers 410, so the server forgets the phone", async () => {
  network(apns(410, "Unregistered"));
  assertEquals((await relay(post({ token: hex(3), kind: "terminal", enc: "x" }))).status, 410);
  network(apns(400, "BadDeviceToken"));
  assertEquals((await relay(post({ token: hex(4), kind: "terminal", enc: "x" }))).status, 410);
});

Deno.test("a Live Activity push carries only a state rebuilt from checked fields", async () => {
  network(apns());
  const since = now() - 60;
  const res = await relay(post({
    token: hex(5, 160),
    kind: "liveactivity",
    event: "update",
    state: { state: "needs", since, kind: "approval", title: "secret project", extra: 1 },
    alert: "injected",
  }));
  assertEquals(res.status, 200);
  const [push] = sent;
  assertEquals(push.headers.get("apns-topic"), "com.example.pocketterm.push-type.liveactivity");
  assertEquals(push.headers.get("apns-push-type"), "liveactivity");
  assertEquals(push.headers.get("apns-priority"), "10");
  const { aps, ...rest } = JSON.parse(push.body);
  assertEquals(rest, {});
  assertEquals(aps["content-state"], { state: "needs", since, kind: "approval" });
  assertEquals(aps.event, "update");
  // Stale 3 minutes on: a computer that stops sending leaves no activity claiming it's still working.
  assert(Math.abs(aps["stale-date"] - (now() + 180)) <= 2);
  assertEquals(aps.alert, undefined);
});

Deno.test("working waits at low priority; an ended activity is dismissed later", async () => {
  network(apns());
  await relay(
    post({ token: hex(6, 160), kind: "liveactivity", event: "update", state: { state: "working", since: now() } }),
  );
  assertEquals(sent[0].headers.get("apns-priority"), "5");
  network(apns());
  await relay(
    post({ token: hex(6, 160), kind: "liveactivity", event: "end", state: { state: "ended", since: now() } }),
  );
  const { aps } = JSON.parse(sent[0].body);
  assertEquals(aps.event, "end");
  assert(aps["dismissal-date"] > now());
});
Deno.test("a server whose clock is off still reaches its phones, its since held to the last week", async () => {
  for (const [since, held] of [[now() - 30 * 86400, now() - 7 * 86400], [now() + 7200, now()]]) {
    network(apns());
    const res = await relay(
      post({ token: hex(10, 160), kind: "liveactivity", event: "update", state: { state: "done", since } }),
    );
    assertEquals(res.status, 200);
    const got = JSON.parse(sent[0].body).aps["content-state"].since;
    assert(Math.abs(got - held) <= 2, `${since} → ${got}`);
  }
});

Deno.test("malformed pushes are refused before anything reaches Apple or Google", async () => {
  const bad: unknown[] = [
    { token: "not-hex", kind: "terminal", enc: "x" },
    { token: hex(7, 300), kind: "terminal", enc: "x" }, // too long for a device token
    { token: hex(7), kind: "terminal" },
    { token: hex(7), kind: "terminal", enc: "x".repeat(3001) },
    { token: hex(7), kind: "reminder", enc: "x" },
    { token: hex(7, 160), kind: "liveactivity", event: "update", state: { state: "exploded", since: now() } },
    { token: hex(7, 160), kind: "liveactivity", event: "update", state: { state: "done", since: now(), kind: "plan" } },
    { token: hex(7, 160), kind: "liveactivity", event: "start", state: { state: "done", since: now() } },
    { token: hex(7), kind: "terminal", enc: "x", desktop: "../../etc" },
    { platform: "windows", token: hex(7), kind: "terminal", enc: "x" },
    { platform: "android", token: "short", kind: "terminal", enc: "x" },
    { platform: "android", token: "f".repeat(160), kind: "reminder", enc: "x" },
    { platform: "android", token: "f".repeat(160), kind: "liveactivity", enc: "x" },
    { platform: "android", token: "f".repeat(160), kind: "terminal", enc: "x", desktop: 12345678 },
    { platform: "android", token: "f".repeat(160), kind: "activity", session: "s1", state: { state: "exploded" } },
    {
      platform: "android",
      token: "f".repeat(160),
      kind: "activity",
      session: "not a key",
      state: { state: "done", since: now() },
    },
    { platform: "android", token: "f".repeat(160), kind: "activity", enc: "c2VhbGVk" }, // whose key opens it?
    {
      platform: "android",
      token: "f".repeat(160),
      kind: "activity",
      session: "k3x9m2qa/s1",
      state: { state: "working", since: now() }, // in the clear
    },
    "a string",
    [1, 2],
  ];
  network();
  for (const body of bad) {
    const res = await relay(post(body));
    assertEquals(res.status, 400, JSON.stringify(body));
  }
  const unsealed = [
    new Request("http://relay.test/v1/push", {
      method: "POST",
      body: JSON.stringify({ token: hex(7), kind: "terminal", enc: "x" }),
    }),
    await sealedPost(await testKey(), { token: hex(7), kind: "terminal", enc: "x" }), // sealed to another relay
    new Request("http://relay.test/v1/push", { method: "POST", body: "x".repeat(20_000) }),
  ];
  for (const req of unsealed) assertEquals((await push(req)).res.status, 400);
  assertEquals(sent.length, 0);
});

Deno.test("an Android push goes to FCM as a data-only message", async () => {
  network();
  const android = {
    platform: "android",
    token: "f".repeat(160),
    kind: "terminal",
    enc: "c2VhbGVk",
    desktop: "k3x9m2qa",
    collapse: "s1",
  };
  assertEquals((await relay(post(android))).status, 501, "without a service account");

  push = makeRelay({
    ...config,
    fcmServiceAccount: JSON.stringify({
      project_id: "pocketterm-test",
      client_email: "relay@pocketterm-test.iam.gserviceaccount.com",
      private_key: await pem({
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      }),
    }),
  });
  network((req) =>
    req.url === "https://oauth2.googleapis.com/token"
      ? json({ access_token: "google-token", expires_in: 3600 })
      : json({ name: "sent" })
  );
  assertEquals((await relay(post(android))).status, 200);
  const [token, message] = sent;
  assertEquals(new URLSearchParams(token.body).get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
  assertEquals(message.url.href, "https://fcm.googleapis.com/v1/projects/pocketterm-test/messages:send");
  assertEquals(message.headers.get("authorization"), "Bearer google-token");
  assertEquals(JSON.parse(message.body), {
    message: {
      token: "f".repeat(160),
      data: { kind: "terminal", enc: "c2VhbGVk", d: "k3x9m2qa" },
      android: { priority: "high", collapse_key: "s1", ttl: "86400s" },
    },
  });

  network(() => json({ name: "sent" }));
  const sealedActivity = {
    platform: "android",
    token: "e".repeat(160),
    kind: "activity",
    enc: "c2VhbGVk",
    desktop: "k3x9m2qa",
    collapse: "k3x9m2qa/s1",
  };
  assertEquals((await relay(post(sealedActivity))).status, 200);
  assertEquals(JSON.parse(sent[0].body).message, {
    token: "e".repeat(160),
    data: { kind: "activity", enc: "c2VhbGVk", d: "k3x9m2qa" },
    android: { priority: "high", collapse_key: "k3x9m2qa/s1", ttl: "3600s" },
  });

  network(() => json({ name: "sent" }));
  const since = now() - 60;
  const end = {
    platform: "android",
    token: "e".repeat(160),
    kind: "activity",
    session: "k3x9m2qa/s1",
    state: { state: "ended", since, title: "secret project" },
    collapse: "k3x9m2qa/s1",
  };
  assertEquals((await relay(post(end))).status, 200);
  assertEquals(
    JSON.parse(sent[0].body).message.data,
    { kind: "activity", session: "k3x9m2qa/s1", state: "ended", since: String(since * 1000) },
  );

  network(() => json({ error: { status: "NOT_FOUND", message: "Requested entity was not found." } }, 404));
  assertEquals(
    (await relay(post({ ...android, token: "g".repeat(160) }))).status,
    410,
    "an uninstalled app's token is gone",
  );
});

Deno.test("one device gets at most 60 pushes a minute", async () => {
  network(apns());
  const token = hex(8);
  for (let i = 0; i < 60; i++) assertEquals((await relay(post({ token, kind: "terminal", enc: "x" }))).status, 200);
  const res = await relay(post({ token, kind: "terminal", enc: "x" }));
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("retry-after"), "60");
  assertEquals(sent.length, 60, "the 61st never reached Apple");
  assertEquals(
    (await relay(post({ token: hex(9), kind: "terminal", enc: "x" }))).status,
    200,
    "other devices still get theirs",
  );
});

Deno.test("a caller guessing tokens is turned away; others are not", async () => {
  network(apns(400, "BadDeviceToken"));
  const guesser = { "cf-connecting-ip": "203.0.113.9" };
  for (let i = 0; i < 15; i++) {
    assertEquals((await relay(post({ token: hex(100 + i), kind: "terminal", enc: "x" }, guesser))).status, 410);
  }
  for (let i = 0; i < 15; i++) {
    assertEquals((await relay(post({ token: "nope", kind: "terminal", enc: "x" }, guesser))).status, 400);
  }
  network(apns());
  assertEquals(
    (await relay(post({ token: hex(200), kind: "terminal", enc: "x" }, guesser))).status,
    429,
    "even a good push waits",
  );
  assertEquals(sent.length, 0);
  assertEquals(
    (await relay(post({ token: hex(200), kind: "terminal", enc: "x" }, { "cf-connecting-ip": "203.0.113.10" }))).status,
    200,
  );
  // x-forwarded-for is the client's to write: it names no caller.
  assertEquals(
    (await relay(post({ token: hex(201), kind: "terminal", enc: "x" }, { "x-forwarded-for": "203.0.113.9" }))).status,
    200,
  );
});
