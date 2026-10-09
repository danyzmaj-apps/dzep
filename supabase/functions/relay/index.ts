// The push relay: the one function that can reach Apple's push service for
// Džep, because it holds the publisher's APNs key. Deployed ONLY to the
// publisher's project (tool/deploy-relay.sh), never by the setup wizard or
// tool/setup-backend.sh. Every Džep server sends its pushes through it
// (functions/push), already encrypted for the iPhone, so all this sees is a
// device token and ciphertext. Deployed --no-verify-jwt.
//
//   POST {"token": hex, "kind": "reminder"|"terminal", "enc": base64, "collapse"?: string}
//   → 200 sent · 410 the iPhone is gone (uninstalled, signed out): forget it · 4xx/5xx otherwise
//
// Secrets: APNS_KEY (the .p8's contents), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (bundle id).

import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { encodeBase64Url } from "jsr:@std/encoding@1/base64url";

const keyId = Deno.env.get("APNS_KEY_ID")!;
const teamId = Deno.env.get("APNS_TEAM_ID")!;
const topic = Deno.env.get("APNS_TOPIC") ?? "com.danyzmaj.dzep";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

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

// What shows if the iPhone can't decrypt (shouldn't happen): no content.
const fallback = { reminder: "Reminder", terminal: "Terminal" } as const;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const body = await req.json().catch(() => ({}));
  if (typeof body.token !== "string" || !/^[0-9a-f]{64,200}$/.test(body.token)) {
    return json(400, { error: "token must be an APNs device token" });
  }
  if (typeof body.enc !== "string" || body.enc.length > 3000) return json(400, { error: "enc missing or too long" });
  const kind = body.kind === "terminal" ? "terminal" : "reminder";

  const payload = JSON.stringify({
    aps: {
      alert: { title: "Džep", body: fallback[kind] },
      sound: "default",
      // The iPhone's notification extension decrypts enc into the real text.
      "mutable-content": 1,
      ...(kind === "reminder" ? { category: "todo" } : {}),
    },
    enc: body.enc,
  });
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken()}`,
    "apns-topic": topic,
    "apns-push-type": "alert",
    "apns-priority": "10",
  };
  if (typeof body.collapse === "string" && body.collapse.length <= 64) headers["apns-collapse-id"] = body.collapse;

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
});
