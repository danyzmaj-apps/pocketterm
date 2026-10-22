// PocketTerm's push relay as a service: GET /health, GET /metrics (private: the
// tunnel answers 404 for it publicly), POST /v1/push (src/relay.ts).
//
// Settings (environment): PORT (8080), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC
// (com.danyzmaj.pocketterm). Secret files: RELAY_KEY_FILE (/run/secrets/relay_key,
// the X25519 private key, PEM), RELAY_PREVIOUS_KEY_FILE (/run/secrets/relay_key_previous,
// optional: the key before, kept while servers move to the new one), APNS_KEY_FILE
// (/run/secrets/apns_key, the .p8), FCM_SERVICE_ACCOUNT_FILE (/run/secrets/fcm_service_account;
// without it Android pushes answer 501).
//
// Logs: JSON lines with a level; a push logs only its platform, status and time.

import { Metrics } from "./src/metrics.ts";
import { relay } from "./src/relay.ts";
import { publicKeyText, relayKey } from "./src/seal.ts";

const log = (level: "info" | "warn" | "error", msg: string, fields: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ level, msg, ...fields }));

function setting(name: string, fallback?: string): string {
  const v = Deno.env.get(name) || fallback;
  if (!v) {
    log("error", `${name} is not set`);
    Deno.exit(1);
  }
  return v;
}

async function optionalFile(path: string): Promise<string | undefined> {
  try {
    return await Deno.readTextFile(path);
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return undefined;
    throw e;
  }
}

const key = await relayKey(await Deno.readTextFile(setting("RELAY_KEY_FILE", "/run/secrets/relay_key")));
const previousPem = await optionalFile(setting("RELAY_PREVIOUS_KEY_FILE", "/run/secrets/relay_key_previous"));
const previous = previousPem ? await relayKey(previousPem) : undefined;
const fcmServiceAccount = await optionalFile(setting("FCM_SERVICE_ACCOUNT_FILE", "/run/secrets/fcm_service_account"));
const push = relay({
  apnsKey: await Deno.readTextFile(setting("APNS_KEY_FILE", "/run/secrets/apns_key")),
  apnsKeyId: setting("APNS_KEY_ID"),
  apnsTeamId: setting("APNS_TEAM_ID"),
  apnsTopic: setting("APNS_TOPIC", "com.danyzmaj.pocketterm"),
  fcmServiceAccount,
  keys: previous ? [key, previous] : [key],
});
const metrics = new Metrics();
const port = Number(setting("PORT", "8080"));

Deno.serve({
  port,
  hostname: "0.0.0.0",
  onListen: () =>
    log("info", "listening", {
      port,
      publicKey: publicKeyText(key),
      previousKey: previous ? publicKeyText(previous) : undefined,
      fcm: !!fcmServiceAccount,
    }),
  onError: (e) => {
    log("error", "request failed", { error: e instanceof Error ? e.name : "unknown" });
    return new Response(null, { status: 500 });
  },
}, async (req) => {
  const path = new URL(req.url).pathname;
  if (path === "/health") return new Response("ok");
  if (path === "/metrics") {
    return new Response(metrics.text(), { headers: { "content-type": "text/plain; version=0.0.4" } });
  }
  const start = performance.now();
  let res: Response;
  if (path !== "/v1/push") {
    res = new Response(null, { status: 404 });
  } else if (req.method !== "POST") {
    res = new Response(null, { status: 405, headers: { allow: "POST" } });
  } else {
    const { res: answer, outcome } = await push(req);
    res = answer;
    const ms = Math.round(performance.now() - start);
    metrics.push(outcome.platform, outcome.status);
    // A 5xx carries Apple's or Google's reason (no token, no body): worth seeing in the logs.
    const error = outcome.status >= 500 ? (await res.clone().json().catch(() => null))?.error : undefined;
    log(error ? "warn" : "info", "push", { platform: outcome.platform, status: outcome.status, ms, error });
  }
  metrics.observe(req.method, res.status, (performance.now() - start) / 1000);
  return res;
});
