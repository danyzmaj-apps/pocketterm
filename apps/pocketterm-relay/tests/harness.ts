// The relay in-process for `deno test`: every request it makes (APNs, FCM,
// Google's OAuth) goes to the fake network a test sets with [network], and
// requests to it are sealed to a throwaway relay key, the way a server seals them.

import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import { type RelayKey, relayKey } from "../src/seal.ts";

export type Route = (req: Request) => Response | Promise<Response>;

const unexpected: Route = (req) => {
  throw new Error(`unexpected request: ${req.method} ${req.url}`);
};

let route: Route = unexpected;

/** What the relay sent, oldest first, since the last [network]. */
export const sent: { method: string; url: URL; headers: Headers; body: string }[] = [];

globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
  const req = new Request(input, init);
  sent.push({ method: req.method, url: new URL(req.url), headers: req.headers, body: await req.clone().text() });
  return await route(req);
};

/** Answers the relay's requests with [r] from now on; forgets what was sent. */
export function network(r: Route = unexpected) {
  route = r;
  sent.length = 0;
}

/** A throwaway private key made for this run only, in PEM (PKCS#8). */
export async function pem(algorithm: EcKeyGenParams | RsaHashedKeyGenParams | { name: "X25519" }): Promise<string> {
  const usages: KeyUsage[] = algorithm.name === "X25519" ? ["deriveBits"] : ["sign", "verify"];
  const pair = await crypto.subtle.generateKey(algorithm, true, usages) as CryptoKeyPair;
  const der = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  return `-----BEGIN PRIVATE KEY-----\n${encodeBase64(new Uint8Array(der))}\n-----END PRIVATE KEY-----\n`;
}

/** A throwaway relay key pair. */
export const testKey = async (): Promise<RelayKey> => relayKey(await pem({ name: "X25519" }));

const info = new TextEncoder().encode("pocketterm-relay/v1");

/** [plain] sealed to [publicKey] (v1), as packages/pocketterm_server/lib/src/relay.dart seals it. */
export async function seal(publicKey: Uint8Array<ArrayBuffer>, plain: string): Promise<string> {
  const eph = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]) as CryptoKeyPair;
  const epk = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const peer = await crypto.subtle.importKey("raw", publicKey, { name: "X25519" }, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "X25519", public: peer }, eph.privateKey, 256);
  const ikm = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const salt = new Uint8Array([...epk, ...publicKey]);
  const key = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const n = crypto.getRandomValues(new Uint8Array(12));
  const c = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: n }, key, new TextEncoder().encode(plain)),
  );
  return JSON.stringify({ v: 1, epk: encodeBase64(epk), n: encodeBase64(n), c: encodeBase64(c) });
}

/** A POST of [body] sealed to [key], as a server sends it (a string body goes as it is, sealed). */
export const post = async (key: RelayKey, body: unknown, headers: Record<string, string> = {}) =>
  new Request("http://relay.test/v1/push", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: await seal(key.publicKey, typeof body === "string" ? body : JSON.stringify(body)),
  });

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
