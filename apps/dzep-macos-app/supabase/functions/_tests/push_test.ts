// functions/push: what a server hands the relay, sealed for each phone.
import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { decodeBase64, encodeBase64 } from "jsr:@std/encoding@1/base64";
import { handlerOf, json, network, post, sent, supabaseEnv } from "./harness.ts";

const relayUrl = "https://relay.test/functions/v1/relay";
const push = await handlerOf(() => import("../push/index.ts"), { ...supabaseEnv, PUSH_RELAY_URL: relayUrl });
const { seal } = await import("../push/index.ts");

const user = { id: "00000000-0000-0000-0000-00000000000a", email: "owner@example.com", app_metadata: {} };
const signedIn = { authorization: "Bearer user-token" };
const phoneKey = crypto.getRandomValues(new Uint8Array(32));
const iphone = "a".repeat(64);
const activity = "b".repeat(160);

/** Opens what seal made, as the phone does. */
async function open(keyBytes: Uint8Array<ArrayBuffer>, sealed: string): Promise<unknown> {
  const raw = decodeBase64(sealed);
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.slice(0, 12) }, key, raw.slice(12));
  return JSON.parse(new TextDecoder().decode(plain));
}

/** A server with one iPhone that follows coding session "s1" on its Lock Screen. */
function server() {
  network((req) => {
    const url = new URL(req.url);
    if (req.url.startsWith(relayUrl)) return json({ ok: true });
    if (url.pathname === "/auth/v1/user") return json(user);
    if (url.pathname === "/rest/v1/push_devices") {
      return json([{ token: iphone, key: encodeBase64(phoneKey), platform: "ios" }]);
    }
    if (url.pathname === "/rest/v1/activity_tokens") return json([{ token: activity, platform: "ios" }]);
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
}

const toRelay = () => sent.filter((r) => r.url.href === relayUrl).map((r) => JSON.parse(r.body));

Deno.test("a sealed message opens only with the phone's key, with a fresh nonce each time", async () => {
  const message = { kind: "reminder" as const, title: "Reminder", body: "Call the bank", id: "todo-1" };
  const a = await seal(encodeBase64(phoneKey), message);
  const b = await seal(encodeBase64(phoneKey), message);
  assertEquals(await open(phoneKey, a), message);
  assertNotEquals(a, b);
  const other = crypto.getRandomValues(new Uint8Array(32));
  let opened = true;
  await open(other, a).catch(() => (opened = false));
  assertEquals(opened, false);
});

Deno.test("a session alert reaches the phone sealed and moves the session's Live Activity", async () => {
  server();
  const res = await push(
    post({ action: "notify", title: "Claude finished · dzep", body: "Done.", session: "s1", state: "done" }, signedIn),
  );
  assertEquals(await res.json(), { sent: 1 });
  const [alert, live] = toRelay();
  assertEquals(alert.token, iphone);
  assertEquals(alert.kind, "terminal");
  assertEquals(alert.collapse, "s1");
  assertEquals(await open(phoneKey, alert.enc), {
    kind: "terminal",
    title: "Claude finished · dzep",
    body: "Done.",
    session: "s1",
  });
  assertEquals(JSON.stringify(alert).includes("Claude finished"), false, "the relay never sees the text");
  assertEquals(live.token, activity);
  assertEquals(live.kind, "liveactivity");
  assertEquals(live.event, "update");
  assertEquals(live.state.state, "done");
});

Deno.test("only an explicit state moves a Live Activity, whatever the title says", async () => {
  server();
  await push(post({ action: "notify", title: "omp finished · dzep", session: "s1" }, signedIn));
  assertEquals(toRelay().map((b) => b.kind), ["terminal"]);
});

Deno.test("registration takes only a real push token and a 32-byte key", async () => {
  const cases: [Record<string, unknown>, number][] = [
    [{ action: "register", token: "not-hex", key: encodeBase64(phoneKey) }, 400],
    [{ action: "register", token: iphone, key: encodeBase64(new Uint8Array(16)) }, 400],
    [{ action: "register", platform: "android", token: iphone, key: encodeBase64(phoneKey) }, 400],
    [{ action: "register", platform: "symbian", token: iphone, key: encodeBase64(phoneKey) }, 400],
    [{ action: "activity_register", token: activity, session: "not a session key" }, 400],
    [{ action: "activity", session: "s1", state: "exploded" }, 400],
    [{ action: "notify", title: "  " }, 400],
  ];
  for (const [body, status] of cases) {
    server();
    assertEquals((await push(post(body, signedIn))).status, status, JSON.stringify(body));
    assertEquals(toRelay().length, 0);
  }
});

Deno.test("nothing without a sign-in or the scheduler's secret", async () => {
  network((req) => {
    const { pathname } = new URL(req.url);
    if (pathname === "/auth/v1/user") return json({ msg: "bad jwt" }, 401);
    if (pathname === "/rest/v1/push_config") return json({ secret: "cron-secret" });
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
  assertEquals((await push(post({ action: "notify", title: "hi" }, { authorization: "Bearer forged" }))).status, 401);
  assertEquals((await push(post({ action: "tick" }, { "x-dzep-cron": "guess" }))).status, 401);
});

/** A lone surrogate: half a character, which Postgres and the iPhone's JSONDecoder refuse. */
const halfCharacter = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

Deno.test("a long label or alert is cut between characters, never through one", async () => {
  network((req) => {
    const { pathname } = new URL(req.url);
    if (req.url.startsWith(relayUrl)) return json({ ok: true });
    if (pathname === "/auth/v1/user") return json(user);
    if (pathname === "/rest/v1/push_devices" && req.method === "POST") return new Response(null, { status: 201 });
    if (pathname === "/rest/v1/push_devices") return json([{ token: iphone, key: encodeBase64(phoneKey), platform: "ios" }]);
    if (pathname === "/rest/v1/push_config") return json({ id: 1 });
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
  const register = { action: "register", token: iphone, key: encodeBase64(phoneKey), label: `a${"😀".repeat(40)}` };
  assertEquals((await push(post(register, signedIn))).status, 200);
  const row = JSON.parse(sent.find((r) => r.url.pathname === "/rest/v1/push_devices" && r.method === "POST")!.body);
  assertEquals(halfCharacter.test(row.label), false, "no half character reaches the database");

  const notify = { action: "notify", title: `a${"😀".repeat(60)}`, body: `a${"😀".repeat(200)}` };
  assertEquals((await push(post(notify, signedIn))).status, 200);
  const opened = (await open(phoneKey, toRelay()[0].enc)) as { title: string; body: string };
  assertEquals(halfCharacter.test(opened.title), false, "the title opens whole on the phone");
  assertEquals(halfCharacter.test(opened.body), false, "and so does the text");
  assertEquals(opened.body, `a${"😀".repeat(199)}`);
});

Deno.test("a body that isn't an object, or a key that isn't base64, is refused, not a crash", async () => {
  server();
  assertEquals((await push(post("null", signedIn))).status, 400);
  server();
  assertEquals((await push(post({ action: "register", token: iphone, key: "not base64!" }, signedIn))).status, 400);
});
