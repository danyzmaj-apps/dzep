// Push notifications to the user's iPhones, through the publisher's relay
// (functions/relay holds the APNs key). Every notification is encrypted here
// with the key that iPhone registered, so the relay only ever sees ciphertext.
// Deployed --no-verify-jwt: the user's token is checked here.
//
//   POST {"action": "register", "token", "key", "label"?}   user token: this iPhone
//   POST {"action": "unregister", "token"}                  user token: signed out
//   POST {"action": "notify", "title", "body"?}             user token: e.g. an omp session finished on the Mac
//   POST {"action": "tick"}                                 x-dzep-cron: the scheduler, reminders now due
import { createClient } from "jsr:@supabase/supabase-js@2";
import { decodeBase64, encodeBase64 } from "jsr:@std/encoding@1/base64";

const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// The publisher's relay; a fork with its own APNs key points this elsewhere.
const relay = Deno.env.get("PUSH_RELAY_URL") ?? "https://tgqmhieundubwtyvsnih.supabase.co/functions/v1/relay";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

type Message = { kind: "reminder" | "terminal"; title: string; body: string; id?: string };

/** AES-256-GCM: base64(nonce ‖ ciphertext ‖ tag), CryptoKit's combined form. */
export async function seal(keyB64: string, message: Message): Promise<string> {
  const key = await crypto.subtle.importKey("raw", decodeBase64(keyB64), "AES-GCM", false, ["encrypt"]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, new TextEncoder().encode(JSON.stringify(message))),
  );
  const out = new Uint8Array(12 + sealed.length);
  out.set(nonce);
  out.set(sealed, 12);
  return encodeBase64(out);
}

/** Sends to every iPhone of [userId]; forgets the ones Apple says are gone. */
async function send(userId: string, message: Message): Promise<number> {
  const { data: devices } = await admin.from("push_devices").select("token, key").eq("user_id", userId);
  let sent = 0;
  for (const d of devices ?? []) {
    const res = await fetch(relay, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        token: d.token,
        kind: message.kind,
        enc: await seal(d.key, message),
        // Lets a newer reminder for the same todo replace an older one.
        collapse: message.id,
      }),
    }).catch((e) => {
      console.error("relay unreachable", e);
      return null;
    });
    if (res?.status === 410) await admin.from("push_devices").delete().eq("token", d.token);
    else if (res?.ok) sent++;
    else if (res) console.error("relay", res.status, await res.text());
  }
  return sent;
}

/** The scheduler's address and secret, set the first time an iPhone registers. */
async function ensureConfig() {
  const { data } = await admin.from("push_config").select("id").maybeSingle();
  if (data) return;
  const secret = encodeBase64(crypto.getRandomValues(new Uint8Array(32)));
  await admin.from("push_config").upsert({ id: 1, url, secret }, { ignoreDuplicates: true });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const body = await req.json().catch(() => ({}));

  if (body.action === "tick") {
    const { data: config } = await admin.from("push_config").select("secret").maybeSingle();
    if (!config || req.headers.get("x-dzep-cron") !== config.secret) return json(401, { error: "Not the scheduler" });
    const { data: due, error } = await admin.rpc("claim_due_reminders");
    if (error) return json(500, { error: error.message });
    let sent = 0;
    for (const r of due ?? []) sent += await send(r.user_id, { kind: "reminder", title: "Reminder", body: r.title, id: r.id });
    return json(200, { due: due?.length ?? 0, sent });
  }

  const jwt = req.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
  const { data: auth } = await admin.auth.getUser(jwt);
  if (!auth.user) return json(401, { error: "Sign in first" });
  const user = auth.user.id;

  if (body.action === "register") {
    if (typeof body.token !== "string" || !/^[0-9a-f]{64,200}$/.test(body.token)) {
      return json(400, { error: "token must be the APNs device token (hex)" });
    }
    if (typeof body.key !== "string" || decodeBase64(body.key).length !== 32) {
      return json(400, { error: "key must be 32 bytes" });
    }
    const { error } = await admin.from("push_devices").upsert({
      token: body.token,
      user_id: user,
      key: body.key,
      label: typeof body.label === "string" ? body.label.slice(0, 80) : "",
      updated_at: new Date().toISOString(),
    });
    if (error) return json(500, { error: error.message });
    await ensureConfig();
    return json(200, { ok: true });
  }

  if (body.action === "unregister") {
    await admin.from("push_devices").delete().eq("token", body.token).eq("user_id", user);
    return json(200, { ok: true });
  }

  if (body.action === "notify") {
    const title = typeof body.title === "string" ? body.title.trim().slice(0, 120) : "";
    if (!title) return json(400, { error: "title is required" });
    const text = typeof body.body === "string" ? body.body.trim().slice(0, 400) : "";
    return json(200, { sent: await send(user, { kind: "terminal", title, body: text }) });
  }

  return json(400, { error: "action must be register, unregister, notify or tick" });
});
