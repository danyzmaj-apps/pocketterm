// Error reports: off without a DSN, and nothing in a report points at a person, a machine or a request.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { type ReportEvent, reportOptions, scrub, scrubEvent } from "../src/errors.ts";

const env = (vars: Record<string, string>) => (name: string) => vars[name];

Deno.test("reports are off without a DSN", () => {
  assertEquals(reportOptions(env({})), undefined);
  assertEquals(reportOptions(env({ SENTRY_DSN: "  " })), undefined);
});

Deno.test("reports send errors only, no PII and no breadcrumbs", () => {
  const o = reportOptions(env({ SENTRY_DSN: " https://k@glitchtip.example/1 " }))!;
  assertEquals(o.dsn, "https://k@glitchtip.example/1");
  assertEquals(o.environment, "production");
  assertEquals(o.sendDefaultPii, false);
  assertEquals(o.tracesSampleRate, 0);
  assertEquals(o.maxBreadcrumbs, 0);
  assertEquals(o.beforeBreadcrumb(), null);
  const kept = o.integrations(
    ["Breadcrumbs", "Console", "Fetch", "DenoServe", "RequestData", "ContextLines", "GlobalHandlers", "Future"].map(
      (name) => ({ name }),
    ),
  );
  assertEquals(kept.map((i) => i.name), ["GlobalHandlers"]);
  assertEquals(reportOptions(env({ SENTRY_DSN: "x", SENTRY_ENVIRONMENT: "staging" }))!.environment, "staging");
});

Deno.test("scrub hides addresses, hosts, emails and URLs", () => {
  assertEquals(
    scrub("connect to https://mac.tail1234.ts.net:8443/v1/push failed"),
    "connect to https://<redacted> failed",
  );
  assertEquals(scrub("from 100.101.2.3 and fd7a:115c:a1e0::1"), "from <ip> and <ip>");
  assertEquals(scrub("host mac.tail1234.ts.net or box.local"), "host <host> or <host>");
  assertEquals(scrub("mail ana@example.com"), "mail <email>");
  assertEquals(scrub("at 12:30:45 Foo::bar"), "at 12:30:45 Foo::bar");
  assert(scrub("x".repeat(1000)).length <= 301);
});

Deno.test("scrubEvent drops people, machines and requests", () => {
  const event = scrubEvent<ReportEvent>({
    message: "to 10.0.0.1",
    server_name: "danyzmaj-server",
    user: { ip_address: "1.2.3.4" },
    request: { url: "https://push.danyzmaj.com/v1/push" },
    extra: { body: "token" },
    breadcrumbs: [{ message: "log line" }],
    exception: { values: [{ value: "fetch https://api.push.apple.com/3/device/abc failed" }] },
  });
  assertEquals(event, {
    message: "to <ip>",
    exception: { values: [{ value: "fetch https://<redacted> failed" }] },
  });
});
