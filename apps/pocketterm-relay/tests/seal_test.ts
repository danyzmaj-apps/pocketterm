// src/seal.ts against requests the PocketTerm server sealed (vectors.json, written by
// packages/pocketterm_server/tool/relay_vectors.dart): they open, and nothing changed or meant for
// another key does.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { decodeBase64, encodeBase64 } from "jsr:@std/encoding@1/base64";
import { keyId, type RelayKey, relayKey, unseal } from "../src/seal.ts";
import { seal, testKey } from "./harness.ts";

type Vectors = {
  relayPrivate: string;
  relayPublic: string;
  cases: { plain: string; sealed: { v: number; epk: string; n: string; c: string } }[];
};
const vectors: Vectors = JSON.parse(await Deno.readTextFile(new URL("./vectors.json", import.meta.url)));

// PKCS#8 for an X25519 private key: a fixed prefix, then the 32 bytes.
const pkcs8 = new Uint8Array([
  ...[0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20],
  ...decodeBase64(vectors.relayPrivate),
]);
const key: RelayKey = await relayKey(`-----BEGIN PRIVATE KEY-----\n${encodeBase64(pkcs8)}\n-----END PRIVATE KEY-----`);
const open = async (k: RelayKey, sealed: unknown) => {
  const plain = await unseal(k, JSON.stringify(sealed));
  return plain && new TextDecoder().decode(plain);
};

/** [b64] with one bit flipped in byte [at]. */
function flip(b64: string, at = 0): string {
  const bytes = decodeBase64(b64);
  bytes[at] ^= 1;
  return encodeBase64(bytes);
}

Deno.test("the relay's public key is the one the server sealed to", () => {
  assertEquals(encodeBase64(key.publicKey), vectors.relayPublic);
});

Deno.test("what the Dart server sealed, the relay opens", async () => {
  assert(vectors.cases.length > 0);
  for (const { plain, sealed } of vectors.cases) assertEquals(await open(key, sealed), plain);
});

Deno.test("a changed request opens to nothing", async () => {
  for (const { sealed } of vectors.cases) {
    const c = decodeBase64(sealed.c);
    for (
      const changed of [
        { ...sealed, c: flip(sealed.c) },
        { ...sealed, c: flip(sealed.c, c.length - 1) }, // the tag
        { ...sealed, n: flip(sealed.n) },
        { ...sealed, epk: flip(sealed.epk) },
        { ...sealed, c: encodeBase64(c.subarray(0, c.length - 1)) },
        { ...sealed, v: 2 },
        { ...sealed, epk: encodeBase64(new Uint8Array(32)) }, // a low-order point
        { epk: sealed.epk, n: sealed.n, c: sealed.c },
      ]
    ) {
      assertEquals(await open(key, changed), null, JSON.stringify(changed).slice(0, 80));
    }
  }
});

Deno.test("another relay's key opens nothing", async () => {
  const other = await testKey();
  for (const { sealed } of vectors.cases) assertEquals(await open(other, sealed), null);
});

Deno.test("what isn't a sealed request is refused", async () => {
  for (const text of ["", "null", "[]", '{"token":"abc","kind":"terminal"}', '{"v":1,"epk":"%%","n":"","c":""}']) {
    assertEquals(await unseal(key, text), null, text);
  }
});

Deno.test("while the key rotates, requests sealed to the new key or the old one open; others don't", async () => {
  const fresh = await testKey();
  const old = await testKey();
  const keys = [fresh, old];
  const plain = '{"token":"t"}';
  const text = async (k: RelayKey, kid?: string) => {
    const sealed = JSON.parse(await seal(k.publicKey, plain));
    return JSON.stringify(kid === undefined ? sealed : { ...sealed, kid });
  };
  const opened = async (t: string) => {
    const p = await unseal(keys, t);
    return p && new TextDecoder().decode(p);
  };
  assertEquals(await opened(await text(fresh, keyId(fresh))), plain);
  assertEquals(await opened(await text(old, keyId(old))), plain);
  // A server from before kid.
  assertEquals(await opened(await text(old)), plain);
  // A kid naming a key the relay doesn't have yet: every key is tried.
  assertEquals(await opened(await text(old, "AAAAAAAAAAA")), plain);
  // A kid naming one key never opens what was sealed to the other.
  assertEquals(await opened(await text(old, keyId(fresh))), null);
  assertEquals(await opened(await text(await testKey())), null);
});
