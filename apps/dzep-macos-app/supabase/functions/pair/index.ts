// Signing a phone in with a code from the Mac, the phone's only way in (no
// GitHub on the phone). The signed-in Mac asks for a code and shows it in a
// QR inside a setup link (dzep://setup?url=…&key=…&code=…); the phone redeems
// the code here for a fresh magic-link token (never emailed) and turns that
// into its own session with verifyOtp(type: magiclink, token_hash). Only the
// SHA-256 of a code is stored (public.pairing_codes).
//
//   POST /functions/v1/pair  Authorization: Bearer <the user's access token>
//     {"action": "create"}                        → {"code", "expires_at"}
//         single use, 10 minutes, for the caller (Settings → Set up phone…)
//     {"action": "reviewer", "days"?, "label"?}   → {"id", "code", "label", "expires_at"}
//         reusable for `days` (default 30, 1–365), for this server's demo
//         account (made on first use): App Store / Play review
//     {"action": "list"}                          → {"codes": [{id, label, expires_at, created_at, last_used_at}]}
//         the caller's active reviewer codes
//     {"action": "revoke", "id"}                  → {"revoked": true}
//         once no reviewer code works (revoked or run out), the demo account
//         is signed out everywhere (public.end_idle_demo_sessions)
//   POST /functions/v1/pair  (no token)
//     {"action": "redeem", "code"}                → {"token_hash"}
//         one failure reads the same whatever the reason (unknown, expired,
//         used, revoked); 429 after 10 failures from one caller in 10 minutes
//         (callers as Supabase's edge names them; no throttle when it doesn't)
//
// The demo account can make phone codes for itself only while one of its
// reviewer codes still works (public.reviewer_access_active).
//
// Deployed with --no-verify-jwt: the token is checked here with auth.getUser.
import { createClient, type User } from "jsr:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const phoneLifetimeMs = 10 * 60 * 1000;

// Crockford's base32: no I, L, O or U, so a code read aloud or typed can't be
// misread. 28 characters of 5 random bits each: 140 bits.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const codeLength = 28;

/** A new code, in groups of four: "K7QM-3XRT-…". */
function newCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(codeLength));
  const chars = Array.from(bytes, (b) => alphabet[b & 31]).join("");
  return chars.match(/.{4}/g)!.join("-");
}

