# Cross-language test vectors

`vectors.json` is the frozen contract that every native PocketTerm port (iOS and macOS in Swift,
Android in Kotlin, Windows in C#) tests against. It pins the behaviour that has to match across
devices: the end-to-end crypto, replay protection, setup links, the live protocol's helpers and frames,
ANSI parsing, file types and the terminal helpers.

Every expected value was computed by the Dart code in `packages/pocketterm_core` at commit `480d6f0`.
A throwaway generator called the real Dart functions; it was deleted after the run, and nothing was
written by hand. Inputs that came from the Dart tests (screens, frames, environments) are kept as they were.
The Dart package is going away, so this file is not regenerated. To change the contract, edit this file
and every port together.

## Conventions

- **Bytes** are standard base64 with padding (`sealed`, `plain`, `nonce`, `enc`) unless a field says
  `hex`. Channel keys are given as `hex`, `base64` and `base64url` (no padding).
- **Strings** are JSON strings. Escape sequences show as `\u001b`, and Dart's `\r`, `\t` and so on as JSON escapes.
  Dart strings are UTF-16. Wherever a helper counts "characters" (`textChunks`, `jsonBytes`,
  `cleanTitle`, `screenLines`), surrogate pairs count as Dart counts them, and the cases include emoji.
- **`note`**: every case has a short note that says what it pins. Some notes also describe the setup.
- **`null`** means "none": no result, refused, or dropped, as the note says.
- **Repeated inputs**: `{"repeat": u, "times": n}` means `u` repeated `n` times. `"then": s` adds `s`
  after the repeats, and `"prefix": p` adds `p` before them.
- **Summaries**: very long outputs are given as
  `{codeUnits, utf8Bytes, jsonBytes, sha256 (of the UTF-8), head, tail}`. `head` and `tail` are the first
  and last 40 code points.
- **Random parts are frozen outputs.** Nonces, `mid`, `ep`, and the `ts` and `id` inside notices came out
  of the run. Ports must *open* these vectors. They can't reproduce them, except for `crypto.sealFixedNonce`.

## Sections

### `crypto`
Uses AES-256-GCM. Sealed bytes are `nonce(12) || ciphertext || tag(16)`, and the AAD is the UTF-8 of the AAD string.

| key | schema |
| --- | --- |
| `constants` | `nonceLength`, `tagLength`, `sealedOverhead` (28), `envelopeVersion` (1), `keyLength` (32) |
| `keys` | named keys `key` (bytes 0..31, used by every case unless named), `other` (255..224), `seven`, `nine`. Each has `hex`, `base64`, `base64url`. `base64url` without padding is the form the QR or setup link carries as `k` |
| `keyParse` | `ChannelKey.tryParse(input)`: `hex` of the key, or `null`. It takes both alphabets, with or without padding, and trims whitespace. A `+` turned into a space is not a key |
| `aad` | the AAD strings: `channel(topic, event)` = `pocketterm/v1\|<topic>\|<event>`, `image(path)`, `push(desktop)`, `activity(desktop)` |
| `pushTag` | `key` name → `tag` (the first 8 bytes of HMAC-SHA256(key, `pocketterm/v1\|push-tag`), base64url without padding) |
| `sessionTag` | `key`, `routedKey` → `tag` (the first 16 bytes of HMAC-SHA256(key, `pocketterm/v1\|push-session\|<routedKey>`)) |
| `open` | `sealed` must open with `key` and `aad` to `plain`. Includes empty, binary, non-ASCII and empty-AAD cases |
| `sealFixedNonce` | sealing `plain` with `key`, `aad` and the given `nonce` must give exactly `sealed`. Use this to test the seal path with an injected nonce |
| `openFails` | `openBytes` result: `plain` (base64), or `null`. The cases are a control, wrong AAD, wrong key, flipped nonce, ciphertext or tag bytes, and truncated or empty input |
| `envelopes` | live-channel envelopes `{v, n, c}`, sealed by a sender's `ChannelSeal` for `topic`/`event`. `message` is the opened inner object `{m, ts, mid, ep, seq}`, and `m` is the event payload |
| `envelopeDrops` | `openEnvelope(key, envelope, aad)` gives `drop` (`version`, `sealed` or `json`, or `null`) and `message`. Note: Dart's `base64Decode` accepts missing padding and the base64url alphabet, so those two cases **open** |
| `channelOpen` | `ChannelSeal.open` on one receiver. The first row gives the guard's `startMs` (clock = start). Each later row has `nowMs`, `event`, `envelope` and `payload` (the opened `m`, or `null` = dropped: replay, order, no `m`, or `m` not an object) |
| `notices` / `activities` | `sealNotice` / `sealActivity(key, desktop, input)`. `enc` is base64 of the sealed bytes for AAD `aad`. `inner` is the opened JSON: `input` plus `ts` (ms) and `id` (16 base64url characters). An activity never opens with the push AAD |
| `images` | an image blob sealed for its storage `path` (AAD `pocketterm/v1\|image\|<path>`). `opensWithOtherPath` is false |

### `replayGuard`
`scenarios[]` has `{startMs, windowMs, rememberMs, maxEpochs, maxIds, steps[]}`. Create a guard whose clock
reads `startMs` (that is its `notBefore`). For each step, set the clock to `nowMs` and call
`check(message)`. `result` is `null` (taken) or the drop reason: `time`, `replay` or `order`.
The rules (`ReplayGuard.check`):

1. `ts` must be an int with `|now − ts| ≤ window` and `ts ≥ notBefore`. Otherwise the result is `time`.
2. `mid` and `ep` must be non-empty strings, and `seq` an int ≥ 1. Otherwise the result is `replay`.
3. Ids and epochs not seen for more than `remember` are forgotten.
4. A `mid` the guard holds gives `replay`. A `seq` at or below its epoch's last gives `order`, and the epoch
   moves to newest-seen without updating its time.
5. On accept, the epoch and the id are recorded as newest. Past `maxEpochs`/`maxIds`, the oldest go first.

### `links`
| key | schema |
| --- | --- |
| `parse` | `Backend.parse(input, kind)` gives `backend` `{url, kind, api, host, onTailnet, unreachable}` or `null`, plus `error` (worded for the user). Plain http is allowed only to `localhost`, `::1` or `127.*`. Every case has `kind` `pocketterm`, the only backend kind left |
| `build` | links a backend makes (`link`, `linkWithSetup`, `linkWithCode` with an optional `computer {desktop, keyHex}`) as `Uri.toString()` (query values percent-encoded) |
| `read` | a `link` string read as Dart's `Uri.parse` does (in `queryParameters`, `+` decodes as a space), giving `backend` `{url, kind}`, `pairingCode`, `setupToken` and `computerKey` `{desktop, keyHex}`, each `null` when absent. A link with `key=`, or an unknown `kind`, is no link |
| `clockWarning` | `offsetSeconds` (server ahead of device; `null` = unknown) → `warning`, or `null` within ±2 min. Minutes are rounded half away from zero (150 s → 3), as Dart's `round()` does |
| `constants` | `protocol`, `minServer`, `clockToleranceSeconds` |

### `localApiPing`
`cases[]`: `{token, port, nonce, nonceAccepted, proof}`. `proof` is the lowercase hex of
HMAC-SHA256(key = UTF-8 token, message = `"pocketterm-ping\n<port>\n<nonce>"`). It is the formula of
`LocalApi.pingProof` in apps/pocketterm-desktop/lib/local_api.dart, computed with the same `package:crypto`.
`nonceAccepted` follows the desktop's rule: 16 to 128 characters, else HTTP 400.

### `ansi`
`ansiSpans(input, TermColors.fallback)`. `colors` gives the fallback `foreground`, `background` and the
256-entry xterm `palette`. Each span is `{text, fg, bg, bold, italic, decoration}`. Colors are
`#AARRGGBB`, `bg: null` is no background, and `decoration` is `underline`, `lineThrough` or `null`
(underline wins). Dim draws `fg` at alpha 0.6 (`0x99`). Reverse swaps `fg`/`bg`, using the default background
when there is no `bg`. Spans are not merged; an empty input gives no spans. `termColorsFromJson` pins
`TermColors.fromJson` (0xRRGGBB ints, made opaque).

### `live`
| key | schema |
| --- | --- |
| `routedKey` / `splitRoutedKey` | `<desktop 8×[a-z0-9]>/<key>`. `result` `{desktop, key}` or `null` |
| `jsonBytes` | `input` (or, for a lone surrogate, `null`: use `utf16`, the code units) → `bytes` the string takes inside a JSON string, UTF-8 |
| `chunkJson` | `items`, `maxBytes` → `chunks` (each item counts its `jsonEncode` UTF-8 length + 1) |
| `constants` | `cutNote`, the item byte caps, chunk default, log/view caps, cache keep |
| `clip.cases` | items upserted into a `LiveLog`, with each stored field summarised: text keeps its start and ends with `cutNote`, tool output keeps its end after `…`. The last case covers streamed appends past the cap |
| `logScenario` | `LiveLog` snapshot → `steps` (`action` → the `ops` it returned, `null` = none) → `finalSeq`, `finalOlder`, `finalItems`, `since3`. Then a `LiveView` applies the wire ops: all, with a gap, and from another epoch |
| `viewCatchUp` | `LiveView.catchUp` steps from `initial`. `view` is `toJson()` after each step |
| `liveCommands` / `matchCommands` | the extension's `commands` parsed. Composer matches: `text`, `max` → `names` |
| `answerKeys` | `agent`, `ask` (LiveAsk JSON), `answers` (LiveAnswer JSON), `approve` → `steps`: `{"keys": [...]}` (kitty key names), `{"type": text}`, `{"settle": true}`, or `"error"` |
| `menuKeys` / `claudeRowKey` | cursor `current` → `target` key list (`"error"` for a negative row). Row index → digit |
| `parsePlanReview` | `agent`, `screen` (plain text) → `{options, current}` or `null` |
| `parseMenu` | `screen` → `{title, items[{label, detail}], current, filter}` or `null` |
| `askOnScreen` | `agent`, `ask`, `screen` → `onScreen` |
| `screenDiff` | `between(a, b)` → `diff` `{drop, keep, tail}` or `null`, plus `applied`; `apply` cases → `result` or `null` |
| `models` | for each model (`LiveItem`, `LiveQueued`, `LiveOp`, `LiveAsk` (+`text`), `LiveAnswer`, `LiveSummary`, `LiveView` (+`keep`), `TermWindow` (+`agent`), `TermStatus`, `ScreenDiff`, `AgentIntegration`): `input` → Dart `fromJson` then `toJson` = `output`. This is the canonical form |
| `agent` | per agent: `label`, `command`, `steers`, `commandIn`, `labelIn`, `resume`/`resumeIn` (with U+00A0 / U+2060), `pickUp`/`pickUpIn`. Also `parse`, `ofProgram`, `sessionOfTitle`, `isOmpProfile`, `ompProfileOfArgs` |
| `frames.channel` | live-channel events: `direction`, `event`, `payload` (the envelope's `m`), and `parsed` (model round trip) where one exists |
| `frames.local` | the local API's `/v1/live` frames (event in `t`), with `parsed` for `ask`, `item` and `commands` |

### `fileTypes`
`byName`: `name` → `extension` (after the last dot, lower case; empty when the dot is first or absent)
and `mime` (`application/octet-stream` when unknown). `extensionOf`: `mime` (parameters and case ignored)
→ the first `extension` of that type, or `null`.

### `chatImages`
`limits`: `maxChatAttachments` (10), `maxChatFileBytes` (20 MiB − 28), `maxBlobBytes`, `maxImageSide`,
`keepAsIsMaxBytes` (an image this small and within `maxImageSide` is sent as it is), and
`imageExtensions`. `imageExtensions` is copied from a private Dart constant; it is the only list not computed.
`sniffImageType`: `bytes` (hex) → `mime` (PNG, JPEG, GIF, WebP) or `null`.
`formatBytes`: `bytes` → `text` (1024-based, one decimal).

### `terminal`
| key | schema |
| --- | --- |
| `windowOfTerm` | `term` (the agent's raw environment; `null` = none) → window `key` or `null`. tmux wins, then the terminal `TERM_PROGRAM` names, then kitty variables |
| `tmuxSocketName` | `name` → `ok` |
| `keyBytes` | kitty key `name` → `bytes` (string) and `hex` (UTF-8), or `error` (the TerminalException message) |
| `keyRuns` / `phoneKeys` | key names → byte runs (Esc goes alone) / the keys the phone may press |
| `textChunks` | `text`, `maxBytes` → `chunks` (cut between characters only) |
| `cleanTitle` | `input` → `title`, at most `titleRunes` runes, ending with `…` when cut |
| `screenLines` | `input` → `lines`. `long` covers the history-budget cut, with summarised output |
| `processes` | `parsePs`, `foreground` (on the `parsePs` input), `parseTasklist`, `parseLsofCwd`, `programOf`, `programOfTitle`, `utf8Locale` |
| `windows` | `windowsFileName`, `windowsPathDirs`, `mergeWindowsPath`, `windowsCommand` (`program`, `argv`) |
| `shellQuote` | `input` → one POSIX shell word |
| `caps` | `TermCap` names in order (the order of `toJson`), `allCaps`, `TermState` names, `Placement.describe` |

### `desktops`
`Desktop.fromJson` → `toJson` (`seen_at` rewritten as UTC ISO-8601 with milliseconds), plus `windows`.
Also `onlineWithinSeconds` (150) and `keepForDays` (30).
