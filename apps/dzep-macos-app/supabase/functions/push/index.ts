// Push notifications to the user's phones, through the publisher's relay
// (functions/relay holds the APNs key and the Firebase service account).
// Every notification is encrypted here with the key that phone registered,
// so the relay only ever sees ciphertext. iPhones go through APNs, Android
// phones through FCM. Deployed --no-verify-jwt: the user's token is checked here.
//
//   POST {"action": "register", "token", "key", "label"?, "platform"?}
//                                                           user token: this phone; platform: ios (default,
//                                                           token: the APNs device token, hex) | android
//                                                           (token: the FCM registration token); key: its
//                                                           AES-256 key, base64
//   POST {"action": "unregister", "token"}                  user token: signed out
//   POST {"action": "notify", "title", "body"?, "session"?}  user token: e.g. an omp session finished on the Mac;
//                                                            session: the omp session a tap opens (its Live
//                                                            Activities, if any, turn done or needs too)
//   POST {"action": "tick"}                                 x-dzep-cron: the scheduler, reminders now due
//
// Sealed messages (AES-256-GCM, base64(nonce ‖ ciphertext ‖ tag)):
//   {"kind": "reminder"|"terminal", "title", "body", "id"?: todo, "session"?: omp session}
//   {"kind": "activity", "session", "state", "since": unix ms, "akind"?}  Android only, see below
//
// Live Activities (an omp session followed on the phone). An iPhone's has
// its own push token and its pushes can't be encrypted (the notification
// extension never sees them), so they carry a state and nothing else: no
// title, no text. An Android phone follows each session with its FCM token
// (one row per session) and gets the state sealed with its device key.
//
//   POST {"action": "activity_register", "token", "session", "platform"?}
//                                                             user token: an activity's push token (ios) or
//                                                             the phone's FCM token (android)
//   POST {"action": "activity_end", "token", "session"?}      user token: that activity is over (only that
//                                                             session's, when given)
//   POST {"action": "activity", "session", "state", "kind"?}  user token: the Mac, on a session's change;
//        state: working | needs | done | ended, kind: question | approval | plan (needs only)
import { createClient } from "jsr:@supabase/supabase-js@2";
import { decodeBase64, encodeBase64 } from "jsr:@std/encoding@1/base64";

const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// The publisher's relay; a fork with its own APNs key points this elsewhere.
const relay = Deno.env.get("PUSH_RELAY_URL") ?? "https://tgqmhieundubwtyvsnih.supabase.co/functions/v1/relay";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** The omp session a push is about: `kitty-<pid>/<window id>` or `pid:<pid>` (at most 64: also a collapse id). */
const sessionKey = (v: unknown) => (typeof v === "string" && /^[\w.:/-]{1,64}$/.test(v) ? v : undefined);

/** APNs tokens are hex; a Live Activity's is longer than a device's. */
const apnsToken = (v: unknown, max = 200): v is string =>
  typeof v === "string" && new RegExp(`^[0-9a-f]{64,${max}}$`).test(v);

/** FCM registration tokens: an Android phone's, for its notifications and its followed sessions alike. */
const fcmToken = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_:\-]{100,4096}$/.test(v);

const platforms = ["ios", "android"] as const;
type Platform = (typeof platforms)[number];

/** The relay's answer to one push; a 410 means the phone is gone. */
async function relayPost(body: Record<string, unknown>): Promise<Response | null> {
  const res = await fetch(relay, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }).catch((e) => {
    console.error("relay unreachable", e);
    return null;
  });
  if (res && !res.ok && res.status !== 410) console.error("relay", res.status, await res.text());
  return res;
}

const activityStates = ["working", "needs", "done", "ended"] as const;
const activityKinds = ["question", "approval", "plan"] as const;
type ActivityState = (typeof activityStates)[number];
type ActivityKind = (typeof activityKinds)[number];

/** Moves every Live Activity of [userId]'s omp [session] to [state] (ended: ends them). */
async function activity(userId: string, session: string, state: ActivityState, kind?: ActivityKind): Promise<number> {
  const { data: rows } = await admin
    .from("activity_tokens")
    .select("token, platform")
    .eq("user_id", userId)
    .eq("session", session);
  const androidTokens = (rows ?? []).filter((r) => r.platform === "android").map((r) => r.token);
  const { data: keys } = androidTokens.length
    ? await admin.from("push_devices").select("token, key").eq("user_id", userId).in("token", androidTokens)
    : { data: [] };
  const keyOf = new Map((keys ?? []).map((d) => [d.token, d.key]));
  const now = Date.now();
  let sent = 0;
  for (const { token, platform } of rows ?? []) {
    let res: Response | null;
    if (platform === "android") {
      const key = keyOf.get(token);
      // The phone unregistered: nothing to seal its pushes with.
      if (!key) {
        await admin.from("activity_tokens").delete().eq("token", token).eq("user_id", userId);
        continue;
      }
      const message: Message = {
        kind: "activity",
        session,
        state,
        since: now,
        ...(state === "needs" && kind ? { akind: kind } : {}),
      };
      res = await relayPost({ platform: "android", token, kind: "activity", enc: await seal(key, message), collapse: session });
    } else {
      res = await relayPost({
        token,
        kind: "liveactivity",
        event: state === "ended" ? "end" : "update",
        state: { state, since: Math.floor(now / 1000), ...(state === "needs" && kind ? { kind } : {}) },
      });
    }
    // An Android token is the phone's: gone, it follows no session any more.
    if (res?.status === 410) await admin.from("activity_tokens").delete().eq("token", token);
    else if (res?.ok) sent++;
  }
  // An ended activity takes no more pushes.
  if (state === "ended") await admin.from("activity_tokens").delete().eq("user_id", userId).eq("session", session);
  return sent;
}

