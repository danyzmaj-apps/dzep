// Quick questions from the Mac popup and the iPhone's Ask tab, answered by
// any OpenAI-compatible chat API. The key lives here, never in the apps:
//
//   AI_API_KEY     required: the provider's API key
//   AI_BASE_URL    default https://api.deepseek.com (OpenAI: https://api.openai.com/v1,
//                  OpenRouter: https://openrouter.ai/api/v1, Ollama: http://<host>:11434/v1)
//   AI_MODEL       default deepseek-flash
//   AI_EXTRA_BODY  optional JSON merged into each request, e.g. {"temperature": 0.3};
//                  defaults to {"thinking": {"type": "disabled"}} on DeepSeek
//
//   POST /functions/v1/ask  {"chat_id": uuid, "question": text}
//   Authorization: Bearer <the user's Supabase access token>
//
// Creates the chat if it's new, saves the question, streams the answer back
// as server-sent events and saves it, all with the user's token (RLS):
//
//   data: {"delta": "text"}      … as the answer arrives
//   data: {"done": true}         saved
//   data: {"error": "message"}   failed (also saved, as the answer's error)
//
// The answer is saved even if the app goes away mid-stream (waitUntil).
// Deployed with --no-verify-jwt: the token is checked here with
// auth.getUser, which works with the project's signing keys.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";

const BASE_URL = (Deno.env.get("AI_BASE_URL") || "https://api.deepseek.com").replace(/\/+$/, "");
const MODEL = Deno.env.get("AI_MODEL") || "deepseek-flash";
const EXTRA_BODY = extraBody();
const PROVIDER = new URL(BASE_URL).host;

/// The longest question taken, and how much earlier conversation goes with
/// it (newest turns first, up to both limits).
const QUESTION_LIMIT = 16_000;
const HISTORY_LIMIT = 40;
const HISTORY_CHARS = 60_000;
const IMAGES_PER_QUESTION = 4;
/// Images sent with a request, newest first: older ones in a long chat stay
/// as "[image]" so the request doesn't grow without end.
const IMAGES_IN_HISTORY = 8;

type Turn = { role: string; content: string; images?: string[] };
type Part = { type: "text"; text: string } | { type: "image_url"; image_url: { url: string } };

/// The turns as the model takes them: a user turn with images becomes text
/// plus `image_url` parts (base64 data URLs, read with the user's token).
async function withImages(db: SupabaseClient, turns: Turn[]) {
  let budget = IMAGES_IN_HISTORY;
  const out: { role: string; content: string | Part[] }[] = [];
  for (const turn of [...turns].reverse()) {
    const paths = turn.role === "user" ? turn.images ?? [] : [];
    if (paths.length === 0) {
      out.push({ role: turn.role, content: turn.content });
      continue;
    }
    const parts: Part[] = [];
    for (const path of paths) {
      const url = budget > 0 ? await dataUrl(db, path) : null;
      if (url) {
        budget--;
        parts.push({ type: "image_url", image_url: { url } });
      } else {
        parts.push({ type: "text", text: "[an earlier image, no longer attached]" });
      }
    }
    if (turn.content) parts.push({ type: "text", text: turn.content });
    out.push({ role: "user", content: parts });
  }
  return out.reverse();
}

async function dataUrl(db: SupabaseClient, path: string): Promise<string | null> {
  const { data } = await db.storage.from("chat").download(path);
  if (!data) return null;
  return `data:${data.type || "image/png"};base64,${encodeBase64(new Uint8Array(await data.arrayBuffer()))}`;
}

function extraBody(): Record<string, unknown> {
  const raw = Deno.env.get("AI_EXTRA_BODY");
  if (!raw) return BASE_URL.includes("deepseek.com") ? { thinking: { type: "disabled" } } : {};
  const parsed = JSON.parse(raw);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("AI_EXTRA_BODY must be a JSON object");
  }
  return parsed;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function systemPrompt() {
  const today = new Date().toISOString().slice(0, 10);
  return "You answer quick questions from a software developer in a small chat on their Mac or iPhone. " +
    "Be brief and direct: lead with the answer, skip preamble. " +
    `Use Markdown only when it helps (code blocks for code, short lists). Today is ${today}.`;
}

