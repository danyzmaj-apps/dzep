// Runs an edge function in-process for `deno test`: its Deno.serve handler is
// captured instead of listening, and every request it makes (Supabase, the
// relay, APNs, FCM) goes to the fake network a test sets with [network].
//
// Import this before anything that creates a Supabase client: supabase-js
// keeps the fetch it finds at creation.

export type Route = (req: Request) => Response | Promise<Response>;
export type Handler = (req: Request) => Promise<Response>;

const unexpected: Route = (req) => {
  throw new Error(`unexpected request: ${req.method} ${req.url}`);
};

let route: Route = unexpected;

/** What the function sent, oldest first, since the last [network]. */
export const sent: { method: string; url: URL; headers: Headers; body: string }[] = [];

globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
  const req = new Request(input, init);
  sent.push({ method: req.method, url: new URL(req.url), headers: req.headers, body: await req.clone().text() });
  return await route(req);
};

/** Answers the function's requests with [r] from now on; forgets what was sent. */
export function network(r: Route = unexpected) {
  route = r;
  sent.length = 0;
}

/**
 * The handler of the function [load] imports, loaded with [env]:
 * `handlerOf(() => import("../relay/index.ts"), {...})`. The import is
 * dynamic on purpose: the function reads its env and calls Deno.serve as it
 * loads, so both must be in place first.
 */
export async function handlerOf(load: () => Promise<unknown>, env: Record<string, string>): Promise<Handler> {
  for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
  let handler: Handler | undefined;
  const serve = Deno.serve;
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    writable: true,
    value: (...args: unknown[]) => {
      handler = args.find((a): a is Handler => typeof a === "function");
      return {};
    },
  });
  try {
    await load();
  } finally {
    Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: serve });
  }
  if (!handler) throw new Error("the function never called Deno.serve");
  return handler;
}

/** A POST to the function with a JSON [body]. */
export const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("http://function.test/", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** The env a project's functions get from Supabase. */
export const supabaseEnv = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_ANON_KEY: "anon-key",
  SUPABASE_SERVICE_ROLE_KEY: "service-key",
};

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
