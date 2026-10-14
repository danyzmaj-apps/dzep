// functions/relay: what reaches APNs and FCM, what never does, and its rate limits.
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import { handlerOf, json, network, post, sent } from "./harness.ts";

/** A throwaway signing key made for this run only, in the PEM form an .p8 has. */
async function pem(algorithm: EcKeyGenParams | RsaHashedKeyGenParams): Promise<string> {
  const pair = await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"]);
  const der = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  return `-----BEGIN PRIVATE KEY-----\n${encodeBase64(new Uint8Array(der))}\n-----END PRIVATE KEY-----\n`;
}

const relay = await handlerOf(() => import("../relay/index.ts"), {
  APNS_KEY: await pem({ name: "ECDSA", namedCurve: "P-256" }),
  APNS_KEY_ID: "KEYID12345",
  APNS_TEAM_ID: "TEAM123456",
  APNS_TOPIC: "com.example.dzep",
});

/** A device token of [n] hex digits, distinct per [seed]. */
const hex = (seed: number, n = 64) => seed.toString(16).padStart(n, "0");
const now = () => Math.floor(Date.now() / 1000);

const apns = (status = 200, reason?: string) => () =>
  reason ? json({ reason }, status) : new Response(null, { status });

Deno.test("an iPhone alert goes to APNs with generic text and the ciphertext", async () => {
  network(apns());
  const res = await relay(post({ token: hex(1), kind: "reminder", enc: "c2VhbGVk", collapse: "todo-1" }));
  assertEquals(res.status, 200);
  assertEquals(sent.length, 1);
  const [push] = sent;
  assertEquals(push.url.href, `https://api.push.apple.com/3/device/${hex(1)}`);
  assertEquals(push.headers.get("apns-topic"), "com.example.dzep");
  assertEquals(push.headers.get("apns-push-type"), "alert");
  assertEquals(push.headers.get("apns-collapse-id"), "todo-1");
  assertMatch(push.headers.get("authorization") ?? "", /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assertEquals(JSON.parse(push.body), {
    aps: { alert: { title: "Džep", body: "Reminder" }, sound: "default", "mutable-content": 1, category: "todo" },
    enc: "c2VhbGVk",
  });
});

Deno.test("a sandbox token is tried on the sandbox after production calls it bad", async () => {
  network((req) => (new URL(req.url).host === "api.push.apple.com" ? apns(400, "BadDeviceToken")() : apns()()));
  const res = await relay(post({ token: hex(2), kind: "terminal", enc: "x" }));
  assertEquals(res.status, 200);
  assertEquals(sent.map((r) => r.url.host), ["api.push.apple.com", "api.sandbox.push.apple.com"]);
});

Deno.test("a token Apple calls gone answers 410, so the server forgets the phone", async () => {
  network(apns(410, "Unregistered"));
  assertEquals((await relay(post({ token: hex(3), kind: "reminder", enc: "x" }))).status, 410);
  network(apns(400, "BadDeviceToken"));
  assertEquals((await relay(post({ token: hex(4), kind: "reminder", enc: "x" }))).status, 410);
});

Deno.test("a Live Activity push carries only a state rebuilt from checked fields", async () => {
  network(apns());
  const since = now() - 60;
  const res = await relay(post({
    token: hex(5, 160),
    kind: "liveactivity",
    event: "update",
    state: { state: "needs", since, kind: "approval", title: "secret project", extra: 1 },
    alert: "injected",
  }));
  assertEquals(res.status, 200);
  const [push] = sent;
  assertEquals(push.headers.get("apns-topic"), "com.example.dzep.push-type.liveactivity");
  assertEquals(push.headers.get("apns-push-type"), "liveactivity");
  assertEquals(push.headers.get("apns-priority"), "10");
  const { aps, ...rest } = JSON.parse(push.body);
  assertEquals(rest, {});
  assertEquals(aps["content-state"], { state: "needs", since, kind: "approval" });
  assertEquals(aps.event, "update");
  assert(aps["stale-date"] > now());
  assertEquals(aps.alert, undefined);
});

Deno.test("working waits at low priority; an ended activity is dismissed later", async () => {
  network(apns());
  await relay(
    post({ token: hex(6, 160), kind: "liveactivity", event: "update", state: { state: "working", since: now() } }),
  );
  assertEquals(sent[0].headers.get("apns-priority"), "5");
  network(apns());
  await relay(
    post({ token: hex(6, 160), kind: "liveactivity", event: "end", state: { state: "ended", since: now() } }),
  );
  const { aps } = JSON.parse(sent[0].body);
  assertEquals(aps.event, "end");
  assert(aps["dismissal-date"] > now());
});

Deno.test("malformed pushes are refused before anything reaches Apple or Google", async () => {
  const bad: unknown[] = [
    { token: "not-hex", kind: "reminder", enc: "x" },
    { token: hex(7, 300), kind: "reminder", enc: "x" }, // too long for a device token
    { token: hex(7), kind: "reminder" },
    { token: hex(7), kind: "reminder", enc: "x".repeat(3001) },
    { token: hex(7, 160), kind: "liveactivity", event: "update", state: { state: "exploded", since: now() } },
    { token: hex(7, 160), kind: "liveactivity", event: "update", state: { state: "done", since: now(), kind: "plan" } },
    { token: hex(7, 160), kind: "liveactivity", event: "update", state: { state: "done", since: now() - 30 * 86400 } },
    { token: hex(7, 160), kind: "liveactivity", event: "start", state: { state: "done", since: now() } },
    { platform: "windows", token: hex(7), kind: "reminder", enc: "x" },
    { platform: "android", token: "short", kind: "reminder", enc: "x" },
    { platform: "android", token: "f".repeat(160), kind: "liveactivity", enc: "x" },
    "a string",
    [1, 2],
  ];
  network();
  for (const body of bad) {
    const res = await relay(post(body));
    assertEquals(res.status, 400, JSON.stringify(body));
  }
  assertEquals(await relay(new Request("http://function.test/", { method: "GET" })).then((r) => r.status), 405);
  assertEquals(sent.length, 0);
});

Deno.test("an Android push goes to FCM as a data-only message", async () => {
  network();
  const android = {
    platform: "android",
    token: "f".repeat(160),
    kind: "reminder",
    enc: "c2VhbGVk",
    collapse: "todo-1",
  };
  assertEquals((await relay(post(android))).status, 501, "without a service account");

  Deno.env.set(
    "FCM_SERVICE_ACCOUNT",
    JSON.stringify({
      project_id: "dzep-test",
      client_email: "relay@dzep-test.iam.gserviceaccount.com",
      private_key: await pem({
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      }),
    }),
  );
  network((req) =>
    req.url === "https://oauth2.googleapis.com/token"
      ? json({ access_token: "google-token", expires_in: 3600 })
      : json({ name: "sent" })
  );
  assertEquals((await relay(post(android))).status, 200);
  const [token, message] = sent;
  assertEquals(new URLSearchParams(token.body).get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
  assertEquals(message.url.href, "https://fcm.googleapis.com/v1/projects/dzep-test/messages:send");
  assertEquals(message.headers.get("authorization"), "Bearer google-token");
  assertEquals(JSON.parse(message.body), {
    message: {
      token: "f".repeat(160),
      data: { kind: "reminder", enc: "c2VhbGVk" },
      android: { priority: "high", collapse_key: "todo-1", ttl: "86400s" },
    },
  });

  network(() => json({ error: { status: "NOT_FOUND", message: "Requested entity was not found." } }, 404));
  assertEquals(
    (await relay(post({ ...android, token: "g".repeat(160) }))).status,
    410,
    "an uninstalled app's token is gone",
  );
});

Deno.test("one device gets at most 60 pushes a minute", async () => {
  network(apns());
  const token = hex(8);
  for (let i = 0; i < 60; i++) assertEquals((await relay(post({ token, kind: "terminal", enc: "x" }))).status, 200);
  const res = await relay(post({ token, kind: "terminal", enc: "x" }));
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("retry-after"), "60");
  assertEquals(sent.length, 60, "the 61st never reached Apple");
  assertEquals(
    (await relay(post({ token: hex(9), kind: "terminal", enc: "x" }))).status,
    200,
    "other devices still get theirs",
  );
});

Deno.test("a caller guessing tokens is turned away; others are not", async () => {
  network(apns(400, "BadDeviceToken"));
  const guesser = { "cf-connecting-ip": "203.0.113.9" };
  for (let i = 0; i < 15; i++) {
    assertEquals((await relay(post({ token: hex(100 + i), kind: "reminder", enc: "x" }, guesser))).status, 410);
  }
  for (let i = 0; i < 15; i++) {
    assertEquals((await relay(post({ token: "nope", kind: "reminder", enc: "x" }, guesser))).status, 400);
  }
  network(apns());
  assertEquals(
    (await relay(post({ token: hex(200), kind: "reminder", enc: "x" }, guesser))).status,
    429,
    "even a good push waits",
  );
  assertEquals(sent.length, 0);
  assertEquals(
    (await relay(post({ token: hex(200), kind: "reminder", enc: "x" }, { "cf-connecting-ip": "203.0.113.10" }))).status,
    200,
  );
  // x-forwarded-for is the client's to write: it names no caller.
  assertEquals(
    (await relay(post({ token: hex(201), kind: "reminder", enc: "x" }, { "x-forwarded-for": "203.0.113.9" }))).status,
    200,
  );
});