function describe(status: number, body: string) {
  let message = body.trim();
  try {
    message = JSON.parse(body)?.error?.message ?? message;
  } catch { /* not JSON */ }
  if (status === 401) return `${PROVIDER} rejected the server's API key (secret AI_API_KEY).`;
  if (status === 402) return `${PROVIDER}: insufficient balance.`;
  if (status === 404) return `${PROVIDER} doesn't know the model "${MODEL}" (secret AI_MODEL).`;
  if (status === 429) return `${PROVIDER} is rate-limiting requests. Try again in a moment.`;
  return `${PROVIDER} error ${status}${message ? `: ${message.slice(0, 300)}` : ""}`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const authorization = req.headers.get("authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const token = authorization.replace(/^Bearer\s+/i, "");
  // Checked on a bare client: one that already carries the header would send
  // it twice.
  const { data: { user } } = await createClient(url, anon, { auth: { persistSession: false } }).auth.getUser(token);
  if (!user) return json(401, { error: "Sign in first" });
  // Everything else runs as the user, under RLS.
  const db = createClient(url, anon, {
    global: { headers: { authorization } },
    auth: { persistSession: false },
  });

  const body = await req.json().catch(() => ({}));
  const chatId = typeof body.chat_id === "string" && uuid.test(body.chat_id) ? body.chat_id : null;
  const question = typeof body.question === "string" ? body.question.trim() : "";
  // Images the app uploaded to the `chat` bucket: only from the user's own folder.
  const images: string[] = Array.isArray(body.images)
    ? body.images.filter((p: unknown): p is string =>
      typeof p === "string" && p.startsWith(`${user.id}/`) && !p.includes("..")
    )
    : [];
  if (!chatId || (!question && images.length === 0)) {
    return json(400, { error: "chat_id (uuid) and a question or images are required" });
  }
  if (question.length > QUESTION_LIMIT) {
    return json(400, { error: `That question is too long (over ${QUESTION_LIMIT.toLocaleString("en")} characters).` });
  }
  if (images.length > IMAGES_PER_QUESTION) {
    return json(400, { error: `Attach at most ${IMAGES_PER_QUESTION} images.` });
  }

  const key = Deno.env.get("AI_API_KEY");
  if (!key) return json(500, { error: "The server has no AI key yet (secret AI_API_KEY; see docs/SELF_HOSTING.md)." });

  // New chat, or one of this user's (RLS hides everyone else's: the insert
  // below then fails on the primary key or the policy).
  const { error: chatError } = await db.from("chats").upsert({ id: chatId }, { onConflict: "id", ignoreDuplicates: true });
  if (chatError) return json(400, { error: chatError.message });
  const { data: chat } = await db.from("chats").select("id, deleted_at").eq("id", chatId).maybeSingle();
  if (!chat) return json(404, { error: "No such chat" });
  if (chat.deleted_at) await db.from("chats").update({ deleted_at: null }).eq("id", chatId);

  const { error: questionError } = await db
    .from("chat_messages")
    .insert({ chat_id: chatId, role: "user", content: question, images });
  if (questionError) return json(400, { error: questionError.message });

  const { data: rows } = await db
    .from("chat_messages")
    .select("role, content, images")
    .eq("chat_id", chatId)
    .is("error", null)
    .order("created_at", { ascending: false })
    .limit(HISTORY_LIMIT);
  // Newest turns first until either limit, then back in order.
  const kept: Turn[] = [];
  let chars = 0;
  for (const row of rows ?? []) {
    if (!row.content && !row.images?.length) continue;
    chars += row.content.length;
    if (kept.length > 0 && chars > HISTORY_CHARS) break;
    kept.push(row);
  }
  kept.reverse();

  const encoder = new TextEncoder();
  let send: (event: unknown) => void = () => {};
  let finish: () => void = () => {};
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let open = true;
      send = (event) => {
        if (!open) return;
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
        } catch {
          open = false; // The app went away; the answer is still saved.
        }
      };
      finish = () => {
        if (!open) return;
        open = false;
        try {
          controller.close();
        } catch { /* already gone */ }
      };
    },
    cancel() {
      send = () => {};
      finish = () => {};
    },
  });

  const work = (async () => {
    let answer = "";
    let error: string | null = null;
    try {
      const history = [{ role: "system", content: systemPrompt() }, ...await withImages(db, kept)];
      const res = await fetch(`${BASE_URL}/chat/completions`, {
        method: "POST",
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: JSON.stringify({ ...EXTRA_BODY, model: MODEL, stream: true, messages: history }),
      });
      if (!res.ok || !res.body) throw new Error(describe(res.status, await res.text()));
      const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
      let buffer = "";
      read: while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += value;
        let nl;
        while ((nl = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, nl).trim();
          buffer = buffer.slice(nl + 1);
          if (!line.startsWith("data:")) continue;
          const data = line.slice(5).trim();
          if (data === "[DONE]") break read;
          const delta = JSON.parse(data)?.choices?.[0]?.delta?.content;
          if (typeof delta === "string" && delta) {
            answer += delta;
            send({ delta });
          }
        }
      }
      if (!answer) throw new Error(`${PROVIDER} sent an empty answer.`);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
    const { error: saveError } = await db
      .from("chat_messages")
      .insert({ chat_id: chatId, role: "assistant", content: answer, error });
    if (saveError) error ??= `Answer not saved: ${saveError.message}`;
    send(error ? { error } : { done: true });
    finish();
  })();
  // @ts-ignore EdgeRuntime is the Supabase edge runtime's global.
  EdgeRuntime.waitUntil(work);

  return new Response(stream, {
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
});
