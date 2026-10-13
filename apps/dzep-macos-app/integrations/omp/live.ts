import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

// Streams this omp session to the Džep menu-bar app (github.com/danyzmaj-apps/dzep), which relays it to the
// iPhone: the transcript as items (messages, tool calls with the end of their output), the answer as it's
// written, whether omp is busy, and the questions and approvals it waits on. From the phone you can prompt
// (with images), interrupt, and page back through older history. The protocol is described in lib/live.dart.
//
// Only the top-level interactive session talks, and only to Džep's local API on 127.0.0.1 (port and token
// from ~/.config/dzep/cli.json, or the file DZEP_CLI_JSON names). While Džep isn't running it quietly tries
// again every few seconds.
//
// Install: copy this file to ~/.omp/agent/extensions/live.ts and restart omp (or use Install in Džep's
// Settings).

const CLI_FILE = process.env.DZEP_CLI_JSON || join(homedir(), ".config", "dzep", "cli.json");
const VERSION = 1;
const HELLO_ITEMS = 300;
const RETRY_MS = 3000;
const APPEND_MS = 100;
const TOOL_MS = 300;
const BASH_POLL_MS = 500;
const BASH_GIVE_UP_MS = 60 * 60 * 1000;
const TAIL_LINES = 60;
const TAIL_CHARS = 4000;
const NOTICE_CHARS = 1000;
const SUMMARY_CHARS = 400;
const COMMAND_CHARS = 80;
const SILENT_ABORT = "__omp.silent_abort__";

/** One transcript entry, keyed like LiveItem.toJson in lib/live.dart (the Mac adds `o` and `s`). */
export type Item = {
	id: string;
	k: "user" | "assistant" | "tool" | "notice";
	t?: string;
	im?: number;
	tl?: string;
	ti?: string;
	a?: string;
	out?: string;
	st?: "running" | "ok" | "error";
};

/** The parts of omp's messages and session entries read here (packages/ai/src/types.ts, docs/session.md). */
type Part = { type?: string; text?: string; id?: string; name?: string; arguments?: unknown };
type Msg = {
	role?: string;
	content?: unknown;
	synthetic?: boolean;
	stopReason?: string;
	errorMessage?: string;
	retryRecovery?: unknown;
	toolCallId?: string;
	isError?: boolean;
	command?: string;
	code?: string;
	output?: string;
	exitCode?: number | null;
	cancelled?: boolean;
	display?: boolean;
	timestamp?: number;
};
type Entry = {
	type?: string;
	id: string;
	parentId?: string | null;
	message?: Msg;
	customType?: string;
	content?: unknown;
	display?: boolean;
	data?: { toolCallId?: string; intent?: string };
};
type Ask =
	| { kind: "ask"; id: string; questions: unknown[] }
	| { kind: "approval"; id: string; tool: string; summary?: string }
	| { kind: "plan"; id: string; title: string };

const parts = (content: unknown): Part[] => (Array.isArray(content) ? content : []);

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	return parts(content)
		.filter((p) => p?.type === "text" && typeof p.text === "string")
		.map((p) => p.text)
		.join("\n");
}

