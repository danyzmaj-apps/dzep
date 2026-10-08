// What the iPhone does without a Supabase session (Siri / Action Button
// intents, the interactive Todos widget), authorised by a device token
// (see device_tokens) in the x-dzep-token header. Deployed --no-verify-jwt.
//
//   POST /functions/v1/device  {"action": "add", "kind": "idea"|"todo"|"note", "title", "notes"?, "created_at"?}
//                              (a note keeps its whole text in notes, its first line as the title)
//   POST /functions/v1/device  {"action": "done", "id"}   → marks a todo done
import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const token = req.headers.get("x-dzep-token") ?? "";
  if (token.length < 32) return json(401, { error: "Missing device token" });

  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const hash = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  const { data: device } = await admin.from("device_tokens").select("id, user_id, label").eq("token_hash", hash).maybeSingle();
  if (!device) return json(401, { error: "Unknown device token" });
  await admin.from("device_tokens").update({ last_used_at: new Date().toISOString() }).eq("id", device.id);

  const body = await req.json().catch(() => ({}));

  if (body.action === "add") {
    const title = typeof body.title === "string" ? body.title.trim() : "";
    if (!title) return json(400, { error: "title is required" });
    const kind = body.kind === "todo" || body.kind === "note" ? body.kind : "idea";
    const notes = typeof body.notes === "string" ? body.notes.trim() : "";
    const { data: item, error } = await admin
      .from("ideas")
      .insert({
        id: crypto.randomUUID(),
        user_id: device.user_id,
        kind,
        title,
        notes: kind === "note" ? (notes ? `${title}\n${notes}` : title) : notes,
        device: device.label,
        ...(typeof body.created_at === "string" ? { created_at: body.created_at } : {}),
      })
      .select("id, kind, title")
      .single();
    if (error) return json(500, { error: error.message });
    return json(201, { item });
  }

  if (body.action === "done") {
    if (typeof body.id !== "string") return json(400, { error: "id is required" });
    const { data: item, error } = await admin
      .from("ideas")
      .update({ done_at: new Date().toISOString() })
      .eq("id", body.id)
      .eq("user_id", device.user_id)
      .eq("kind", "todo")
      .is("done_at", null)
      .select("id")
      .maybeSingle();
    if (error) return json(500, { error: error.message });
    // Already done (or not this user's): nothing to change, not an error.
    return json(200, { item });
  }

  return json(400, { error: "action must be add or done" });
});