/** [code] as stored: upper case, separators gone, look-alikes mapped. */
function normalize(code: string): string {
  return code.toUpperCase().replace(/[^0-9A-Z]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

const isDemo = (user: User) => user.app_metadata?.dzep_demo === true;

/** This server's demo account for reviewers: found, or made once. */
async function demoUser(): Promise<string> {
  const { data: found, error } = await admin.rpc("pairing_demo_user");
  if (error) throw new Error(error.message);
  if (typeof found === "string") return found;
  // The project's own ref keeps the address recognisable; .invalid never
  // resolves, and nothing is ever emailed to it.
  const ref = new URL(url).hostname.split(".")[0].replace(/[^a-z0-9-]/gi, "") || "dzep";
  const { data, error: createError } = await admin.auth.admin.createUser({
    email: `reviewer@${ref}.dzep.invalid`,
    email_confirm: true,
    app_metadata: { dzep_demo: true },
    user_metadata: { name: "Reviewer (demo)" },
  });
  if (createError || !data.user) throw new Error(createError?.message ?? "No demo account was made.");
  return data.user.id;
}

async function insertCode(row: {
  user_id: string;
  created_by: string;
  reusable: boolean;
  label: string;
  expires_at: string;
}): Promise<{ id: string; code: string }> {
  const code = newCode();
  const { data, error } = await admin
    .from("pairing_codes")
    .insert({ ...row, code_hash: await sha256(normalize(code)) })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return { id: data.id, code };
}

/**
 * Who sends the request, for the throttle only: the address Cloudflare, in
 * front of Supabase's edge, puts in cf-connecting-ip (it replaces whatever a
 * client sent). Null where nothing trustworthy names the caller (a local
 * stack): x-forwarded-for and x-real-ip are whatever the client says.
 */
function caller(req: Request): string | null {
  return req.headers.get("cf-connecting-ip")?.trim() || null;
}

const unusable =
  "That code doesn't work: it may have run out, been used already or been revoked. " +
  "Make a new one in Džep on your Mac (Settings → Set up phone…).";

const reviewerAccessEnded = "This reviewer access has ended. Ask the server's owner for a new reviewer code.";

async function redeem(req: Request, code: unknown): Promise<Response> {
  const normalized = typeof code === "string" ? normalize(code) : "";
  // A malformed code can't exist; it still counts as a failure for the throttle.
  const hash = normalized.length === codeLength ? await sha256(normalized) : "";
  const { data, error } = await admin.rpc("redeem_pairing_code", { p_hash: hash, p_ip: caller(req) });
  if (error) return json(500, { error: error.message });
  if (data?.error === "throttled") return json(429, { error: "Too many tries. Wait a few minutes, then try again." });
  if (typeof data?.user_id !== "string") return json(400, { error: unusable });

  const { data: found } = await admin.auth.admin.getUserById(data.user_id);
  const email = found?.user?.email;
  if (!email) return json(400, { error: unusable });
  const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (linkError || !link.properties?.hashed_token) {
    return json(500, { error: linkError?.message ?? "No sign-in was made." });
  }
  return json(200, { token_hash: link.properties.hashed_token });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const body = await req.json().catch(() => ({}));
  const action = body?.action;

  if (action === "redeem") return await redeem(req, body.code);

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await createClient(url, anonKey, { auth: { persistSession: false } }).auth.getUser(token);
  if (!user) return json(401, { error: "Sign in first" });

  // Listing and revoking go through the caller's own token: row level
  // security keeps them to their own codes, without the hashes.
  const own = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  try {
    if (action === "create") {
      if (!user.email) return json(400, { error: "Your account has no email address, so it can't pair a phone." });
      if (isDemo(user)) {
        const { data: active, error } = await own.rpc("reviewer_access_active");
        if (error) return json(500, { error: error.message });
        if (active !== true) return json(403, { error: reviewerAccessEnded });
      }
      // Spent and run-out phone codes of this user have no further use.
      await admin
        .from("pairing_codes")
        .delete()
        .eq("created_by", user.id)
        .eq("reusable", false)
        .lt("expires_at", new Date().toISOString());
      const expires_at = new Date(Date.now() + phoneLifetimeMs).toISOString();
      const { code } = await insertCode({ user_id: user.id, created_by: user.id, reusable: false, label: "", expires_at });
      return json(200, { code, expires_at });
    }

    // Reviewer codes are the owner's business, not the demo account's.
    if (isDemo(user)) return json(403, { error: "The demo account can't manage reviewer codes." });

    if (action === "reviewer") {
      const days = Number.isInteger(body.days) ? body.days : 30;
      if (days < 1 || days > 365) return json(400, { error: "days must be between 1 and 365" });
      const label = typeof body.label === "string" ? body.label.trim().slice(0, 80) : "";
      const expires_at = new Date(Date.now() + days * 24 * 60 * 60 * 1000).toISOString();
      const { id, code } = await insertCode({
        user_id: await demoUser(),
        created_by: user.id,
        reusable: true,
        label,
        expires_at,
      });
      return json(200, { id, code, label, expires_at });
    }

    if (action === "list") {
      const { data, error } = await own
        .from("pairing_codes")
        .select("id, label, expires_at, created_at, last_used_at")
        .eq("reusable", true)
        .is("revoked_at", null)
        .gt("expires_at", new Date().toISOString())
        .order("created_at", { ascending: false });
      if (error) return json(500, { error: error.message });
      return json(200, { codes: data });
    }

    if (action === "revoke") {
      if (typeof body.id !== "string") return json(400, { error: "id is required" });
      const { data, error } = await own
        .from("pairing_codes")
        .update({ revoked_at: new Date().toISOString() })
        .eq("id", body.id)
        .select("id")
        .maybeSingle();
      if (error) return json(500, { error: error.message });
      if (!data) return json(404, { error: "No such code." });
      return json(200, { revoked: true });
    }
  } catch (e) {
    return json(500, { error: e instanceof Error ? e.message : String(e) });
  }

  return json(400, { error: "Update Džep: action must be create, redeem, reviewer, list or revoke." });
});