function clip(text: string, max: number): string {
	return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function oneLine(text: string, max = 200): string {
	return clip(text.replace(/\s+/g, " ").trim(), max);
}

/** The end of a tool's output: its last lines, at most a few thousand characters. */
export function tail(text: string): string {
	let lines = text.replace(/\s+$/, "").split("\n");
	if (lines.length > TAIL_LINES) lines = lines.slice(-TAIL_LINES);
	const out = lines.join("\n");
	return out.length > TAIL_CHARS ? out.slice(-TAIL_CHARS) : out;
}

/** What a tool call works on, in one short line: bash's command, a file's path, a search's pattern. */
export function brief(tool: string, args: unknown): string {
	const a = (args && typeof args === "object" ? args : {}) as Record<string, unknown>;
	const str = (key: string) => (typeof a[key] === "string" ? (a[key] as string) : "");
	let text = "";
	switch (tool) {
		case "bash":
			text = str("command");
			break;
		case "read":
		case "write":
			text = str("path");
			break;
		case "edit": {
			// omp's edit takes a patch whose sections start `[path#TAG]`.
			const input = str("input");
			const paths = [...new Set([...input.matchAll(/^\[([^\]\n#]+)#\w+\]/gm)].map((m) => m[1]))];
			text = str("path") || paths.join(", ") || (input.split("\n")[0] ?? "");
			break;
		}
		case "grep":
		case "find":
		case "glob":
			text = [str("pattern"), str("path")].filter(Boolean).join(" in ");
			break;
		case "ask": {
			const questions = Array.isArray(a.questions) ? (a.questions as { question?: unknown }[]) : [];
			text = questions.map((q) => (typeof q?.question === "string" ? q.question : "")).join(" · ");
			break;
		}
	}
	if (!text) {
		const { i: _intent, ...rest } = a;
		try {
			text = Object.keys(rest).length > 0 ? JSON.stringify(rest) : "";
		} catch {
			text = "";
		}
	}
	return oneLine(text);
}

function toolItem(id: string, name: unknown, args: unknown): Item {
	const tool = typeof name === "string" ? name : "tool";
	const intent = (args as { i?: unknown } | undefined)?.i;
	return {
		id,
		k: "tool",
		tl: tool,
		ti: typeof intent === "string" && intent.trim() ? oneLine(intent) : undefined,
		a: brief(tool, args) || undefined,
		st: "running",
	};
}

function applyResult(item: Item, content: unknown, isError: boolean): void {
	item.out = tail(textOf(content)) || undefined;
	item.st = isError ? "error" : "ok";
}

function noticeItems(id: string, content: unknown): Item[] {
	const text = textOf(content).trim();
	return text ? [{ id, k: "notice", t: clip(text, NOTICE_CHARS) }] : [];
}

/** An assistant message's text item (if it wrote any) and one running item per tool call. */
export function assistantItems(msg: Msg, id: string): Item[] {
	const items: Item[] = [];
	const text = parts(msg.content)
		.filter((p) => p?.type === "text" && typeof p.text === "string")
		.map((p) => (p.text as string).trim())
		.filter(Boolean)
		.join("\n\n");
	if (text) items.push({ id, k: "assistant", t: text });
	for (const p of parts(msg.content)) {
		if (p?.type === "toolCall" && typeof p.id === "string") items.push(toolItem(p.id, p.name, p.arguments));
	}
	return items;
}

/** What to say when an answer broke off: the error (unless a retry got past it), or that it was interrupted. */
export function endNotice(msg: Msg): string | undefined {
	if (msg.stopReason === "error" && !msg.retryRecovery) return msg.errorMessage?.trim() || "Error";
	if (msg.stopReason === "aborted" && msg.errorMessage !== SILENT_ABORT) return "Interrupted";
	return undefined;
}

/** A `!command` (or `$code`) the person ran themselves. */
function shellItem(msg: Msg, id: string): Item {
	const failed = msg.cancelled === true || (typeof msg.exitCode === "number" && msg.exitCode !== 0);
	return {
		id,
		k: "tool",
		tl: msg.role === "pythonExecution" ? "python" : "bash",
		a: oneLine(msg.command ?? msg.code ?? "") || undefined,
		out: tail(msg.output ?? "") || undefined,
		st: failed ? "error" : "ok",
	};
}

/** The items one message makes. Tool results aren't here: they change the item of their call. */
export function messageItems(msg: Msg, id: string): Item[] {
	switch (msg.role) {
		case "user": {
			if (msg.synthetic) return [];
			const text = textOf(msg.content).trim();
			const images = parts(msg.content).filter((p) => p?.type === "image").length;
			return text || images ? [{ id, k: "user", t: text || undefined, im: images || undefined }] : [];
		}
		case "assistant": {
			const items = assistantItems(msg, id);
			const notice = endNotice(msg);
			if (notice) items.push({ id: `${id}:end`, k: "notice", t: notice });
			return items;
		}
		case "bashExecution":
		case "pythonExecution":
			return [shellItem(msg, id)];
		case "custom":
		case "hookMessage":
			return msg.display ? noticeItems(id, msg.content) : [];
		default:
			return [];
	}
}

/** A session branch (getBranch(), oldest first) as items, from the last /clear on. */
export function historyItems(entries: readonly Entry[]): Item[] {
	const items: Item[] = [];
	const tools = new Map<string, Item>();
	let from = 0;
	entries.forEach((e, i) => {
		if (e?.type === "reset_boundary") from = i + 1;
	});
	for (const e of entries.slice(from)) {
		switch (e?.type) {
			case "message": {
				const msg = e.message;
				if (!msg) break;
				if (msg.role === "toolResult") {
					const item = tools.get(msg.toolCallId ?? "");
					if (item) applyResult(item, msg.content, msg.isError === true);
					break;
				}
				for (const item of messageItems(msg, e.id)) {
					items.push(item);
					if (item.k === "tool") tools.set(item.id, item);
				}
				break;
			}
			case "custom_message":
				if (e.display) items.push(...noticeItems(e.id, e.content));
				break;
			case "compaction":
				items.push({ id: e.id, k: "notice", t: "Context compacted" });
				break;
			case "custom": {
				const item = e.customType === "tool_execution_start" ? tools.get(e.data?.toolCallId ?? "") : undefined;
				if (item && typeof e.data?.intent === "string" && e.data.intent.trim()) item.ti = oneLine(e.data.intent);
				break;
			}
		}
	}
	return items;
}

/** The `ask` tool's questions as LiveQuestion.toJson has them. */
function askOf(id: string, args: unknown): Ask | null {
	const questions = (args as { questions?: unknown } | undefined)?.questions;
	if (!Array.isArray(questions)) return null;
	return {
		kind: "ask",
		id,
		questions: questions.map((q) => ({
			id: typeof q?.id === "string" ? q.id : "",
			question: typeof q?.question === "string" ? q.question : "",
			header: typeof q?.header === "string" && q.header ? q.header : undefined,
			options: (Array.isArray(q?.options) ? q.options : []).map((o: unknown) =>
				typeof o === "string" ? o : String((o as { label?: unknown } | null)?.label ?? ""),
			),
			multi: q?.multi === true ? true : undefined,
			recommended: typeof q?.recommended === "number" ? q.recommended : undefined,
		})),
	};
}

/**
 * The plan review omp opens at the end of plan mode, after a `write` (args `path` or `file_path`) to
 * `xd://propose` succeeds. Checked as omp's event controller does: the write's result carries the device
 * dispatch in `details.xdev`, whose `inner` holds the plan's file, title and whether it exists.
 */
export function planOf(id: string, toolName: string, result: unknown): Ask | null {
	if (toolName !== "write") return null;
	const details = (result as { details?: unknown } | null | undefined)?.details;
	const xdev = (details as { xdev?: unknown } | null | undefined)?.xdev as
		| { tool?: unknown; mode?: unknown; args?: unknown; inner?: unknown }
		| null
		| undefined;
	if (xdev?.tool !== "propose" || xdev.mode !== "execute") return null;
	const inner = xdev.inner as { planFilePath?: unknown; title?: unknown; planExists?: unknown } | null | undefined;
	if (
		typeof inner?.planFilePath !== "string" ||
		typeof inner.title !== "string" ||
		typeof inner.planExists !== "boolean"
	) {
		return null;
	}
	const written = (xdev.args as { title?: unknown } | null | undefined)?.title;
	const title = inner.title.trim() || (typeof written === "string" ? written.trim() : "") || "Plan";
	return { kind: "plan", id, title };
}

/** The last thing the agent said, flattened to one short line. */
function lastAnswer(messages: readonly unknown[]): string {
	let last = "";
	for (const m of messages as Msg[]) {
		if (m?.role !== "assistant") continue;
		const text = parts(m.content)
			.filter((p) => p?.type === "text" && typeof p.text === "string")
			.map((p) => p.text)
			.join(" ");
		if (text.trim()) last = text;
	}
	return oneLine(last, SUMMARY_CHARS);
}

/** The kitty window omp runs in, as Džep keys it (`kitty-23224/24`). */
function windowKey(): string | null {
	const listen = process.env.KITTY_LISTEN_ON;
	const window = process.env.KITTY_WINDOW_ID;
	return listen && window ? `${basename(listen.replace(/^unix:/, ""))}/${window}` : null;
}

function metaOf(ctx: ExtensionContext): { title: string; model: string; ctx: number | null } {
	let percent: number | null = null;
	try {
		const usage = ctx.getContextUsage();
		if (usage && Number.isFinite(usage.percent)) percent = Math.round(usage.percent);
	} catch {}
	return {
		title: ctx.sessionManager.getSessionName() ?? "",
		model: ctx.model?.name || ctx.model?.id || "",
		ctx: percent,
	};
}

/** omp's builtin slash commands, which `getCommands()` leaves out (packages/coding-agent/src/slash-commands/builtin-*.ts,
 * v18.4.2, in the order the TUI lists them). */
const BUILTIN_COMMANDS: [string, string][] = [
	["security", "Plan, run, inspect, import, and compare OMP-native security scans"],
	["settings", "Open settings menu"],
	["setup", "Open provider setup"],
	["plan", "Toggle plan mode (agent plans before executing)"],
	["plan-review", "Re-open the plan review for the latest plan (plan mode only)"],
	["vibe", "Toggle vibe mode (direct persistent fast/good worker sessions; read-only toolset)"],
	["goal", "Toggle goal mode (persistent autonomous objective for this session)"],
	["guided-goal", "Have the agent interview you in chat, then set up goal mode"],
	["loop", "Toggle loop mode: the next prompt re-submits after every yield"],
	["queue", "Queue a message for after the agent yields"],
	["model", "Switch model for this session"],
	["switch", "Switch model for this session; accepts fuzzy ids, provider/id, @role, :level"],
	["fast", "Toggle priority service tier (OpenAI service_tier=priority, Anthropic speed=fast)"],
	["slow", "Toggle slow mode (flex tier on OpenAI/Google; low priority on Anthropic past the session limit)"],
	["skillful", "Toggle listing available skills in the system prompt (session only)"],
	["extended-context", "Toggle extended context windows"],
	["computer", "Toggle the native computer-use eval prelude for this session"],
	["prewalk", "Arm or restart a one-shot model handoff"],
	["advisor", "Toggle the advisor (a second model that reviews each turn and injects notes)"],
	["export", "Export session to HTML file"],
	["trace", "Open this session's trace in the stats dashboard"],
	["dump", "Copy session transcript to clipboard (and write LLM request JSON to tmp)"],
	["share", "Share session via an encrypted link (share server or secret gist)"],
	["collab", "Share this session live via a relay"],
	["join", "Join a shared collab session"],
	["leave", "Leave the collab session"],
	["browser", "Toggle browser eval-prelude headless vs visible mode"],
	["copy", "Pick text or code from the conversation to copy"],
	["open", "Open the last link from the conversation in your browser (or pick one with /copy)"],
	["todo", "View or modify the agent's todo list"],
	["session", "Session management commands"],
	["jobs", "Show async background jobs status"],
	["usage", "Show provider usage and limits"],
	["stats", "Launch the local stats dashboard"],
	["changelog", "Show changelog entries"],
	["hotkeys", "Show all keyboard shortcuts"],
	["tools", "Show tools currently visible to the agent"],
	["context", "Show estimated context usage breakdown"],
	["extensions", "Open Extension Control Center dashboard"],
	["agents", "Open the agents hub (per-agent model, prewalk, and advisor)"],
	["git", "Open the git UI (split diff viewer, staging, commit composer)"],
	["hub", "Open the live Agent Hub"],
	["branch", "Rewind to a previous message, keeping the old path as a branch"],
	["fork", "Create a new fork from a previous message"],
	["tree", "Navigate session tree (switch branches)"],
	["login", "Login with OAuth provider"],
	["logout", "Logout from OAuth provider"],
	["mcp", "Manage MCP servers (add, list, remove, test)"],
	["ssh", "Manage SSH hosts (add, list, remove)"],
	["new", "Start a new session"],
	["fresh", "Reset provider stream state without changing the local transcript"],
	["clear", "Clear the conversation context in place, keeping the session"],
	["delete", "Delete the current session and start a new one"],
	["compact", "Manually compact the session context"],
	["shake", "Drop heavy content from context (tool results, large blocks)"],
	["handoff", "Summarize the session into a handoff document and compact in place"],
	["resume", "Resume a different session"],
	["pin", "Pin or unpin a session at the top of the resume list"],
	["btw", "Ask a side question, or browse this session's BTW history"],
	["tan", "Run a full background agent on tangential work"],
	["omfg", "Forge a TTSR rule from a complaint to stop a recurring behavior"],
	["cleanse", "Detect and fix project diagnostics with weighted parallel subagents"],
	["retry", "Retry the last failed agent turn"],
	["debug", "Open debug tools selector"],
	["memory", "Inspect and operate memory maintenance"],
	["rename", "Rename the current session (omit title to generate)"],
	["move", "Move the current session to a different directory"],
	["wt", "Move this session into a new worktree, changes included"],
	["add-dir", "Add a workspace directory to this session (multi-root)"],
	["remove-dir", "Remove a workspace directory from this session"],
	["dirs", "List this session's workspace directories"],
	["exit", "Exit the application"],
	["restart", "Restart omp with the same launch flags, resuming this session"],
	["marketplace", "Manage marketplace plugin sources and installed plugins"],
	["plugins", "View and manage installed plugins"],
	["reload-plugins", "Reload all plugins (skills, commands, hooks, tools, agents, MCP)"],
	["skills", "Search, install, and update skills from the skills.omp.sh registry"],
	["force", "Force next turn to use a specific tool"],
	["live", "Start Codex-backed realtime voice mode"],
	["record", "Start or stop recording this screen to a replayable file (omp play)"],
	["pause", "Freeze all agents (main, subagents, advisor) until resumed"],
	["quit", "Quit the application"],
];

type Command = { name: string; description?: string };

/** The slash commands the phone offers: omp's builtins, then the session's extension, prompt and skill commands. */
function commandsOf(pi: ExtensionAPI): Command[] {
	const out: Command[] = BUILTIN_COMMANDS.map(([name, description]) => ({ name, description }));
	const seen = new Set(out.map((c) => c.name));
	let more: readonly { name?: unknown; description?: unknown }[] = [];
	try {
		if (typeof pi.getCommands === "function") more = pi.getCommands() ?? [];
	} catch {}
	for (const c of more) {
		if (typeof c?.name !== "string" || !c.name || seen.has(c.name)) continue;
		seen.add(c.name);
		const description = typeof c.description === "string" ? oneLine(c.description, COMMAND_CHARS) : "";
		out.push({ name: c.name, description: description || undefined });
	}
	return out;
}

export default function liveExtension(pi: ExtensionAPI) {
	// The session this extension streams, as the newest handler saw it.
	let ctx: ExtensionContext | undefined;
	let active = false;
	let ws: WebSocket | undefined;
	let retry: Timer | undefined;

	// Live ids: unique to this omp process, so never confused with entry ids or another connection's.
	const prefix = `live-${Date.now().toString(36)}-`;
	let counter = 0;
	const newId = () => `${prefix}${++counter}`;

	// Items older than the ones sent so far, for `older` requests.
	let older: Item[] = [];
	let meta = "";
	let commands = "";
	let ask: Ask | null = null;

	// The answer being written: its text so far, and what hasn't gone out yet.
	type Stream = { id: string; text: string; pending: string; created: boolean; part: number; timer?: Timer };
	let stream: Stream | undefined;
	// An error held until it's clear no retry follows.
	let failed: Item | undefined;
	const tools = new Map<string, Item>();
	const toolArgs = new Map<string, unknown>();
	const throttles = new Map<string, { at: number; timer?: Timer }>();
	// `!command`s still running; omp records their output without a message event.
	type Shell = { item: Item; role: string; source: string; since: number };
	const shells: Shell[] = [];
	const shellEntries = new Set<string>();
	let shellPoll: Timer | undefined;

	function send(msg: object): void {
		const socket = ws;
		if (!socket || socket.readyState !== WebSocket.OPEN) return;
		try {
			socket.send(JSON.stringify(msg));
		} catch {}
	}

	const sendItem = (item: Item) => send({ t: "item", item });

	function hello(): void {
		const c = ctx;
		if (!c) return;
		let items: Item[] = [];
		try {
			items = historyItems(c.sessionManager.getBranch() as unknown as Entry[]);
		} catch {}
		const start = Math.max(0, items.length - HELLO_ITEMS);
		older = items.slice(0, start);
		const m = metaOf(c);
		meta = JSON.stringify(m);
		const list = commandsOf(pi);
		commands = JSON.stringify(list);
		send({
			t: "hello",
			v: VERSION,
			agent: "omp",
			session: { id: c.sessionManager.getSessionId(), title: m.title, cwd: c.cwd, model: m.model },
			window: windowKey(),
			pid: process.pid,
			busy: !c.isIdle(),
			ctx: m.ctx,
			items: items.slice(start),
			older: start > 0,
			commands: list,
		});
		// What's in flight isn't in the session file yet.
		if (stream?.created) {
			sendItem({ id: stream.id, k: "assistant", t: stream.text || undefined });
			stream.pending = "";
		}
		for (const shell of shells) sendItem(shell.item);
		if (ask) send({ t: "ask", ask });
	}

	function connect(): void {
		retry = undefined;
		if (!active || ws) return;
		let conn: { port?: number; token?: string };
		try {
			conn = JSON.parse(readFileSync(CLI_FILE, "utf8"));
		} catch {
			return later();
		}
		if (!conn?.port || !conn.token) return later();
		let socket: WebSocket;
		try {
			socket = new WebSocket(`ws://127.0.0.1:${conn.port}/v1/live`, {
				headers: { authorization: `Bearer ${conn.token}` },
			});
		} catch {
			return later();
		}
		ws = socket;
		// Socket callbacks run outside omp's handler guard: a throw there would end the session.
		socket.onopen = () => {
			try {
				if (ws === socket) hello();
			} catch {}
		};
		socket.onmessage = (event) => {
			try {
				if (ws === socket) onFrame(String(event.data));
			} catch {}
		};
		socket.onclose = () => {
			try {
				if (ws !== socket) return;
				ws = undefined;
				later();
			} catch {}
		};
		socket.onerror = () => {};
	}

	function later(): void {
		if (active && !retry && ctx) retry = ctx.setTimeout(connect, RETRY_MS);
	}

	function onFrame(raw: string): void {
		let msg: {
			t?: string;
			req?: unknown;
			text?: unknown;
			images?: unknown;
			deliver?: unknown;
			limit?: unknown;
		};
		try {
			msg = JSON.parse(raw);
		} catch {
			return;
		}
		const reply = (extra: object = {}) => send({ t: "reply", req: msg.req, ...extra });
		const failure = (e: unknown) => reply({ error: e instanceof Error ? e.message : String(e) });
		const c = ctx;
		if (!c) return reply({ error: "No session." });
		switch (msg.t) {
			case "prompt": {
				const text = typeof msg.text === "string" ? msg.text : "";
				const images = (Array.isArray(msg.images) ? msg.images : [])
					.filter((i) => typeof i?.data === "string" && typeof i?.mimeType === "string")
					.map((i) => ({ type: "image" as const, data: i.data as string, mimeType: i.mimeType as string }));
				if (!text.trim() && images.length === 0) return reply({ error: "Nothing to send." });
				const content = images.length > 0 ? [{ type: "text" as const, text }, ...images] : text;
				const deliverAs = msg.deliver === "followUp" ? "followUp" : "steer";
				try {
					const sent: unknown = c.isIdle() ? pi.sendUserMessage(content) : pi.sendUserMessage(content, { deliverAs });
					// It may resolve only when the run ends; never let a rejection escape.
					if (sent instanceof Promise) sent.catch(() => {});
				} catch (e) {
					return failure(e);
				}
				return reply();
			}
			case "abort":
				try {
					c.abort();
				} catch (e) {
					return failure(e);
				}
				return reply();
			case "older": {
				const limit = typeof msg.limit === "number" && msg.limit > 0 ? Math.min(msg.limit, 1000) : 200;
				const from = Math.max(0, older.length - limit);
				const items = older.slice(from);
				older = older.slice(0, from);
				return reply({ items, older: from > 0 });
			}
			default:
				return reply({ error: `Unknown request: ${msg.t}` });
		}
	}

	function flush(s: Stream): void {
		s.timer = undefined;
		if (!s.pending) return;
		send({ t: "append", id: s.id, text: s.pending });
		s.pending = "";
	}

	function liveTool(id: string, name: string, args: unknown): Item {
		let item = tools.get(id);
		if (!item) {
			item = toolItem(id, name, args);
			tools.set(id, item);
		}
		return item;
	}

	function endThrottle(id: string): void {
		const t = throttles.get(id);
		if (t?.timer && ctx) ctx.clearTimer(t.timer);
		throttles.delete(id);
	}

	function clearAsk(id: string): void {
		if (ask?.id !== id) return;
		ask = null;
		send({ t: "ask", ask: null });
	}

	/** Finds the recorded result of each running `!command` near the end of the branch. */
	function pollShells(): void {
		const c = ctx;
		if (!c) return;
		const now = Date.now();
		let entry = c.sessionManager.getLeafEntry() as unknown as Entry | undefined;
		for (let n = 0; entry && n < 200 && shells.length > 0; n++) {
			const msg = entry.message;
			if (entry.type === "message" && msg && !shellEntries.has(entry.id)) {
				const i = shells.findIndex(
					(s) =>
						s.role === msg.role &&
						s.source === (msg.command ?? msg.code) &&
						(msg.timestamp ?? now) >= s.since,
				);
				if (i >= 0) {
					const [shell] = shells.splice(i, 1);
					shellEntries.add(entry.id);
					Object.assign(shell.item, shellItem(msg, shell.item.id));
					sendItem(shell.item);
				}
			}
			entry = entry.parentId ? (c.sessionManager.getEntry(entry.parentId) as unknown as Entry | undefined) : undefined;
		}
		for (let i = shells.length - 1; i >= 0; i--) if (now - shells[i].since > BASH_GIVE_UP_MS) shells.splice(i, 1);
		if (shells.length === 0 && shellPoll) {
			c.clearTimer(shellPoll);
			shellPoll = undefined;
		}
	}

	function userShell(role: string, source: string, c: ExtensionContext): void {
		const item: Item = {
			id: newId(),
			k: "tool",
			tl: role === "pythonExecution" ? "python" : "bash",
			a: oneLine(source) || undefined,
			st: "running",
		};
		shells.push({ item, role, source, since: Date.now() });
		sendItem(item);
		shellPoll ??= c.setInterval(pollShells, BASH_POLL_MS);
	}

	/** Runs [fn] for the streamed session only; nothing gets out of a handler. */
	function live(c: ExtensionContext, fn: () => void): void {
		if (!active) return;
		ctx = c;
		try {
			fn();
		} catch {}
	}

	function restart(c: ExtensionContext): void {
		live(c, () => {
			stream = undefined;
			failed = undefined;
			ask = null;
			tools.clear();
			toolArgs.clear();
			for (const id of [...throttles.keys()]) endThrottle(id);
			shells.length = 0;
			hello();
		});
	}

	pi.on("session_start", (_event, c) => {
		try {
			active = c.agent?.kind !== "sub" && c.mode === "tui";
			if (!active) return;
			ctx = c;
			if (ws) hello();
			else connect();
		} catch {}
	});
	pi.on("session_switch", (_event, c) => restart(c));
	pi.on("session_branch", (_event, c) => restart(c));
	pi.on("session_tree", (_event, c) => restart(c));
	pi.on("session_compact", (_event, c) => live(c, hello));
	pi.on("session_shutdown", () => {
		active = false;
		const socket = ws;
		ws = undefined;
		try {
			socket?.close(1000);
		} catch {}
	});

	pi.on("agent_start", (_event, c) =>
		live(c, () => {
			// A run after a plan review: it was answered (approved, refined) on the Mac or from the phone.
			if (ask?.kind === "plan") clearAsk(ask.id);
			send({ t: "busy", busy: true });
		}),
	);
	pi.on("agent_end", (event, c) =>
		live(c, () => {
			if (event.willContinue) return;
			if (failed) sendItem(failed);
			failed = undefined;
			tools.clear();
			toolArgs.clear();
			const summary = lastAnswer(event.messages);
			send({ t: "busy", busy: false, summary: summary || undefined });
		}),
	);
	pi.on("turn_end", (_event, c) =>
		live(c, () => {
			const m = metaOf(c);
			const json = JSON.stringify(m);
			// /reload-plugins and the like change the session's own commands.
			const list = commandsOf(pi);
			const listJson = JSON.stringify(list);
			if (json === meta && listJson === commands) return;
			const changed = listJson !== commands;
			meta = json;
			commands = listJson;
			send({ t: "meta", ...m, ...(changed ? { commands: list } : {}) });
		}),
	);

	pi.on("message_start", (event, c) =>
		live(c, () => {
			const msg = event.message as unknown as Msg;
			if (msg.role === "user") {
				if (ask?.kind === "plan") clearAsk(ask.id);
				for (const item of messageItems(msg, newId())) sendItem(item);
			} else if (msg.role === "assistant") {
				if (stream?.timer) c.clearTimer(stream.timer);
				stream = { id: newId(), text: "", pending: "", created: false, part: -1 };
				// Another answer is coming: the last error was retried.
				failed = undefined;
			}
		}),
	);
	pi.on("message_update", (event, c) =>
		live(c, () => {
			const update = event.assistantMessageEvent;
			const s = stream;
			if (!s || update.type !== "text_delta" || !update.delta) return;
			let delta = update.delta;
			if (s.part !== update.contentIndex) {
				if (s.text) delta = `\n\n${delta}`;
				s.part = update.contentIndex;
			}
			if (!s.created) {
				s.created = true;
				sendItem({ id: s.id, k: "assistant" });
			}
			s.text += delta;
			s.pending += delta;
			s.timer ??= c.setTimeout(() => flush(s), APPEND_MS);
		}),
	);
	pi.on("message_end", (event, c) =>
		live(c, () => {
			const msg = event.message as unknown as Msg;
			if (msg.role === "assistant") {
				const s = stream;
				stream = undefined;
				if (s?.timer) c.clearTimer(s.timer);
				const id = s?.id ?? newId();
				const items = assistantItems(msg, id);
				// The streamed text was only whitespace: empty the item it made.
				if (s?.created && items[0]?.k !== "assistant") items.unshift({ id, k: "assistant" });
				for (const item of items) {
					if (item.k === "tool") {
						// Already running (tools can start before the answer ends): keep what it has.
						if (tools.has(item.id)) continue;
						tools.set(item.id, item);
					}
					sendItem(item);
				}
				const notice = endNotice(msg);
				if (notice) {
					const item: Item = { id: `${id}:end`, k: "notice", t: notice };
					if (msg.stopReason === "error") failed = item;
					else sendItem(item);
				}
			} else if (msg.role === "toolResult") {
				// Calls cut short get a result without ever running.
				const item = tools.get(msg.toolCallId ?? "");
				if (item?.st !== "running") return;
				applyResult(item, msg.content, msg.isError === true);
				sendItem(item);
			} else if (msg.role !== "user") {
				for (const item of messageItems(msg, newId())) sendItem(item);
			}
		}),
	);

	pi.on("tool_call", (event, c) => live(c, () => toolArgs.set(event.toolCallId, event.input)));
	pi.on("tool_execution_start", (event, c) =>
		live(c, () => {
			if (!toolArgs.has(event.toolCallId)) toolArgs.set(event.toolCallId, event.args);
			const item = liveTool(event.toolCallId, event.toolName, event.args);
			if (event.intent?.trim()) item.ti = oneLine(event.intent);
			sendItem(item);
			if (event.toolName === "ask") {
				ask = askOf(event.toolCallId, event.args);
				if (ask) send({ t: "ask", ask });
			}
		}),
	);
	pi.on("tool_execution_update", (event, c) =>
		live(c, () => {
			const item = liveTool(event.toolCallId, event.toolName, event.args);
			const out = tail(textOf((event.partialResult as { content?: unknown } | undefined)?.content));
			if (out) item.out = out;
			const t = throttles.get(event.toolCallId) ?? { at: 0 };
			throttles.set(event.toolCallId, t);
			if (t.timer) return;
			const wait = t.at + TOOL_MS - Date.now();
			if (wait <= 0) {
				t.at = Date.now();
				sendItem(item);
				return;
			}
			t.timer = c.setTimeout(() => {
				t.timer = undefined;
				t.at = Date.now();
				if (item.st === "running") sendItem(item);
			}, wait);
		}),
	);
	pi.on("tool_execution_end", (event, c) =>
		live(c, () => {
			endThrottle(event.toolCallId);
			const item = liveTool(event.toolCallId, event.toolName, toolArgs.get(event.toolCallId));
			applyResult(item, (event.result as { content?: unknown } | undefined)?.content, event.isError);
			sendItem(item);
			tools.delete(event.toolCallId);
			toolArgs.delete(event.toolCallId);
			clearAsk(event.toolCallId);
			// omp opens its plan review now, and nothing tells extensions when it closes; a run or a
			// prompt after it does (see agent_start and message_start).
			if (!event.isError) {
				const plan = planOf(event.toolCallId, event.toolName, event.result);
				if (plan) {
					ask = plan;
					send({ t: "ask", ask });
				}
			}
		}),
	);
	pi.on("tool_approval_requested", (event, c) =>
		live(c, () => {
			const summary = brief(event.toolName, toolArgs.get(event.toolCallId));
			ask = { kind: "approval", id: event.toolCallId, tool: event.toolName, summary: summary || undefined };
			send({ t: "ask", ask });
		}),
	);
	pi.on("tool_approval_resolved", (event, c) => live(c, () => clearAsk(event.toolCallId)));

	pi.on("user_bash", (event, c) => live(c, () => userShell("bashExecution", event.command, c)));
	pi.on("user_python", (event, c) => live(c, () => userShell("pythonExecution", event.code, c)));
}
