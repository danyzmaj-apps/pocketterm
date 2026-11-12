# PocketTerm's push relay. Deployed by Baker's Relay workflow on
# danyzmaj-server (deploy/compose.yaml); secrets come in as files under /run/secrets.
FROM denoland/deno:alpine-2.9.6
WORKDIR /app
COPY --chmod=755 deno.json deno.lock main.ts ./
COPY --chmod=755 src ./src
# Fetch the dependencies at build time (pinned by deno.lock), so the running relay
# loads nothing and reaches nothing but Apple, Google and (with SENTRY_DSN) GlitchTip.
RUN deno cache --frozen main.ts && chown -R deno:deno /deno-dir
USER deno
EXPOSE 8080
CMD ["run", "--allow-net", "--allow-env", "--allow-read=/run/secrets", "--cached-only", "--frozen", "main.ts"]
