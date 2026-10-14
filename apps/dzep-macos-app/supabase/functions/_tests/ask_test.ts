// functions/ask: what it takes, and what it saves when the AI provider fails.
import { assertEquals } from "jsr:@std/assert@1";
import { handlerOf, json, network, post, sent, supabaseEnv } from "./harness.ts";

// The edge runtime's global; here the answer's work is awaited by the test.
const pending: Promise<unknown>[] = [];
Object.assign(globalThis, { EdgeRuntime: { waitUntil: (p: Promise<unknown>) => pending.push(p) } });

const ai = "https://ai.test/v1";
const ask = await handlerOf(() => import("../ask/index.ts"), {
  ...supabaseEnv,
  AI_API_KEY: "ai-key",
  AI_BASE_URL: ai,
  AI_MODEL: "m",
});

const user = { id: "00000000-0000-0000-0000-00000000000a", email: "owner@example.com", app_metadata: {} };
const signedIn = { authorization: "Bearer user-token" };
const chatId = "00000000-0000-0000-0000-0000000000c1";

/** A lone surrogate: half a character, which Postgres refuses in JSON. */
const halfCharacter = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

Deno.test("a body that isn't an object is refused, not a crash", async () => {
  network((req) => {
    if (new URL(req.url).pathname === "/auth/v1/user") return json(user);
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
  assertEquals((await ask(post("null", signedIn))).status, 400);
});

Deno.test("a provider's long error is saved cut between characters, never through one", async () => {
  network((req) => {
    const { pathname } = new URL(req.url);
    if (req.url.startsWith(ai)) return json({ error: { message: `a${"😀".repeat(200)}` } }, 500);
    if (pathname === "/auth/v1/user") return json(user);
    if (pathname === "/rest/v1/chats" && req.method === "POST") return new Response(null, { status: 201 });
    if (pathname === "/rest/v1/chats") return json({ id: chatId, deleted_at: null });
    if (pathname === "/rest/v1/chat_messages" && req.method === "POST") return new Response(null, { status: 201 });
    if (pathname === "/rest/v1/chat_messages") return json([{ role: "user", content: "hi", images: [] }]);
    throw new Error(`unexpected request: ${req.method} ${req.url}`);
  });
  const res = await ask(post({ chat_id: chatId, question: "hi" }, signedIn));
  assertEquals(res.status, 200);
  await res.body?.cancel();
  await Promise.all(pending.splice(0));
  const saved = sent.filter((r) => r.url.pathname === "/rest/v1/chat_messages" && r.method === "POST")
    .map((r) => JSON.parse(r.body));
  const answer = saved.find((m) => m.role === "assistant");
  assertEquals(typeof answer?.error, "string");
  assertEquals(halfCharacter.test(answer.error), false, "no half character reaches the database");
});
