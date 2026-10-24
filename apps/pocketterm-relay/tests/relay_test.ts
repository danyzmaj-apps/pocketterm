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

// A computer's push tag and a session's: opaque here, made on the computer with its key.
const tag = "RJM0r7AxRLM";
const ref = "yMPqtkm1TA3-r0AeuNDSHg";
/** A sealed alert for [token]. */
const alert = (token: string) => ({ token, kind: "terminal", enc: "x", tag });

const apns = (status = 200, reason?: string) => () =>
  reason ? json({ reason }, status) : new Response(null, { status });

Deno.test("an iPhone alert goes to APNs with generic text, the ciphertext and its computer's tag, no ids", async () => {
  network(apns());
  const res = await relay(post({ token: hex(1), kind: "terminal", enc: "c2VhbGVk", tag, collapse: ref }));
  assertEquals(res.status, 200);
  assertEquals(sent.length, 1);
  const [push] = sent;
  assertEquals(push.url.href, `https://api.push.apple.com/3/device/${hex(1)}`);
  assertEquals(push.headers.get("apns-topic"), "com.example.pocketterm");
  assertEquals(push.headers.get("apns-push-type"), "alert");
  assertEquals(push.headers.get("apns-collapse-id"), ref);
  assertMatch(push.headers.get("authorization") ?? "", /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assertEquals(JSON.parse(push.body), {
    aps: { alert: { title: "PocketTerm", body: "Terminal" }, sound: "default", "mutable-content": 1 },
    enc: "c2VhbGVk",
    t: tag,
  });
});

Deno.test("an alert naming its computer or session in the clear is refused", async () => {
  network(apns());
  for (
    const body of [
      { token: hex(10), kind: "terminal", enc: "c2VhbGVk" }, // no tag: which key opens it?
      { token: hex(10), kind: "terminal", enc: "c2VhbGVk", desktop: "k3x9m2qa" },
      { token: hex(10), kind: "terminal", enc: "c2VhbGVk", tag: "k3x9m2qa" },
      { token: hex(10), kind: "terminal", enc: "c2VhbGVk", tag, collapse: "k3x9m2qa/s1" },
      { token: hex(10), kind: "terminal", enc: "c2VhbGVk", tag, session: "k3x9m2qa/s1" },
    ]
  ) assertEquals((await relay(post(body))).status, 400, JSON.stringify(body));
  assertEquals(sent.length, 0);
});

Deno.test("a sandbox token is tried on the sandbox after production calls it bad", async () => {
  network((req) => (new URL(req.url).host === "api.push.apple.com" ? apns(400, "BadDeviceToken")() : apns()()));
  const res = await relay(post(alert(hex(2))));
  assertEquals(res.status, 200);
  assertEquals(sent.map((r) => r.url.host), ["api.push.apple.com", "api.sandbox.push.apple.com"]);
});

Deno.test("a token Apple calls gone answers 410, so the server forgets the phone", async () => {
  network(apns(410, "Unregistered"));
  assertEquals((await relay(post(alert(hex(3))))).status, 410);
  network(apns(400, "BadDeviceToken"));
  assertEquals((await relay(post(alert(hex(4))))).status, 410);
});

Deno.test("a Live Activity push carries only a state rebuilt from checked fields", async () => {
  network(apns());
  const since = now() - 60;
  const res = await relay(post({
    token: hex(5, 160),
    kind: "liveactivity",
    event: "update",
    state: { state: "needs", since, kind: "approval", title: "secret project", extra: 1 },
  }));
  assertEquals(res.status, 200);
  const [push] = sent;
  assertEquals(push.headers.get("apns-topic"), "com.example.pocketterm.push-type.liveactivity");
  assertEquals(push.headers.get("apns-push-type"), "liveactivity");
  assertEquals(push.headers.get("apns-priority"), "10");
  assertEquals(push.headers.get("apns-collapse-id"), null);
  const { aps, ...rest } = JSON.parse(push.body);
  assertEquals(rest, {});
  assertEquals(aps["content-state"], { state: "needs", since, kind: "approval" });
  assertEquals(aps.event, "update");
  // Stale 3 minutes on: a computer that stops sending leaves no activity claiming it's still working.
  assert(Math.abs(aps["stale-date"] - (now() + 180)) <= 2);
  assertEquals(aps.alert, undefined);
});

Deno.test("a Live Activity push carrying anything but its token and state is refused", async () => {
  network(apns());
  const update = {
    token: hex(5, 160),
    kind: "liveactivity",
    event: "update",
    state: { state: "working", since: now() },
  };
  for (
    const more of [{ session: "k3x9m2qa/s1" }, { desktop: "k3x9m2qa" }, { collapse: ref }, { tag }, { alert: "hi" }]
  ) assertEquals((await relay(post({ ...update, ...more }))).status, 400, JSON.stringify(more));
  assertEquals(sent.length, 0);
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

Deno.test("a quiet update waits at low priority with a fresh stale-date; quiet is only true, with update", async () => {
  network(apns());
  const since = now() - 3600;
  const res = await relay(post({
    token: hex(7, 160),
    kind: "liveactivity",
    event: "update",
    state: { state: "needs", since, kind: "question" },
    quiet: true,
  }));
  assertEquals(res.status, 200);
  assertEquals(sent[0].headers.get("apns-priority"), "5");
  const { aps } = JSON.parse(sent[0].body);
  assertEquals(aps["content-state"], { state: "needs", since, kind: "question" });
  assert(Math.abs(aps["stale-date"] - (now() + 180)) <= 2);
  assertEquals(aps.alert, undefined);

  network(apns());
  for (
    const wrong of [
      { event: "update", state: { state: "done", since }, quiet: false },
      { event: "update", state: { state: "done", since }, quiet: "yes" },
      { event: "end", state: { state: "ended", since }, quiet: true },
    ]
  ) {
    assertEquals((await relay(post({ token: hex(7, 160), kind: "liveactivity", ...wrong }))).status, 400);
  }
  assertEquals(sent.length, 0);
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
    { token: "not-hex", kind: "terminal", enc: "x", tag },
    { token: hex(7, 300), kind: "terminal", enc: "x", tag }, // too long for a device token
    { token: hex(7), kind: "terminal", tag },
    { token: hex(7), kind: "terminal", enc: "x".repeat(3001), tag },
    { token: hex(7), kind: "reminder", enc: "x", tag },
    { token: hex(7, 160), kind: "liveactivity", event: "update", state: { state: "exploded", since: now() } },
    { token: hex(7, 160), kind: "liveactivity", event: "update", state: { state: "done", since: now(), kind: "plan" } },
    { token: hex(7, 160), kind: "liveactivity", event: "start", state: { state: "done", since: now() } },
    { token: hex(7), kind: "terminal", enc: "x", tag: "../../etc/xx" },
    { platform: "windows", token: hex(7), kind: "terminal", enc: "x", tag },
    { platform: "android", token: "short", kind: "terminal", enc: "x", tag },
    { platform: "android", token: "f".repeat(160), kind: "reminder", enc: "x", tag },
    { platform: "android", token: "f".repeat(160), kind: "liveactivity", enc: "x", tag },
    { platform: "android", token: "f".repeat(160), kind: "terminal", enc: "x", tag: 12345678 },
    { platform: "android", token: "f".repeat(160), kind: "activity", ref, state: { state: "exploded" } },
    {
      platform: "android",
      token: "f".repeat(160),
      kind: "activity",
      ref: "k3x9m2qa/s1", // a session key, not its tag
      state: { state: "ended", since: now() },
    },
    { platform: "android", token: "f".repeat(160), kind: "activity", enc: "c2VhbGVk", ref }, // whose key opens it?
    { platform: "android", token: "f".repeat(160), kind: "activity", enc: "c2VhbGVk", tag }, // which session?
    {
      platform: "android",
      token: "f".repeat(160),
      kind: "activity",
      ref,
      state: { state: "working", since: now() }, // in the clear
    },
    {
      platform: "android",
      token: "f".repeat(160),
      kind: "activity",
      ref,
      session: "k3x9m2qa/s1",
      state: { state: "ended", since: now() },
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

Deno.test("an Android push goes to FCM as a data-only message, with tags and no ids", async () => {
  network();
  const android = {
    platform: "android",
    token: "f".repeat(160),
    kind: "terminal",
    enc: "c2VhbGVk",
    tag,
    collapse: ref,
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
      data: { kind: "terminal", enc: "c2VhbGVk", t: tag },
      android: { priority: "high", collapse_key: ref, ttl: "86400s" },
    },
  });

  network(() => json({ name: "sent" }));
  const sealedActivity = {
    platform: "android",
    token: "e".repeat(160),
    kind: "activity",
    enc: "c2VhbGVk",
    tag,
    ref,
  };
  assertEquals((await relay(post(sealedActivity))).status, 200);
  assertEquals(JSON.parse(sent[0].body).message, {
    token: "e".repeat(160),
    data: { kind: "activity", enc: "c2VhbGVk", t: tag },
    android: { priority: "high", collapse_key: ref, ttl: "3600s" },
  });

  network(() => json({ name: "sent" }));
  const since = now() - 60;
  const end = {
    platform: "android",
    token: "e".repeat(160),
    kind: "activity",
    ref,
    state: { state: "ended", since, title: "secret project" },
  };
  assertEquals((await relay(post(end))).status, 200);
  assertEquals(
    JSON.parse(sent[0].body).message,
    {
      token: "e".repeat(160),
      data: { kind: "activity", ref, state: "ended", since: String(since * 1000) },
      android: { priority: "high", collapse_key: ref, ttl: "3600s" },
    },
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
  for (let i = 0; i < 60; i++) assertEquals((await relay(post(alert(token)))).status, 200);
  const res = await relay(post(alert(token)));
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("retry-after"), "60");
  assertEquals(sent.length, 60, "the 61st never reached Apple");
  assertEquals(
    (await relay(post(alert(hex(9))))).status,
    200,
    "other devices still get theirs",
  );
});

Deno.test("a caller guessing tokens is turned away; others are not", async () => {
  network(apns(400, "BadDeviceToken"));
  const guesser = { "cf-connecting-ip": "203.0.113.9" };
  for (let i = 0; i < 15; i++) {
    assertEquals((await relay(post(alert(hex(100 + i)), guesser))).status, 410);
  }
  for (let i = 0; i < 15; i++) {
    assertEquals((await relay(post(alert("nope"), guesser))).status, 400);
  }
  network(apns());
  assertEquals(
    (await relay(post(alert(hex(200)), guesser))).status,
    429,
    "even a good push waits",
  );
  assertEquals(sent.length, 0);
  assertEquals(
    (await relay(post(alert(hex(200)), { "cf-connecting-ip": "203.0.113.10" }))).status,
    200,
  );
  // x-forwarded-for is the client's to write: it names no caller.
  assertEquals(
    (await relay(post(alert(hex(201)), { "x-forwarded-for": "203.0.113.9" }))).status,
    200,
  );
});
