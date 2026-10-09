import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

// /idea, /todo and /note talk to the Džep menu-bar app (github.com/danyzmaj-apps/dzep)
// over its localhost API. Ideas land under the current repo's name as their
// @project, so they show up in the app's sidebar next to the popup ones.
// Todos are one global work list (no project); notes are free text.
//
// Install: copy this file to ~/.omp/agent/extensions/idea.ts and restart omp.

const CLI_FILE = join(homedir(), ".config", "dzep", "cli.json");
const USAGE = "Usage: /idea <text> | /idea list | /idea do <n|text>";
const NOT_RUNNING = "Džep isn't running. Open it (it lives in the menu bar), then try again.";

type Idea = { id: string; title: string; notes: string; project: string; created_at: string };
type Numbered = Idea & { index: number };

class DzepError extends Error {}

function project(cwd: string): string {
	let dir = cwd;
	for (;;) {
		if (existsSync(join(dir, ".git"))) return basename(dir);
		const parent = dirname(dir);
		if (parent === dir) return basename(cwd);
		dir = parent;
	}
}

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
	let conn: { port: number; token: string };
	try {
		conn = JSON.parse(readFileSync(CLI_FILE, "utf8"));
	} catch {
		throw new DzepError(NOT_RUNNING);
	}
	let res: Response;
	try {
		res = await fetch(`http://127.0.0.1:${conn.port}${path}`, {
			method,
			headers: { authorization: `Bearer ${conn.token}`, "content-type": "application/json" },
			body: body === undefined ? undefined : JSON.stringify(body),
			signal: AbortSignal.timeout(3000),
		});
	} catch {
		throw new DzepError(NOT_RUNNING);
	}
	const json = (await res.json().catch(() => ({}))) as T & { error?: string };
	if (!res.ok) throw new DzepError(json.error ?? `Džep answered ${res.status}.`);
	return json;
}

/** The project's ideas, oldest first, numbered 1..n: the numbers /idea list prints. */
async function list(proj: string): Promise<Numbered[]> {
	const { ideas } = await call<{ ideas: Idea[] }>("GET", `/v1/ideas?project=${encodeURIComponent(proj)}`);
	return ideas.map((idea, i) => ({ ...idea, index: i + 1 }));
}

