// functions/relay/limits.ts: the relay's per-key windows.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { callerOf, Limiter } from "../relay/limits.ts";

Deno.test("a key gets max hits per window, then waits for the next window", () => {
  const limit = new Limiter(3, 1000);
  assertEquals([0, 1, 2, 3].map(() => limit.take("a", 0)), [true, true, true, false]);
  assert(limit.full("a", 999));
  assert(!limit.full("b", 999), "keys don't share a window");
  assert(limit.take("a", 1000), "a new window starts afresh");
  assert(!limit.full("a", 1000));
});

Deno.test("past maxKeys, finished windows go first, then the oldest", () => {
  const limit = new Limiter(1, 1000, 2);
  limit.take("old", 0);
  limit.take("kept", 1500);
  limit.take("new", 1600); // "old" has run out: it goes, the others stay full
  assert(limit.full("kept", 1600) && limit.full("new", 1600));
  limit.take("newer", 1700); // none finished: the oldest ("kept") goes
  assert(!limit.full("kept", 1700));
  assert(limit.full("new", 1700) && limit.full("newer", 1700));
});

Deno.test("the caller is who Cloudflare says, never what the client says", () => {
  const req = (headers: Record<string, string>) => new Request("http://x/", { headers });
  assertEquals(callerOf(req({ "cf-connecting-ip": " 192.0.2.1 " })), "192.0.2.1");
  assertEquals(callerOf(req({ "x-forwarded-for": "192.0.2.1", "x-real-ip": "192.0.2.2" })), null);
  assertEquals(callerOf(req({})), null);
});
