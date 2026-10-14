// The push relay: the one function that can reach Apple's push service and
// Firebase Cloud Messaging for Džep, because it holds the publisher's APNs key
// and Firebase service account. Deployed ONLY to the publisher's project
// (tool/deploy-relay.sh), never by the setup wizard or tool/setup-backend.sh.
// Every Džep server sends its pushes through it (functions/push), already
// encrypted for the phone, so all this sees is a device token and ciphertext.
// Deployed --no-verify-jwt.
//
// iPhones (APNs; no platform field):
//   POST {"token": hex, "kind": "reminder"|"terminal", "enc": base64, "collapse"?: string}
//   POST {"token": hex, "kind": "liveactivity", "event": "update"|"end",
//         "state": {"state": "working"|"needs"|"done"|"ended", "since": unix seconds,
//                   "kind"?: "question"|"approval"|"plan"}}
// Android phones (FCM HTTP v1, a data-only message the app decrypts and shows):
//   POST {"platform": "android", "token": FCM registration token,
//         "kind": "reminder"|"terminal"|"activity", "enc": base64, "collapse"?: string}
//   → 200 sent · 410 the phone is gone (uninstalled, signed out): forget it ·
//     429 over a rate limit (Retry-After) · 501 FCM not configured here · 4xx/5xx otherwise
//
// Trust: any caller may use it (self-hosted servers have no credentials of
// the publisher's), so whoever knows a device token can make that phone show
// a generic "Džep / Reminder" alert, or move or end one of its Live
// Activities, and nothing more: the real text needs the key only that phone
// and its server hold. Rate limits (limits.ts) keep floods cheap: per caller
// address, per device token, and fewer still for a caller whose tokens keep
// turning out unknown or malformed.
//
// A Live Activity push (a coding session on the Lock Screen) can't be
// encrypted: the iPhone's notification extension never sees it. So it carries
// only a state, rebuilt here from checked fields, never anything passed
// through. Android's ongoing notification for a session is the app's own, so
// its state travels sealed like everything else (kind "activity").
//
// Secrets: APNS_KEY (the .p8's contents), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (bundle id),
// FCM_SERVICE_ACCOUNT (the Firebase service account's JSON key).

import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { encodeBase64Url } from "jsr:@std/encoding@1/base64url";
import {
  assertion,
  exchange,
  fcmGone,
  fcmKinds,
  fcmMessage,
  fcmToken,
  importPrivateKey,
  parseServiceAccount,
  type ServiceAccount,
} from "./fcm.ts";
import { callerOf, relayLimits } from "./limits.ts";

const keyId = Deno.env.get("APNS_KEY_ID")!;
const teamId = Deno.env.get("APNS_TEAM_ID")!;
const topic = Deno.env.get("APNS_TOPIC") ?? "com.danyzmaj.dzep";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const limits = relayLimits();

const tooMany = () =>
  new Response(JSON.stringify({ error: "Too many pushes; try again in a minute" }), {
    status: 429,
    headers: { "content-type": "application/json", "retry-after": "60" },
  });

/** Counts a push to [token]; false once that device had its share this minute. */
async function tokenAllowed(token: string): Promise<boolean> {
  // Hashed: an FCM token can be kilobytes long.
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return limits.token.take(String.fromCharCode(...new Uint8Array(digest)));
}

// The .p8 is PEM: base64 PKCS#8 between the BEGIN/END lines.
const signingKey = crypto.subtle.importKey(
  "pkcs8",
  decodeBase64((Deno.env.get("APNS_KEY") ?? "").replace(/-----[A-Z ]+-----/g, "").replace(/\s/g, "")),
  { name: "ECDSA", namedCurve: "P-256" },
  false,
  ["sign"],
);