/** id: the todo (reminders); session: the omp session (terminal). */
type Notice = { kind: "reminder" | "terminal"; title: string; body: string; id?: string; session?: string };
/** An omp session's state for an Android phone; since: unix ms. */
type ActivityMessage = { kind: "activity"; session: string; state: ActivityState; since: number; akind?: ActivityKind };
type Message = Notice | ActivityMessage;

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

/** Sends to every phone of [userId]; forgets the ones Apple or Google say are gone. */
async function send(userId: string, message: Notice): Promise<number> {
  const { data: devices } = await admin.from("push_devices").select("token, key, platform").eq("user_id", userId);
  let sent = 0;
  for (const d of devices ?? []) {
    const res = await relayPost({
      ...(d.platform === "android" ? { platform: "android" } : {}),
      token: d.token,
      kind: message.kind,
      enc: await seal(d.key, message),
      // Lets a newer push for the same todo, or the same omp session,
      // replace an older one.
      collapse: message.id ?? message.session,
    });
    if (res?.status === 410) await admin.from("push_devices").delete().eq("token", d.token);
    else if (res?.ok) sent++;
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

  const platform: Platform | undefined = body.platform == null ? "ios" : platforms.find((p) => p === body.platform);
  if (!platform) return json(400, { error: "platform must be ios or android" });

  if (body.action === "register") {
    if (platform === "android") {
      if (!fcmToken(body.token)) return json(400, { error: "token must be the FCM registration token" });
    } else if (!apnsToken(body.token)) return json(400, { error: "token must be the APNs device token (hex)" });
    if (typeof body.key !== "string" || decodeBase64(body.key).length !== 32) {
      return json(400, { error: "key must be 32 bytes" });
    }
    const { error } = await admin.from("push_devices").upsert({
      token: body.token,
      user_id: user,
      key: body.key,
      label: typeof body.label === "string" ? body.label.slice(0, 80) : "",
      platform,
      updated_at: new Date().toISOString(),
    });
    if (error) return json(500, { error: error.message });
    await ensureConfig();
    return json(200, { ok: true });
  }

  if (body.action === "unregister") {
    await admin.from("push_devices").delete().eq("token", body.token).eq("user_id", user);
    // An Android phone's sessions follow its device token.
    await admin.from("activity_tokens").delete().eq("token", body.token).eq("user_id", user);
    return json(200, { ok: true });
  }

  if (body.action === "notify") {
    const title = typeof body.title === "string" ? body.title.trim().slice(0, 120) : "";
    if (!title) return json(400, { error: "title is required" });
    const text = typeof body.body === "string" ? body.body.trim().slice(0, 400) : "";
    const session = sessionKey(body.session);
    const sent = await send(user, { kind: "terminal", title, body: text, session });
    // The Mac's omp alerts (lib/controller.dart) also move the session's Live Activities.
    if (session) {
      const state = title.startsWith("omp finished") ? "done" : title.startsWith("omp needs you") ? "needs" : null;
      if (state) await activity(user, session, state);
    }
    return json(200, { sent });
  }

  if (body.action === "activity_register") {
    const session = sessionKey(body.session);
    if (platform === "android") {
      if (!fcmToken(body.token)) return json(400, { error: "token must be the FCM registration token" });
    } else if (!apnsToken(body.token, 400)) return json(400, { error: "token must be the activity's push token (hex)" });
    if (!session) return json(400, { error: "session must be an omp session key" });
    // A token another user registered stays theirs.
    const { data: other } = await admin
      .from("activity_tokens")
      .select("user_id")
      .eq("token", body.token)
      .neq("user_id", user)
      .limit(1);
    if (other?.length) return json(409, { error: "token belongs to someone else" });
    // An iPhone's activity follows one session for good.
    if (platform === "ios") {
      await admin.from("activity_tokens").delete().eq("token", body.token).neq("session", session);
    }
    const { error } = await admin
      .from("activity_tokens")
      .upsert(
        { token: body.token, user_id: user, session, platform, updated_at: new Date().toISOString() },
        { onConflict: "token,session" },
      );
    if (error) return json(500, { error: error.message });
    return json(200, { ok: true });
  }

  if (body.action === "activity_end") {
    if (typeof body.token === "string") {
      const session = sessionKey(body.session);
      let ended = admin.from("activity_tokens").delete().eq("token", body.token).eq("user_id", user);
      if (session) ended = ended.eq("session", session);
      await ended;
    }
    return json(200, { ok: true });
  }

  if (body.action === "activity") {
    const session = sessionKey(body.session);
    if (!session) return json(400, { error: "session must be an omp session key" });
    const state = activityStates.find((s) => s === body.state);
    if (!state) return json(400, { error: `state must be ${activityStates.join(", ")}` });
    const kind = body.kind == null ? undefined : activityKinds.find((k) => k === body.kind);
    if (body.kind != null && !kind) return json(400, { error: `kind must be ${activityKinds.join(", ")}` });
    return json(200, { sent: await activity(user, session, state, kind) });
  }

  return json(400, {
    error: "action must be register, unregister, notify, tick, activity_register, activity_end or activity",
  });
});
