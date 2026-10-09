// Pairing a new device without a second sign-in: the signed-in Mac asks for a
// one-time code and shows it in a QR (with the server's URL and key); the
// iPhone redeems it with verifyOtp(type: magiclink, token_hash) and gets its
// own session. The code is a magic-link token that is never emailed: it works
// once, and expires with the project's OTP expiry (10 minutes, config.toml).
//
//   POST /functions/v1/pair   Authorization: Bearer <the user's access token>
//   → {"token_hash": "...", "expires_in": 600}
//
// Deployed with --no-verify-jwt: the token is checked here with auth.getUser.
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const url = Deno.env.get("SUPABASE_URL")!;
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
  }).auth.getUser(token);
  if (!user) return json(401, { error: "Sign in first" });
  if (!user.email) {
    return json(400, { error: "Your account has no email address, so it can't pair. Sign in with GitHub on the iPhone." });
  }

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email: user.email });
  if (error || !data.properties?.hashed_token) return json(500, { error: error?.message ?? "No code was made." });
  return json(200, { token_hash: data.properties.hashed_token, expires_in: 600 });
});