// Apple wants a fresh provider token at most hourly and at least every 20 min
// apart; one per 40 min, reused across requests while the function stays warm.
let jwt: { token: string; at: number } | null = null;

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (jwt && now - jwt.at < 40 * 60) return jwt.token;
  const part = (o: unknown) => encodeBase64Url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${part({ alg: "ES256", kid: keyId })}.${part({ iss: teamId, iat: now })}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await signingKey,
    new TextEncoder().encode(unsigned),
  );
  const token = `${unsigned}.${encodeBase64Url(new Uint8Array(sig))}`;
  jwt = { token, at: now };
  return token;
}

// Google's access tokens last an hour; one per 50 min, reused while warm.
let fcm: { sa: ServiceAccount; key: CryptoKey; token?: string; until?: number } | null = null;

/** The service account and a live access token, or what's missing (a 501). */
type FcmAccess = { sa: ServiceAccount; token: string } | string;

async function fcmAccess(): Promise<FcmAccess> {
  if (!fcm) {
    const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!raw) return "FCM_SERVICE_ACCOUNT is not set: this relay can't reach Android phones";
    const sa = parseServiceAccount(raw);
    if (typeof sa === "string") return sa;
    fcm = { sa, key: await importPrivateKey(sa.private_key) };
  }
  const now = Math.floor(Date.now() / 1000);
  if (!fcm.token || !fcm.until || now >= fcm.until) {
    const got = await exchange(await assertion(fcm.sa, fcm.key, now));
    fcm.token = got.token;
    fcm.until = now + Math.min(50 * 60, got.expiresIn - 60);
  }
  return { sa: fcm.sa, token: fcm.token };
}

