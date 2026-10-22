// Sealed relay requests (v1). A sender seals each request body to the relay's
// static X25519 public key, so whatever carries it (Cloudflare, proxies, logs)
// sees only ciphertext, device tokens included:
//
//   ephemeral X25519 key pair (esk, epk); shared = X25519(esk, relay public key)
//   key = HKDF-SHA256(ikm: shared, salt: epk ‖ relay public key, info: "pocketterm-relay/v1", 32 bytes)
//   c   = AES-256-GCM(key, nonce n: 12 random bytes, the JSON body) ‖ 16-byte tag
//   body: {"v": 1, "kid": key id, "epk": base64(32 bytes), "n": base64(12 bytes), "c": base64(c)}
//
// A fresh ephemeral key per request: no two requests share a key, and a
// recorded request can't be opened without the relay's private key.
// Sender: packages/pocketterm_server/lib/src/relay.dart.
//
// Key rotation: the relay may hold its current key and the previous one. kid
// (the first 11 characters of the public key's base64) names the one a request
// was sealed to; a request without it (servers from before) is tried with each.

import { decodeBase64, encodeBase64 } from "jsr:@std/encoding@1/base64";
import { decodeBase64Url } from "jsr:@std/encoding@1/base64url";

const info = new TextEncoder().encode("pocketterm-relay/v1");

/** The relay's key pair: the private half for opening, the public half (raw 32 bytes) for the KDF salt. */
export type RelayKey = { privateKey: CryptoKey; publicKey: Uint8Array<ArrayBuffer> };

/** The relay's key pair from a PKCS#8 PEM X25519 private key (`openssl genpkey -algorithm X25519`). */
export async function relayKey(pem: string): Promise<RelayKey> {
  const der = decodeBase64(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s/g, ""));
  const privateKey = await crypto.subtle.importKey("pkcs8", der, { name: "X25519" }, true, ["deriveBits"]);
  const jwk = await crypto.subtle.exportKey("jwk", privateKey);
  if (!jwk.x) throw new Error("the X25519 key has no public half");
  return { privateKey, publicKey: decodeBase64Url(jwk.x) };
}

/** The relay's public key as senders configure it: base64 of the raw 32 bytes. */
export const publicKeyText = (key: RelayKey) => encodeBase64(key.publicKey);

/** The id senders put in `kid`: the first 11 characters of [publicKeyText]. */
export const keyId = (key: RelayKey) => publicKeyText(key).slice(0, 11);

function field(o: Record<string, unknown>, name: string, length?: number): Uint8Array<ArrayBuffer> | null {
  const v = o[name];
  if (typeof v !== "string") return null;
  try {
    const bytes = decodeBase64(v);
    return length === undefined || bytes.length === length ? bytes : null;
  } catch {
    return null;
  }
}

/**
 * The plain body of a sealed request [text], or null when it isn't one sealed to one of [keys] (or was changed).
 * The key its kid names is tried first; without a kid, or with one no key has, each in turn.
 */
export async function unseal(keys: RelayKey | RelayKey[], text: string): Promise<Uint8Array | null> {
  let o: unknown;
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  if (!o || typeof o !== "object" || Array.isArray(o)) return null;
  const sealed = o as Record<string, unknown>;
  if (sealed.v !== 1) return null;
  const epk = field(sealed, "epk", 32);
  const n = field(sealed, "n", 12);
  const c = field(sealed, "c");
  if (!epk || !n || !c || c.length < 16) return null;
  const all = Array.isArray(keys) ? keys : [keys];
  const named = all.find((k) => keyId(k) === sealed.kid);
  for (const key of named ? [named] : all) {
    const plain = await open(key, epk, n, c);
    if (plain) return plain;
  }
  return null;
}

async function open(
  key: RelayKey,
  epk: Uint8Array<ArrayBuffer>,
  n: Uint8Array<ArrayBuffer>,
  c: Uint8Array<ArrayBuffer>,
): Promise<Uint8Array | null> {
  try {
    const peer = await crypto.subtle.importKey("raw", epk, { name: "X25519" }, false, []);
    const shared = new Uint8Array(
      await crypto.subtle.deriveBits({ name: "X25519", public: peer }, key.privateKey, 256),
    );
    // A low-order epk gives an all-zero secret anyone could compute.
    if (shared.every((b) => b === 0)) return null;
    const ikm = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
    const salt = new Uint8Array(64);
    salt.set(epk);
    salt.set(key.publicKey, 32);
    const aes = await crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt, info },
      ikm,
      { name: "AES-GCM", length: 256 },
      false,
      ["decrypt"],
    );
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: n }, aes, c));
  } catch {
    return null;
  }
}
