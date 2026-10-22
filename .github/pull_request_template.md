## What a user will notice

<!-- One change per PR. For anything bigger than a fix, link the issue where we agreed on the shape. -->

## Checklist

- [ ] The checks in [CONTRIBUTING.md](https://github.com/danyzmaj-apps/pocketterm/blob/main/CONTRIBUTING.md#pull-requests) pass
- [ ] Desktop changes work on macOS and Windows, phone changes on iPhone and Android (or say which one can't, and why)
- [ ] User-visible changes are in the next version's `## <version>` section of `CHANGELOG.md`, saying whether servers or the relay must be updated
- [ ] Server API changes are in `packages/pocketterm_server/PROTOCOL.md`, and the PR says whether apps and servers of different versions still work together