function find(ideas: Numbered[], selector: string): Numbered {
	if (/^\d+$/.test(selector)) {
		const hit = ideas.find((i) => i.index === Number(selector));
		if (!hit) throw new DzepError(`Idea #${selector} not found.`);
		return hit;
	}
	const needle = selector.toLowerCase();
	const hits = ideas.filter((i) => `${i.title} ${i.notes}`.toLowerCase().includes(needle));
	if (hits.length === 0) throw new DzepError(`No idea matches "${selector}".`);
	if (hits.length > 1) throw new DzepError(`Ambiguous — matches ${hits.map((i) => `#${i.index}`).join(", ")}. Use the number.`);
	return hits[0];
}

/** "14:02" today, "7 Oct 14:02" otherwise — the same stamp the app shows. */
function stamp(iso: string): string {
	const d = new Date(iso);
	const time = d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
	if (d.toDateString() === new Date().toDateString()) return time;
	return `${d.toLocaleDateString("en-GB", { day: "numeric", month: "short" })} ${time}`;
}

function render(proj: string, ideas: Numbered[]): string {
	if (ideas.length === 0) return `Džep · @${proj}\n\nNo ideas for this repo yet.`;
	const rows = ideas.map((i) => {
		const notes = i.notes ? `\n     ${i.notes.split("\n")[0]}` : "";
		return `${i.index}. ${i.title}  · ${stamp(i.created_at)}${notes}`;
	});
	return `Džep · @${proj}\n\n${rows.join("\n")}`;
}

export default function ideaExtension(pi: ExtensionAPI) {
	// The agent finished (its last agent_end of the run): Džep pushes it to the
	// iPhone, but only if nobody has used the Mac for a minute. Quiet when
	// Džep isn't running.
	pi.on("agent_end", async (event, ctx) => {
		if (event.isTerminal === false) return;
		let last = "";
		for (const m of event.messages) {
			if (m.role !== "assistant" || !Array.isArray(m.content)) continue;
			for (const part of m.content) if (part.type === "text" && part.text.trim()) last = part.text;
		}
		const summary = last.replace(/[`*_#>]/g, "").replace(/\s+/g, " ").trim();
		await call("POST", "/v1/notify", {
			title: `omp finished · ${basename(ctx.cwd)}`,
			body: summary.length > 180 ? `${summary.slice(0, 179)}…` : summary,
		}).catch(() => {});
	});

	pi.registerCommand("idea", {
		description: "Capture an idea into Džep (under this repo's project) without interrupting the agent",
		handler: async (args, ctx) => {
			const raw = (args ?? "").trim();
			if (!raw) {
				ctx.ui.notify(USAGE, "warning");
				return;
			}
			const proj = project(ctx.cwd);
			const head = raw.split(/\s+/)[0] ?? "";
			const sub = head.toLowerCase();
			const tail = raw.slice(head.length).trim();

			try {
				if (sub === "list") {
					const body = render(proj, await list(proj));
					if (!ctx.isIdle()) {
						ctx.ui.notify("Listing ideas once the agent is idle…", "info");
						await ctx.waitForIdle();
					}
					pi.sendMessage({ customType: "ideas", content: body, display: true, attribution: "user" }, { triggerTurn: false });
					return;
				}

				if (sub === "do") {
					if (!tail) {
						ctx.ui.notify("Usage: /idea do <n|text>", "warning");
						return;
					}
					const idea = find(await list(proj), tail);
					ctx.ui.notify(`Idea #${idea.index} — starting: ${idea.title}`, "info");
					const notes = idea.notes ? `\n\n${idea.notes}` : "";
					await pi.sendMessage(
						{ customType: "idea-do", content: `Work on idea #${idea.index}: ${idea.title}${notes}`, display: true, attribution: "user" },
						{ triggerTurn: true, deliverAs: "nextTurn" },
					);
					return;
				}

				const text = (sub === "new" ? tail : raw).replace(/\s+/g, " ").trim();
				if (!text) {
					ctx.ui.notify("Usage: /idea new <text>", "warning");
					return;
				}
				await call("POST", "/v1/ideas", { title: text, project: proj });
				ctx.ui.notify(`Idea captured in Džep under @${proj}`, "info");
			} catch (e) {
				if (!(e instanceof DzepError)) throw e;
				ctx.ui.notify(e.message, "warning");
			}
		},
	});

	pi.registerCommand("todo", {
		description: "Add a todo to Džep (or /todo list, /todo done <n|text>) without interrupting the agent",
		handler: async (args, ctx) => {
			const raw = (args ?? "").trim();
			if (!raw) {
				ctx.ui.notify("Usage: /todo <text> | /todo list | /todo done <n|text>", "warning");
				return;
			}
			const head = raw.split(/\s+/)[0] ?? "";
			const sub = head.toLowerCase();
			const tail = raw.slice(head.length).trim();
			try {
				// Open todos, oldest first, numbered like /todo list prints them.
				const open = async () => {
					const { ideas } = await call<{ ideas: Idea[] }>("GET", "/v1/ideas?kind=todo");
					return ideas.map((todo, i) => ({ ...todo, index: i + 1 }));
				};

				if (sub === "list") {
					const todos = await open();
					const body =
						todos.length === 0
							? "Džep · todos\n\nNothing open."
							: `Džep · todos\n\n${todos.map((t) => `${t.index}. [ ] ${t.title}  · ${stamp(t.created_at)}`).join("\n")}`;
					if (!ctx.isIdle()) {
						ctx.ui.notify("Listing todos once the agent is idle…", "info");
						await ctx.waitForIdle();
					}
					pi.sendMessage({ customType: "todos", content: body, display: true, attribution: "user" }, { triggerTurn: false });
					return;
				}

				if (sub === "done") {
					if (!tail) {
						ctx.ui.notify("Usage: /todo done <n|text>", "warning");
						return;
					}
					const todos = await open();
					const hits = /^\d+$/.test(tail)
						? todos.filter((t) => t.index === Number(tail))
						: todos.filter((t) => t.title.toLowerCase().includes(tail.toLowerCase()));
					if (hits.length === 0) throw new DzepError(`No open todo matches "${tail}".`);
					if (hits.length > 1) throw new DzepError(`Ambiguous — matches ${hits.map((t) => `#${t.index}`).join(", ")}. Use the number.`);
					await call("PATCH", `/v1/ideas/${hits[0].id}`, { done: true });
					ctx.ui.notify(`Done: ${hits[0].title}`, "info");
					return;
				}

				const text = raw.replace(/\s+/g, " ").trim();
				await call("POST", "/v1/ideas", { title: text, kind: "todo" });
				ctx.ui.notify("Todo added to Džep", "info");
			} catch (e) {
				if (!(e instanceof DzepError)) throw e;
				ctx.ui.notify(e.message, "warning");
			}
		},
	});

	pi.registerCommand("note", {
		description: "Write a quick note into Džep without interrupting the agent",
		handler: async (args, ctx) => {
			const text = (args ?? "").trim();
			if (!text) {
				ctx.ui.notify("Usage: /note <text>", "info");
				return;
			}
			try {
				await call("POST", "/v1/ideas", { title: text, kind: "note" });
				ctx.ui.notify("Note saved to Džep", "info");
			} catch (e) {
				if (!(e instanceof DzepError)) throw e;
				ctx.ui.notify(e.message, "warning");
			}
		},
	});
}
