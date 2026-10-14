// functions/pair: redeeming a code (normalised, throttled per trusted caller)
// and what the reviewer demo account may do.
import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import { handlerOf, json, network, post, sent, sha256, supabaseEnv } from "./harness.ts";

const pair = await handlerOf(() => import("../pair/index.ts"), supabaseEnv);

const owner = {
  id: "00000000-0000-0000-0000-00000000000a",
  email: "owner@example.com",
  app_metadata: { provider: "github" },
};
const demo = {
  id: "00000000-0000-0000-0000-00000000000d",
  email: "reviewer@x.dzep.invalid",
  app_metadata: { provider: "email", dzep_demo: true },
};

/** A Supabase that signs in [user], redeems to [redeemed] and answers reviewer_access_active with [active]. */
function supabase(opts: { user?: typeof owner; redeemed?: unknown; active?: boolean } = {}) {
  network(async (req) => {
    const { pathname } = new URL(req.url);
    if (pathname === "/rest/v1/rpc/redeem_pairing_code") return json(opts.redeemed ?? { error: "invalid" });
    if (pathname === `/auth/v1/admin/users/${owner.id}`) return json(owner);
    if (pathname === "/auth/v1/admin/generate_link") {
      const { email } = await req.json();
      return json({
        ...owner,
        email,
        action_link: "",
        email_otp: "",
        hashed_token: "magic-token-hash",
        verification_type: "magiclink",
      });
    }
    if (pathname === "/auth/v1/user") return opts.user ? json(opts.user) : json({ msg: "bad jwt" }, 401);
    if (pathname === "/rest/v1/rpc/reviewer_access_active") return json(opts.active ?? true);
    if (pathname === "/rest/v1/pairing_codes" && req.method === "DELETE") return new Response(null, { status: 204 });
    if (pathname === "/rest/v1/pairing_codes" && req.method === "POST") return json({ id: "new-code" }, 201);
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
}

/** What redeem_pairing_code was called with. */
const redeemArgs = () => JSON.parse(sent.find((r) => r.url.pathname === "/rest/v1/rpc/redeem_pairing_code")!.body);

Deno.test("a code typed loosely is the code: case, separators and look-alikes don't matter", async () => {
  supabase({ redeemed: { user_id: owner.id } });
  const res = await pair(post({ action: "redeem", code: "o-l23 4567 89ab cdef ghjk mnpq rstv" }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { token_hash: "magic-token-hash" });
  assertEquals(redeemArgs().p_hash, await sha256("0123456789ABCDEFGHJKMNPQRSTV"));
  const link = sent.find((r) => r.url.pathname === "/auth/v1/admin/generate_link")!;
  assertEquals(JSON.parse(link.body).type, "magiclink");
  assertEquals(JSON.parse(link.body).email, owner.email);
});

Deno.test("a code of the wrong length fails, and still counts for the throttle", async () => {
  supabase();
  const res = await pair(post({ action: "redeem", code: "K7QM-3XRT" }));
  assertEquals(res.status, 400);
  assertMatch((await res.json()).error, /doesn't work/);
  assertEquals(redeemArgs().p_hash, "", "no hash: nothing can match");
});

Deno.test("the throttle trusts only the caller address Cloudflare sets", async () => {
  supabase();
  await pair(
    post({ action: "redeem", code: "x" }, { "cf-connecting-ip": "198.51.100.7", "x-forwarded-for": "10.0.0.1" }),
  );
  assertEquals(redeemArgs().p_ip, "198.51.100.7");
  supabase();
  await pair(post({ action: "redeem", code: "x" }, { "x-forwarded-for": "10.0.0.1", "x-real-ip": "10.0.0.2" }));
  assertEquals(redeemArgs().p_ip, null, "client-written headers name nobody");
});

Deno.test("a throttled caller is told to wait", async () => {
  supabase({ redeemed: { error: "throttled" } });
  assertEquals((await pair(post({ action: "redeem", code: "x" }))).status, 429);
});

Deno.test("the demo account makes phone codes only while a reviewer code works", async () => {
  supabase({ user: demo, active: false });
  const ended = await pair(post({ action: "create" }, { authorization: "Bearer demo-token" }));
  assertEquals(ended.status, 403);
  assertMatch((await ended.json()).error, /reviewer access has ended/);
  assertEquals(sent.filter((r) => r.url.pathname === "/rest/v1/pairing_codes").length, 0, "no code was made");
  const check = sent.find((r) => r.url.pathname === "/rest/v1/rpc/reviewer_access_active")!;
  assertEquals(check.headers.get("authorization"), "Bearer demo-token", "checked as the demo account itself");

  supabase({ user: demo, active: true });
  const res = await pair(post({ action: "create" }, { authorization: "Bearer demo-token" }));
  assertEquals(res.status, 200);
  assertMatch((await res.json()).code, /^([0-9A-Z]{4}-){6}[0-9A-Z]{4}$/);
});

Deno.test("the owner's phone codes don't ask about reviewer access", async () => {
  supabase({ user: owner });
  assertEquals((await pair(post({ action: "create" }, { authorization: "Bearer owner-token" }))).status, 200);
  assertEquals(sent.some((r) => r.url.pathname === "/rest/v1/rpc/reviewer_access_active"), false);
});

Deno.test("the demo account can't make or revoke reviewer codes", async () => {
  for (const body of [{ action: "reviewer" }, { action: "list" }, { action: "revoke", id: "x" }]) {
    supabase({ user: demo });
    assertEquals((await pair(post(body, { authorization: "Bearer demo-token" }))).status, 403, body.action);
  }
});

Deno.test("everything but redeem needs a sign-in", async () => {
  supabase();
  assertEquals((await pair(post({ action: "create" }))).status, 401);
});

/** A lone surrogate: half a character, which Postgres refuses in JSON. */
const halfCharacter = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

Deno.test("a long reviewer label is cut between characters, never through one", async () => {
  network((req) => {
    const { pathname } = new URL(req.url);
    if (pathname === "/auth/v1/user") return json(owner);
    if (pathname === "/rest/v1/rpc/pairing_demo_user") return json(demo.id);
    if (pathname === "/rest/v1/pairing_codes" && req.method === "POST") return json({ id: "new-code" }, 201);
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
  const res = await pair(
    post({ action: "reviewer", days: 7, label: `a${"😀".repeat(40)}` }, { authorization: "Bearer owner-token" }),
  );
  assertEquals(res.status, 200);
  const label: string = JSON.parse(sent.find((r) => r.url.pathname === "/rest/v1/pairing_codes")!.body).label;
  assertEquals(halfCharacter.test(label), false, "no half character reaches the database");
  assertEquals(label, `a${"😀".repeat(39)}`);
});
