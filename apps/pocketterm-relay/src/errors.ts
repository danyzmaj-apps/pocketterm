// Error reports to GlitchTip (Sentry-compatible), only when SENTRY_DSN is set. What leaves the relay is the
// exception's type, its scrubbed message and its stack: never a request, a token, an address or a log line.
// main.ts hands these options to Sentry.init.

// The integrations kept. Everything else is off on purpose: Breadcrumbs, Console and Fetch would copy log lines and
// URLs, DenoServe, DenoHttp and RequestData would attach requests and client addresses, ContextLines reads source
// files the container may not read. An allowlist, so an integration a later SDK adds stays off until chosen.
export const keptIntegrations: Record<string, true> = {
  EventFilters: true,
  FunctionToString: true,
  LinkedErrors: true,
  Dedupe: true,
  DenoContext: true,
  NormalizePaths: true,
  GlobalHandlers: true,
};

const maxText = 300;

/** Strips what could point at a person or a machine from a message: URLs, IPs, host names, emails. */
export function scrub(text: string): string {
  const out = text
    .replace(/\b[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]+/gi, (m) => `${m.slice(0, m.indexOf("://"))}://<redacted>`)
    .replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, "<email>")
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "<ip>")
    .replace(
      /(?<![\w:])(?:(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}|[0-9a-f:]*::[0-9a-f:]*)(?![\w:])/gi,
      (m) => /[0-9a-f]/i.test(m) ? "<ip>" : m,
    )
    .replace(/\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ts\.net|local|lan|internal)\b/gi, "<host>");
  return out.length > maxText ? `${out.slice(0, maxText)}…` : out;
}

/** The parts of a Sentry event this file touches; structural, so the tests need no SDK. */
export interface ReportEvent {
  message?: string;
  server_name?: string;
  user?: unknown;
  request?: unknown;
  extra?: unknown;
  breadcrumbs?: unknown;
  exception?: { values?: { value?: string }[] };
  logentry?: { message?: string; formatted?: string; params?: unknown[] };
}

/** beforeSend: drops the fields that can carry people, machines or traffic, and scrubs every message. */
export function scrubEvent<E extends ReportEvent>(event: E): E {
  delete event.server_name;
  delete event.user;
  delete event.request;
  delete event.extra;
  delete event.breadcrumbs;
  if (event.message) event.message = scrub(event.message);
  if (event.logentry) {
    event.logentry = {
      message: event.logentry.message && scrub(event.logentry.message),
      formatted: event.logentry.formatted && scrub(event.logentry.formatted),
    };
  }
  for (const e of event.exception?.values ?? []) {
    if (e.value) e.value = scrub(e.value);
  }
  return event;
}

/** Sentry.init options from the environment, or undefined when SENTRY_DSN is unset (reports off). */
export function reportOptions(env: (name: string) => string | undefined) {
  const dsn = env("SENTRY_DSN")?.trim();
  if (!dsn) return undefined;
  return {
    dsn,
    environment: env("SENTRY_ENVIRONMENT")?.trim() || "production",
    release: env("SENTRY_RELEASE")?.trim() || undefined,
    sendDefaultPii: false,
    tracesSampleRate: 0,
    maxBreadcrumbs: 0,
    beforeBreadcrumb: () => null,
    enableOpenTelemetrySetup: false,
    initialScope: { tags: { component: "relay" } },
    integrations: <I extends { name: string }>(defaults: I[]) => defaults.filter((i) => keptIntegrations[i.name]),
    beforeSend: scrubEvent,
  };
}
