# PocketTerm server image. Build from the repository root:
#   docker build -f apps/pocketterm-server/Dockerfile -t pocketterm-server .
FROM dart:3.13.4 AS build
WORKDIR /src
# Only the server's two workspace members: a workspace of just them, resolved against the repository's lock file.
COPY pubspec.lock ./
COPY packages/pocketterm_server/pubspec.yaml packages/pocketterm_server/
COPY apps/pocketterm-server/pubspec.yaml apps/pocketterm-server/
RUN printf 'name: pocketterm_workspace\npublish_to: none\nenvironment:\n  sdk: ^3.13.4\nworkspace:\n  - packages/pocketterm_server\n  - apps/pocketterm-server\n' > pubspec.yaml \
 && dart pub get
COPY packages/pocketterm_server packages/pocketterm_server
COPY apps/pocketterm-server apps/pocketterm-server
RUN dart pub get --offline \
 && dart compile exe apps/pocketterm-server/bin/pocketterm_server.dart -o /pocketterm-server \
 && mkdir /data

# The Dart image's /runtime holds the few system files an AOT executable needs (libc, CA certificates…).
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /pocketterm-server /usr/local/bin/pocketterm-server
COPY --from=build --chown=65532:65532 /data /data
ENV PATH=/usr/local/bin \
    POCKETTERM_DATA=/data \
    POCKETTERM_PORT=47900 \
    POCKETTERM_ADDRESS=0.0.0.0
USER 65532:65532
VOLUME /data
EXPOSE 47900
ENTRYPOINT ["pocketterm-server"]
CMD ["serve"]
