// Quick questions from the Mac popup and the iPhone's Ask tab. The DeepSeek
// key lives here (secret DEEPSEEK_API_KEY), never in the apps.
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
import { createClient } from "jsr:@supabase/supabase-js@2";

const MODEL = "deepseek-flash";
const DEEPSEEK = "https://api.deepseek.com/chat/completions";
const HISTORY_LIMIT = 40;

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
  if (status === 401) return "DeepSeek rejected the server's API key.";
  if (status === 402) return "DeepSeek: insufficient balance.";
  return `DeepSeek error ${status}${message ? `: ${message}` : ""}`;
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
  if (!chatId || !question) return json(400, { error: "chat_id (uuid) and question are required" });

  const key = Deno.env.get("DEEPSEEK_API_KEY");
  if (!key) return json(500, { error: "The server has no DeepSeek key (secret DEEPSEEK_API_KEY)." });

  // New chat, or one of this user's (RLS hides everyone else's: the insert
  // below then fails on the primary key or the policy).
  const { error: chatError } = await db.from("chats").upsert({ id: chatId }, { onConflict: "id", ignoreDuplicates: true });
  if (chatError) return json(400, { error: chatError.message });
  const { data: chat } = await db.from("chats").select("id, deleted_at").eq("id", chatId).maybeSingle();
  if (!chat) return json(404, { error: "No such chat" });
  if (chat.deleted_at) await db.from("chats").update({ deleted_at: null }).eq("id", chatId);

  const { error: questionError } = await db.from("chat_messages").insert({ chat_id: chatId, role: "user", content: question });
  if (questionError) return json(400, { error: questionError.message });

  const { data: rows } = await db
    .from("chat_messages")
    .select("role, content")
    .eq("chat_id", chatId)
    .is("error", null)
    .neq("content", "")
    .order("created_at", { ascending: false })
    .limit(HISTORY_LIMIT);
  const history = [{ role: "system", content: systemPrompt() }, ...(rows ?? []).reverse()];

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
      const res = await fetch(DEEPSEEK, {
        method: "POST",
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
        // A quick answer, not a pondered one.
        body: JSON.stringify({ model: MODEL, stream: true, thinking: { type: "disabled" }, messages: history }),
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
      if (!answer) throw new Error("DeepSeek sent an empty answer.");
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
