// The relay's rate limits. It takes calls from every PocketTerm server without
// credentials (a server has nothing the publisher gave it), so it limits what
// one caller, or one device, can make it do. Counts live in memory only and go
// with a restart: best effort, enough to make a flood from one address cheap
// without storing anything. Keys are HMACs (Keyer), never an address or a token.

/** At most [max] hits per key in each window of [windowMs]. */
export class Limiter {
  readonly #counts = new Map<string, { start: number; count: number }>();

  constructor(
    readonly max: number,
    readonly windowMs: number,
    /** Keys kept at once; past it, finished windows go first, then the oldest. */
    readonly maxKeys = 10_000,
  ) {}

  /** Whether [key] has used its [max] hits in the current window. */
  full(key: string, now = Date.now()): boolean {
    const c = this.#counts.get(key);
    return c !== undefined && now - c.start < this.windowMs && c.count >= this.max;
  }

  /** Counts a hit for [key]; false (and not counted) when its window is full. */
  take(key: string, now = Date.now()): boolean {
    if (this.full(key, now)) return false;
    const c = this.#counts.get(key);
    if (c && now - c.start < this.windowMs) {
      c.count++;
    } else {
      this.#counts.delete(key);
      this.#counts.set(key, { start: now, count: 1 });
      this.#trim(now);
    }
    return true;
  }

  #trim(now: number) {
    if (this.#counts.size <= this.maxKeys) return;
    for (const [key, c] of this.#counts) {
      if (now - c.start >= this.windowMs) this.#counts.delete(key);
    }
    // Insertion order: the oldest windows first.
    for (const key of this.#counts.keys()) {
      if (this.#counts.size <= this.maxKeys) break;
      this.#counts.delete(key);
    }
  }
}

const minute = 60_000;

/**
 * The relay's limits. Servers behind one NAT or cloud egress share an address,
 * so the per-caller one is generous; a device rarely gets more than a few pushes
 * a minute; and a caller whose tokens keep coming back unknown or malformed
 * (guessing tokens) is turned away for a while.
 */
export function relayLimits() {
  return {
    caller: new Limiter(600, minute),
    token: new Limiter(60, minute),
    bad: new Limiter(30, 10 * minute),
  };
}

/**
 * The caller as Cloudflare (the tunnel in front of the relay) gives its address, counted as pocketterm-server's redeem
 * throttle counts one: an IPv4 address as itself, an IPv4-mapped IPv6 one as its IPv4 address, any other IPv6 address
 * as its /64 (`2001:db8:1:2::/64`): one machine or home gets a whole /64, so its addresses would otherwise be fresh
 * counters. Null when nothing trustworthy names it.
 */
export function callerOf(req: Request): string | null {
  const address = req.headers.get("cf-connecting-ip")?.trim();
  if (!address) return null;
  return address.includes(":") ? ipv6Network(address) ?? address : address;
}

/** [address]'s /64, or its IPv4 address when it is IPv4-mapped; null when it isn't IPv6. */
function ipv6Network(address: string): string | null {
  let host: string;
  try {
    // The URL parser checks the address and writes it canonically (lowercase, hex only, "::" for the longest zeros).
    host = new URL(`http://[${address}]/`).hostname.slice(1, -1);
  } catch {
    return null;
  }
  const [head, tail] = host.includes("::") ? host.split("::") : [host, null];
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = [...left, ...Array(8 - left.length - right.length).fill("0"), ...right].map((g) => parseInt(g, 16));
  if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
    return [groups[6] >> 8, groups[6] & 255, groups[7] >> 8, groups[7] & 255].join(".");
  }
  return `${groups.slice(0, 4).map((g) => g.toString(16)).join(":")}::/64`;
}

const day = 24 * 60 * 60_000;

/**
 * Rate-limit keys: HMAC-SHA256 of an address or a token under a random salt
 * made in memory and replaced every day. The counters never hold the value
 * itself, and nothing links one day's keys to the next.
 */
export class Keyer {
  #salt: Promise<CryptoKey> | null = null;
  #since = 0;

  /** The counter key for [value] (its HMAC, as a binary string) at [now]. */
  async key(value: string, now = Date.now()): Promise<string> {
    if (!this.#salt || now - this.#since >= day) {
      this.#since = now;
      this.#salt = crypto.subtle.generateKey({ name: "HMAC", hash: "SHA-256" }, false, ["sign"]) as Promise<CryptoKey>;
    }
    const mac = await crypto.subtle.sign("HMAC", await this.#salt, new TextEncoder().encode(value));
    return String.fromCharCode(...new Uint8Array(mac));
  }
}
