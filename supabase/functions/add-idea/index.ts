// POST /functions/v1/add-idea  {title, notes?, project?, created_at?}
// Header x-ideja-token: a device token (see device_tokens). Deployed with
// --no-verify-jwt: the device token is the credential, not a session.
import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const token = req.headers.get("x-ideja-token") ?? "";
  if (token.length < 32) return json(401, { error: "Missing device token" });

  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const hash = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  const { data: device } = await admin.from("device_tokens").select("id, user_id, label").eq("token_hash", hash).maybeSingle();
  if (!device) return json(401, { error: "Unknown device token" });

  const body = await req.json().catch(() => ({}));
  const title = typeof body.title === "string" ? body.title.trim() : "";
  if (!title) return json(400, { error: "title is required" });

  const { data: idea, error } = await admin
    .from("ideas")
    .insert({
      id: crypto.randomUUID(),
      user_id: device.user_id,
      title,
      notes: typeof body.notes === "string" ? body.notes.trim() : "",
      project: typeof body.project === "string" ? body.project.trim() : "",
      device: device.label,
      ...(typeof body.created_at === "string" ? { created_at: body.created_at } : {}),
    })
    .select("id, title")
    .single();
  if (error) return json(500, { error: error.message });

  await admin.from("device_tokens").update({ last_used_at: new Date().toISOString() }).eq("id", device.id);
  return json(201, { idea });
});
