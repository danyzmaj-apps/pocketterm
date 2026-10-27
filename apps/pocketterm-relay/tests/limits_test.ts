// src/limits.ts: the relay's per-key windows and their keys.
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { callerOf, Keyer, Limiter } from "../src/limits.ts";

Deno.test("a key gets max hits per window, then waits for the next window", () => {
  const limit = new Limiter(3, 1000);
  assertEquals([0, 1, 2, 3].map(() => limit.take("a", 0)), [true, true, true, false]);
  assert(limit.full("a", 999));
  assert(!limit.full("b", 999), "keys don't share a window");
  assert(limit.take("a", 1000), "a new window starts afresh");
  assert(!limit.full("a", 1000));
});

Deno.test("past maxKeys, finished windows go first, then the oldest", () => {
  const limit = new Limiter(1, 1000, 2);
  limit.take("old", 0);
  limit.take("kept", 1500);
  limit.take("new", 1600); // "old" has run out: it goes, the others stay full
  assert(limit.full("kept", 1600) && limit.full("new", 1600));
  limit.take("newer", 1700); // none finished: the oldest ("kept") goes
  assert(!limit.full("kept", 1700));
  assert(limit.full("new", 1700) && limit.full("newer", 1700));
});

Deno.test("the caller is who Cloudflare says, never what the client says", () => {
  const req = (headers: Record<string, string>) => new Request("http://x/", { headers });
  assertEquals(callerOf(req({ "cf-connecting-ip": " 192.0.2.1 " })), "192.0.2.1");
  assertEquals(callerOf(req({ "x-forwarded-for": "192.0.2.1", "x-real-ip": "192.0.2.2" })), null);
  assertEquals(callerOf(req({})), null);
});

Deno.test("an IPv6 caller counts by its /64, an IPv4-mapped one as its IPv4 address", () => {
  const req = (ip: string) => new Request("http://x/", { headers: { "cf-connecting-ip": ip } });
  assertEquals(callerOf(req("2001:db8:1:2::1")), "2001:db8:1:2::/64");
  assertEquals(callerOf(req("2001:DB8:1:2:ffff:eeee:dddd:cccc")), "2001:db8:1:2::/64");
  assertEquals(callerOf(req("2001:db8::1")), "2001:db8:0:0::/64");
  assertNotEquals(callerOf(req("2001:db8:1:3::1")), callerOf(req("2001:db8:1:2::1")));
  assertEquals(callerOf(req("::ffff:192.0.2.7")), "192.0.2.7");
});

Deno.test("counter keys are HMACs that change with the day's salt, never the value itself", async () => {
  const keyer = new Keyer();
  const today = await keyer.key("192.0.2.1", 0);
  assertEquals(await keyer.key("192.0.2.1", 1000), today, "stable within a day");
  assertNotEquals(await keyer.key("192.0.2.2", 1000), today);
  assert(!today.includes("192.0.2.1"));
  assertNotEquals(await keyer.key("192.0.2.1", 24 * 3600_000), today, "a new salt the next day");
});
