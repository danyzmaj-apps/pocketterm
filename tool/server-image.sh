#!/usr/bin/env bash
# Builds the PocketTerm server image (apps/pocketterm-server/Dockerfile) for amd64 and arm64 and pushes it to
# ghcr.io/danyzmaj-apps/pocketterm-server, as Baker's "Server image" workflow does on every release tag:
# v0.2.0 -> :0.2.0, :0.2 and :latest; a prerelease tag (v0.2.0-rc.1) gets only its own version, so :latest stays
# on the last release.
#
#   tool/server-image.sh [<tag>] [--dry-run]
#
# <tag> defaults to the tag on HEAD. --dry-run builds both platforms and pushes nothing. Pushing logs in to
# ghcr.io with the gh CLI's token, which needs the write:packages scope (gh auth refresh -s write:packages).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=ghcr.io/danyzmaj-apps/pocketterm-server
BUILDER=pocketterm-image
TAG="" DRY=0
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) TAG=$a ;;
  esac
done
[ -n "$TAG" ] || TAG=$(git describe --tags --exact-match HEAD 2>/dev/null) ||
  { echo "HEAD has no tag: give one (v1.2.3)" >&2; exit 2; }
[[ $TAG =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?$ ]] ||
  { echo "not a release tag: $TAG (v1.2.3 or v1.2.3-rc.1)" >&2; exit 2; }
VERSION=${TAG#v}
NAMES=("$IMAGE:$VERSION")
if [ -z "${BASH_REMATCH[4]}" ]; then
  NAMES+=("$IMAGE:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "$IMAGE:latest")
fi
TAGS=()
for n in "${NAMES[@]}"; do TAGS+=(-t "$n"); done

# A docker-container builder: the plain docker driver can't push one image for two platforms.
docker buildx inspect "$BUILDER" >/dev/null 2>&1 || docker buildx create --name "$BUILDER" --driver docker-container >/dev/null

if [ "$DRY" = 1 ]; then
  OUT=(--output type=cacheonly)
else
  gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin >/dev/null
  OUT=(--push)
fi
echo "$TAG -> ${NAMES[*]}$([ "$DRY" = 1 ] && echo ' (dry run: nothing pushed)')"
docker buildx build --builder "$BUILDER" \
  --platform linux/amd64,linux/arm64 \
  -f apps/pocketterm-server/Dockerfile \
  --label org.opencontainers.image.source=https://github.com/danyzmaj-apps/pocketterm \
  --label "org.opencontainers.image.version=$VERSION" \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  "${TAGS[@]}" "${OUT[@]}" .
