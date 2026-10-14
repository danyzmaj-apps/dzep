// functions/device: what a widget or a notification's Done action may do with a device token.
import { assertEquals } from "jsr:@std/assert@1";
import { handlerOf, json, network, post, supabaseEnv } from "./harness.ts";

const device = await handlerOf(() => import("../device/index.ts"), supabaseEnv);

const token = { "x-dzep-token": "t".repeat(43) };

Deno.test("a body that isn't an object is refused, not a crash", async () => {
  network((req) => {
    const { pathname } = new URL(req.url);
    if (pathname === "/rest/v1/device_tokens" && req.method === "GET") {
      return json({ id: "d1", user_id: "00000000-0000-0000-0000-00000000000a", label: "phone" });
    }
    if (pathname === "/rest/v1/device_tokens") return new Response(null, { status: 204 });
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
  assertEquals((await device(post("null", token))).status, 400);
});
