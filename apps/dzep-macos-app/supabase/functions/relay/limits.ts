// The relay's rate limits. It takes calls from every Džep server without
// credentials (a server has nothing the publisher gave it), so it limits what
// one caller, or one device, can make it do. Counts live in this instance's
// memory: Supabase runs a few instances and recycles them every few minutes,
// so a limit is per instance and best effort, enough to make a flood from one
// address cheap without a table on the relay's project.

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
 * The relay's limits. Real servers share Supabase's few egress addresses, so
 * the per-caller one is generous; a device rarely gets more than a few pushes
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

/** The caller's address as Cloudflare (in front of Supabase's edge) gives it; null when nothing trustworthy does. */
export const callerOf = (req: Request): string | null => req.headers.get("cf-connecting-ip")?.trim() || null;
