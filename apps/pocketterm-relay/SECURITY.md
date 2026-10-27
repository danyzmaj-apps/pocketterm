# Push relay: who can see what

The relay is run by Danijel Lovric (the publisher) on his own server in Germany (danyzmaj-server, OVHcloud), behind a
Cloudflare tunnel, at https://push.danyzmaj.com. It is used only if you turn notifications on in the phone app. A push
goes:

```
your computer → your PocketTerm server → Cloudflare → the relay → Apple (APNs) or Google (FCM) → your phone
```

## What nobody but your phones can read

**The notification itself**: its title, its text, the session and its state. Your computer encrypts it (AES-256-GCM)
with that computer's own channel key before it leaves. That key exists only on the computer and on the phones that
scanned its code. Your server, Cloudflare, the relay, Apple and Google pass it along as ciphertext (`enc`). On the
phone, the notification extension (iPhone) or the app (Android) decrypts it. A phone without the key shows a plain
"PocketTerm".

## What each party can see

| Who                                                                | Sees                                                                                                                                                                                                                                            | Never sees                                                                                                                                                        |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Your PocketTerm server**                                         | your phones' push tokens (it stores them to send to them), the sessions each phone follows, the ciphertext, the opaque tags, a followed session's state                                                                                         | the notification text                                                                                                                                             |
| **Cloudflare** and anything else between your server and the relay | that your server's address sent an encrypted request of some size to push.danyzmaj.com, and the status code back                                                                                                                                | the device token, the tags, what kind of push it is: the whole request is sealed to the relay's key (X25519 + HKDF-SHA256 + AES-256-GCM, a fresh key per request) |
| **The relay** (in memory, for the length of one request)           | the device token, the ciphertext, the opaque tags, an iPhone Live Activity's state, your server's address (as Cloudflare reports it)                                                                                                            | the notification text, the computer id, the session key                                                                                                           |
| **Apple / Google**                                                 | the device token (they need it to find your phone), the ciphertext, the opaque tags, a generic "PocketTerm / Terminal" alert; for an iPhone Live Activity its **state in plain text**; for Android's coding-session notification, that it ended | the notification text, the computer id, the session key                                                                                                           |

The **opaque tags** say nothing without your computer's key. `tag` is the computer's push tag (an HMAC under its channel
key): your phone finds the key it belongs to among its own, and nobody else can tell which computer it is. `collapse`
and `ref` are a session's push tag (an HMAC of the session's key under the same key): a newer push for a session
replaces an older one, and an Android end names its session by it. No computer id, session key or name reaches the
relay, and it refuses any field not listed for each kind of push.

**Lock Screen updates (iPhone).** When you follow a session, iOS shows its state on the Lock Screen: working, needs you,
or finished. Apple doesn't let apps decrypt these updates, so this state travels unencrypted: one of `working`, `needs`,
`done`, `ended`, a timestamp, and for `needs` one of `question`, `approval`, `plan`. It never includes any text from
your sessions, and it carries no names, folders or ids: the push goes to the activity's own token, which is all Apple
needs, and the relay rebuilds it from those checked fields only. Which session the activity shows (its title, its
folder, the session a tap opens) is set on the phone when the activity starts and never travels. Apple, the relay and
your server can see the state; your server also knows which session each activity follows, to route its updates, and
never passes that on. It goes stale 3 minutes after the last update, and the server ends it when its computer hasn't
checked in for 3 minutes.

Android's coding-session notification is opened by the app, so its state travels encrypted with the computer's key
(`enc`, like a notification). Only its end can go in plain text, when the server ends it for a computer that went quiet:
`ended`, a timestamp and the session's opaque tag (`ref`), which the phone registered with your server.

## What the relay keeps

Nothing. No database, no volume, no files written; the container's filesystem is read-only.

- **Logs**: one line per push with the platform, the status code and how long it took, plus Apple's or Google's error
  reason on a 5xx. Never a token, an address or a body.
- **Metrics**: counts by method, status code and platform.
- **Rate limits**: counters in memory, keyed by HMAC-SHA256 of the caller's address (an IPv6 caller's /64) or the device
  token under a random salt that lives only in memory and is replaced every day. Gone on restart; one day's keys can't
  be linked to the next.

The relay's private key, the APNs key and the Firebase service account sit on the server in
`/etc/danyzmaj/pocketterm-relay/` (root and the deploy runner only), outside git and the image.

## What someone could do with it

- **Anyone who knows one of your device tokens** can make your phone show a generic "PocketTerm" alert, or move or end
  one of its Live Activities, and nothing more: real text needs your computer's key. Rate limits per address, per token,
  and for callers whose tokens keep turning out wrong make this slow and cheap to absorb.
- **Whoever runs the relay** (the publisher, or someone who broke into the server) sees device tokens and Live Activity
  states as they pass, and could send the same generic alerts. They still can't read a notification.
- **A recorded request** can't be opened later without the relay's private key; with it, it shows what the relay itself
  sees above.

## Don't want to trust it?

Run your own: a fork with its own phone app (its own bundle id and Firebase project) runs this relay with its own keys
and points its servers at it with `PUSH_RELAY_URL` and `PUSH_RELAY_KEY`. A relay only reaches apps signed with its own
APNs and Firebase credentials.

Report a vulnerability as in the repository's [SECURITY.md](../../SECURITY.md).