/** An Android phone's push, through FCM. */
async function android(body: Record<string, unknown>): Promise<Response> {
  if (!fcmToken(body.token)) return json(400, { error: "token must be an FCM registration token" });
  const kind = fcmKinds.find((k) => k === body.kind);
  if (!kind) return json(400, { error: `kind must be ${fcmKinds.join(", ")}` });
  // FCM takes 4 KB of data in all.
  if (typeof body.enc !== "string" || body.enc.length > 3000) return json(400, { error: "enc missing or too long" });
  const collapse = typeof body.collapse === "string" && body.collapse.length <= 64 ? body.collapse : undefined;
  if (!(await tokenAllowed(body.token))) return tooMany();

  let access: FcmAccess;
  try {
    access = await fcmAccess();
  } catch (e) {
    return json(502, { error: `${e instanceof Error ? e.message : e}` });
  }
  if (typeof access === "string") return json(501, { error: access });
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${access.sa.project_id}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${access.token}`, "content-type": "application/json" },
    body: JSON.stringify(fcmMessage(body.token, kind, body.enc, collapse)),
  });
  if (res.ok) return json(200, { ok: true });
  const answer: unknown = await res.json().catch(() => null);
  // A token Google no longer takes: the next request mints a new one.
  if (res.status === 401 && fcm) fcm.token = undefined;
  if (fcmGone(res.status, answer)) return json(410, { gone: true });
  return json(502, { error: `FCM ${res.status} ${JSON.stringify(answer)}`.slice(0, 500) });
}

// What shows if the iPhone can't decrypt (shouldn't happen): no content.
const fallback = { reminder: "Reminder", terminal: "Terminal" } as const;

const activityStates = ["working", "needs", "done", "ended"];
const activityKinds = ["question", "approval", "plan"];

/** A Live Activity's push from a checked body; a string says what's wrong. */
function liveActivity(body: Record<string, unknown>): { payload: string; priority: string } | string {
  const s = body.state;
  if (!s || typeof s !== "object") return "state missing";
  const { state, since, kind } = s as Record<string, unknown>;
  if (typeof state !== "string" || !activityStates.includes(state)) return "state.state must be a known state";
  const now = Math.floor(Date.now() / 1000);
  if (typeof since !== "number" || !Number.isFinite(since) || since < now - 7 * 86400 || since > now + 3600) {
    return "state.since must be a recent unix time";
  }
  if (kind !== undefined && (typeof kind !== "string" || !activityKinds.includes(kind) || state !== "needs")) {
    return "state.kind must be a known kind, with needs";
  }
  if (body.event !== "update" && body.event !== "end") return "event must be update or end";
  const end = body.event === "end";
  const aps: Record<string, unknown> = {
    timestamp: now,
    event: body.event,
    "content-state": { state, since: Math.floor(since), ...(kind ? { kind } : {}) },
  };
  // Gone from the Lock Screen 10 minutes after it ended; otherwise stale (the
  // phone shows it as such) after 8 hours without news.
  if (end) aps["dismissal-date"] = now + 600;
  else aps["stale-date"] = now + 8 * 3600;
  // Apple rations priority 10; working can wait.
  return { payload: JSON.stringify({ aps }), priority: state === "working" ? "5" : "10" };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const caller = callerOf(req);
  if (caller && (limits.bad.full(caller) || !limits.caller.take(caller))) return tooMany();
  const body: unknown = await req.json().catch(() => null);
  const res = body && typeof body === "object" && !Array.isArray(body)
    ? await push(body as Record<string, unknown>)
    : json(400, { error: "the body must be a JSON object" });
  // Malformed requests and tokens no phone has: what guessing looks like.
  if (caller && (res.status === 400 || res.status === 410)) limits.bad.take(caller);
  return res;
});

async function push(body: Record<string, unknown>): Promise<Response> {
  if (body.platform === "android") return android(body);
  if (body.platform !== undefined && body.platform !== "ios") return json(400, { error: "platform must be ios or android" });
  const live = body.kind === "liveactivity";
  // A Live Activity's token is longer than a device's.
  if (typeof body.token !== "string" || !new RegExp(`^[0-9a-f]{64,${live ? 400 : 200}}$`).test(body.token)) {
    return json(400, { error: "token must be an APNs device token" });
  }

  let payload: string;
  const headers: Record<string, string> = { authorization: `bearer ${await providerToken()}` };
  if (live) {
    const push = liveActivity(body);
    if (typeof push === "string") return json(400, { error: push });
    payload = push.payload;
    headers["apns-topic"] = `${topic}.push-type.liveactivity`;
    headers["apns-push-type"] = "liveactivity";
    headers["apns-priority"] = push.priority;
  } else {
    if (typeof body.enc !== "string" || body.enc.length > 3000) return json(400, { error: "enc missing or too long" });
    const kind = body.kind === "terminal" ? "terminal" : "reminder";
    payload = JSON.stringify({
      aps: {
        alert: { title: "Džep", body: fallback[kind] },
        sound: "default",
        // The iPhone's notification extension decrypts enc into the real text.
        "mutable-content": 1,
        ...(kind === "reminder" ? { category: "todo" } : {}),
      },
      enc: body.enc,
    });
    headers["apns-topic"] = topic;
    headers["apns-push-type"] = "alert";
    headers["apns-priority"] = "10";
    if (typeof body.collapse === "string" && body.collapse.length <= 64) headers["apns-collapse-id"] = body.collapse;
  }
  if (!(await tokenAllowed(body.token))) return tooMany();

  // Release builds talk to production, ones run from Xcode / flutter run to
  // the sandbox; a token from the other one is a BadDeviceToken here.
  for (const host of ["api.push.apple.com", "api.sandbox.push.apple.com"]) {
    const res = await fetch(`https://${host}/3/device/${body.token}`, { method: "POST", headers, body: payload });
    if (res.ok) return json(200, { ok: true });
    const answer: unknown = await res.json().catch(() => null);
    const reason =
      answer && typeof answer === "object" && "reason" in answer && typeof answer.reason === "string" ? answer.reason : "";
    if (res.status === 410 || reason === "Unregistered") return json(410, { gone: true });
    if (reason !== "BadDeviceToken") return json(502, { error: `APNs ${res.status} ${reason}` });
  }
  return json(410, { gone: true });
}
