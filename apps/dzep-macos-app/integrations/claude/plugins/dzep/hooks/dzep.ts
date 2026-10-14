import type { EngineInterface, On, Timer } from "claude-code";
import {
	type Ask,
	type Block,
	type Item,
	applyResult,
	askOf,
	commandsOf,
	historyItems,
	pingProof,
	planTitle,
	promptText,
	results,
	rowItems,
	summary,
	systemItem,
	windowKey,
} from "./items.ts";

// Džep (github.com/danyzmaj-apps/dzep) for Claude Code, the twin of its omp extensions:
//
// - /idea, /do and /note talk to the Džep menu-bar app over its localhost API, without a Claude turn and
//   while Claude works. Ideas land under the current repo's name as their @project; todos are one global
//   work list; notes are free text. The todo command is /do, as in omp (whose own /todo wins there).
// - This session goes to the phone through Džep: the transcript as items, the answer as it's written,
//   whether Claude is busy, and the questions, approvals and plan reviews it waits on (answered on the phone
//   by keys Džep types into this terminal window). From the phone you can prompt (with images), stop, and page
//   back through older history. The protocol is described in packages/dzep_core/lib/live.dart; mods have no
//   WebSocket, so it goes over HTTP long polls (POST /v1/live/http).
//
// Only an interactive session talks, and only to Džep's local API on 127.0.0.1 (port and token from
// ~/.config/dzep/cli.json, or the file DZEP_CLI_JSON names), once whatever answers at that port has proved it
// holds the token. While Džep isn't running it quietly tries again every few seconds.

const VERSION = 1;
const HELLO_ITEMS = 300;
const RETRY_MS = 3000;
const APPEND_MS = 100;
const NOT_RUNNING = "Džep isn't running. Open it (it lives in the menu bar), then try again.";
const IDEA_USAGE = "Usage: /idea <text> | /idea list | /idea do <n|text>";
const DO_USAGE = "Usage: /do <text> | /do list | /do done <n|text>";

type Cli = { port: number; token: string };
type Idea = { id: string; title: string; notes: string; project: string; created_at: string };
type Numbered = Idea & { index: number };
type Frame = Record<string, unknown>;
/** The answer being written: one text block of one model request. */
type Stream = { id: string; text: string; pending: string; created: boolean; timer?: Timer };

class DzepError extends Error {}

// Live ids: unique to this module, so never confused with row ids or another connection's.
const instance = Math.random().toString(36).slice(2, 10);
let counter = 0;
const newId = () => `live-${instance}-${++counter}`;

// The session as streamed: an interactive one only.
let active = false;
let cli: Cli | undefined;
let conn: string | undefined;
let connecting = false;
let retry: Timer | undefined;
let sending = false;
let polling = false;
let outbox: Frame[] = [];

// Items older than the ones sent so far, for `older` requests.
let older: Item[] = [];
let meta = "";
let commands = "";
let turnId: string | undefined;
// The turn showed an interruption itself.
let interrupted = false;
// Phone prompts waiting for their turn: the run goes on after this one ends.
let queued = 0;
// Text blocks being written, oldest first, until their row is stored.
const streams = new Map<string, Stream>();
const tools = new Map<string, Item>();
// What Claude waits on, in the order its dialogs come: the first is on screen.
const asks: Ask[] = [];
// Images the Mac saved for phone prompts, which Read may open without asking.
const files = new Set<string>();
// The plan file plan mode writes, whose heading names the plan review.
let planPath: string | undefined;

// ------------------------------------------------------------ local API

async function readCli($: EngineInterface): Promise<Cli | undefined> {
	try {
		const path = (await $.env.get("DZEP_CLI_JSON")) || `${await $.env.get("HOME")}/.config/dzep/cli.json`;
		const json = JSON.parse(await $.fs.read(path)) as { port?: unknown; token?: unknown };
		return typeof json.port === "number" && typeof json.token === "string"
			? { port: json.port, token: json.token }
			: undefined;
	} catch {
		return undefined;
	}
}

/** Whether the Džep that wrote cli.json answers at its port: it proves it holds the token ([pingProof] of
 * the port and a fresh nonce) before the token, the transcript or a phone's prompt goes anywhere. After Džep
 * quits, anything could be listening at its old port. */
async function proven($: EngineInterface, c: Cli): Promise<boolean> {
	const nonce = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
	try {
		const res = await $.http.fetch(`http://127.0.0.1:${c.port}/v1/ping?nonce=${nonce}`, { method: "GET" });
		const { proof } = JSON.parse(res.text) as { proof?: unknown };
		return res.ok && proof === (await pingProof(c.token, c.port, nonce));
	} catch {
		return false;
	}
}

async function call<T>($: EngineInterface, method: string, path: string, body?: unknown): Promise<T> {
	const c = await readCli($);
	if (!c || !(await proven($, c))) throw new DzepError(NOT_RUNNING);
	let res: { status: number; ok: boolean; text: string };
	try {
		res = await $.http.fetch(`http://127.0.0.1:${c.port}${path}`, {
			method,
			headers: { authorization: `Bearer ${c.token}`, "content-type": "application/json" },
			body: body === undefined ? undefined : JSON.stringify(body),
		});
	} catch {
		throw new DzepError(NOT_RUNNING);
	}
	let json: T & { error?: string };
	try {
		json = JSON.parse(res.text);
	} catch {
		json = {} as T & { error?: string };
	}
	if (!res.ok) throw new DzepError(json.error ?? `Džep answered ${res.status}.`);
	return json;
}

/** The repo the session works in (the nearest folder with .git), else its folder: an idea's @project. */
async function project($: EngineInterface): Promise<string> {
	const cwd = await $.session.cwd();
	let dir = cwd.replace(/\/+$/, "") || "/";
	for (;;) {
		if (await $.fs.exists(`${dir}/.git`)) return dir.split("/").pop() || dir;
		const parent = dir.slice(0, dir.lastIndexOf("/")) || "/";
		if (parent === dir) return cwd.split("/").filter(Boolean).pop() ?? cwd;
		dir = parent;
	}
}

/** The project's ideas, oldest first, numbered 1..n: the numbers /idea list prints. */
async function ideas($: EngineInterface, proj: string): Promise<Numbered[]> {
	const { ideas } = await call<{ ideas: Idea[] }>($, "GET", `/v1/ideas?project=${encodeURIComponent(proj)}`);
	return ideas.map((idea, i) => ({ ...idea, index: i + 1 }));
}

/** Open todos, oldest first, numbered like /do list prints them. */
async function todos($: EngineInterface): Promise<Numbered[]> {
	const { ideas } = await call<{ ideas: Idea[] }>($, "GET", "/v1/ideas?kind=todo");
	return ideas.map((todo, i) => ({ ...todo, index: i + 1 }));
}

/** The one of [items] that [selector] names: its number, or words in it. */
export function find(items: Numbered[], selector: string, what: string, text: (i: Numbered) => string): Numbered {
	const hits = /^\d+$/.test(selector)
		? items.filter((i) => i.index === Number(selector))
		: items.filter((i) => text(i).toLowerCase().includes(selector.toLowerCase()));
	if (hits.length === 0) {
		throw new DzepError(/^\d+$/.test(selector) ? `${what} #${selector} not found.` : `No ${what.toLowerCase()} matches "${selector}".`);
	}
	if (hits.length > 1) throw new DzepError(`Ambiguous — matches ${hits.map((i) => `#${i.index}`).join(", ")}. Use the number.`);
	return hits[0] as Numbered;
}

/** "14:02" today, "7 Oct 14:02" otherwise — the same stamp the app shows. */
export function stamp(iso: string): string {
	const d = new Date(iso);
	const time = d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
	if (d.toDateString() === new Date().toDateString()) return time;
	return `${d.toLocaleDateString("en-GB", { day: "numeric", month: "short" })} ${time}`;
}

/** /idea: capture an idea under this repo's project, list them, or start one. */
async function idea($: EngineInterface, args: string): Promise<{ text?: string }> {
	const raw = args.trim();
	if (!raw) {
		$.ui.toast(IDEA_USAGE);
		return {};
	}
	const proj = await project($);
	const head = raw.split(/\s+/)[0] ?? "";
	const sub = head.toLowerCase();
	const rest = raw.slice(head.length).trim();
	if (sub === "list") {
		const list = await ideas($, proj);
		if (list.length === 0) return { text: `Džep · @${proj}\n\nNo ideas for this repo yet.` };
		const rows = list.map((i) => {
			const notes = i.notes ? `\n     ${i.notes.split("\n")[0]}` : "";
			return `${i.index}. ${i.title}  · ${stamp(i.created_at)}${notes}`;
		});
		return { text: `Džep · @${proj}\n\n${rows.join("\n")}` };
	}
	if (sub === "do") {
		if (!rest) {
			$.ui.toast("Usage: /idea do <n|text>");
			return {};
		}
		const hit = find(await ideas($, proj), rest, "Idea", (i) => `${i.title} ${i.notes}`);
		$.ui.toast(`Idea #${hit.index} — starting: ${hit.title}`);
		const notes = hit.notes ? `\n\n${hit.notes}` : "";
		// A command can't start a turn itself: the prompt goes once it has finished.
		$.clock.after(0, () => submit($, `Work on idea #${hit.index}: ${hit.title}${notes}`));
		return {};
	}
	const text = (sub === "new" ? rest : raw).replace(/\s+/g, " ").trim();
	if (!text) {
		$.ui.toast("Usage: /idea new <text>");
		return {};
	}
	await call($, "POST", "/v1/ideas", { title: text, project: proj });
	$.ui.toast(`Idea captured in Džep under @${proj}`);
	return {};
}

/** /do: add a todo, list the open ones, or mark one done. */
async function todo($: EngineInterface, args: string): Promise<{ text?: string }> {
	const raw = args.trim();
	if (!raw) {
		$.ui.toast(DO_USAGE);
		return {};
	}
	const head = raw.split(/\s+/)[0] ?? "";
	const sub = head.toLowerCase();
	const rest = raw.slice(head.length).trim();
	if (sub === "list") {
		const open = await todos($);
		if (open.length === 0) return { text: "Džep · todos\n\nNothing open." };
		return { text: `Džep · todos\n\n${open.map((t) => `${t.index}. [ ] ${t.title}  · ${stamp(t.created_at)}`).join("\n")}` };
	}
	if (sub === "done") {
		if (!rest) {
			$.ui.toast("Usage: /do done <n|text>");
			return {};
		}
		const hit = find(await todos($), rest, "Todo", (t) => t.title);
		await call($, "PATCH", `/v1/ideas/${hit.id}`, { done: true });
		$.ui.toast(`Done: ${hit.title}`);
		return {};
	}
	await call($, "POST", "/v1/ideas", { title: raw.replace(/\s+/g, " ").trim(), kind: "todo" });
	$.ui.toast("Todo added to Džep");
	return {};
}

/** /note: a quick note. */
async function note($: EngineInterface, args: string): Promise<{ text?: string }> {
	const text = args.trim();
	if (!text) {
		$.ui.toast("Usage: /note <text>");
		return {};
	}
	await call($, "POST", "/v1/ideas", { title: text, kind: "note" });
	$.ui.toast("Note saved to Džep");
	return {};
}

/** Runs a command; Džep's own errors (not running, nothing matches) are a toast, not a failure. */
async function command($: EngineInterface, name: "idea" | "do" | "note", args: string): Promise<{ text?: string }> {
	try {
		if (name === "idea") return await idea($, args);
		if (name === "do") return await todo($, args);
		return await note($, args);
	} catch (e) {
		if (!(e instanceof DzepError)) throw e;
		$.ui.toast(e.message);
		return {};
	}
}

/** A prompt as the person's own words, run when Claude is next idle. */
function submit($: EngineInterface, text: string): void {
	queued++;
	const settled = () => {
		queued--;
		// It never ran: nothing follows the run that ended.
		if (queued === 0 && turnId === undefined) send($, { t: "busy", busy: false });
	};
	$.prompt.submit({ text, asUser: true }).then(settled, settled);
}

// ------------------------------------------------------------ live: transport

/** One long-poll request; its answer, or the status that says the connection is gone. */
async function post(
	$: EngineInterface,
	body: Frame,
): Promise<{ status: number; conn?: string; frames: Frame[] }> {
	const c = cli;
	if (!c) return { status: 0, frames: [] };
	const res = await $.http.fetch(`http://127.0.0.1:${c.port}/v1/live/http`, {
		method: "POST",
		headers: { authorization: `Bearer ${c.token}`, "content-type": "application/json" },
		body: JSON.stringify(body),
	});
	if (!res.ok) return { status: res.status, frames: [] };
	const json = JSON.parse(res.text) as { conn?: unknown; frames?: unknown };
	return {
		status: res.status,
		conn: typeof json.conn === "string" ? json.conn : undefined,
		frames: Array.isArray(json.frames) ? (json.frames as Frame[]) : [],
	};
}

function send($: EngineInterface, frame: Frame): void {
	if (!active) return;
	outbox.push(frame);
	if (conn) void pump($);
}

function sendItem($: EngineInterface, item: Item): void {
	send($, { t: "item", item });
}

/** Sends what waits, one request at a time so the frames arrive in order. */
async function pump($: EngineInterface): Promise<void> {
	const c = conn;
	if (sending || !c || outbox.length === 0) return;
	sending = true;
	const frames = outbox.splice(0, 200);
	try {
		const res = await post($, { conn: c, frames });
		if (c !== conn) return;
		if (res.status !== 200) return lost($, c);
		for (const f of res.frames) await onFrame($, f);
	} catch {
		lost($, c);
	} finally {
		sending = false;
	}
	if (outbox.length > 0) void pump($);
}

/** Waits for the Mac's frames, again and again while connected. */
async function poll($: EngineInterface): Promise<void> {
	const c = conn;
	if (polling || !c) return;
	polling = true;
	try {
		const res = await post($, { conn: c, frames: [], wait: true });
		if (c !== conn) return;
		if (res.status !== 200) return lost($, c);
		for (const f of res.frames) await onFrame($, f);
	} catch {
		return lost($, c);
	} finally {
		polling = false;
	}
	void poll($);
}

/** The connection [c] is gone (Džep quit, or forgot it): say hello again soon. */
function lost($: EngineInterface, c: string): void {
	if (conn !== c) return;
	conn = undefined;
	later($);
}

function later($: EngineInterface): void {
	if (active && !retry) retry = $.clock.after(RETRY_MS, () => void connect($));
}

/** Opens a connection with the session's hello, then what's in flight. */
async function connect($: EngineInterface): Promise<void> {
	retry = undefined;
	if (!active || conn || connecting) return;
	connecting = true;
	try {
		const c = await readCli($);
		if (!c || !(await proven($, c))) return later($);
		cli = c;
		const hello = await helloFrame($);
		outbox = [];
		const res = await post($, { frames: [hello, ...inFlight()] });
		if (res.status !== 200 || !res.conn) return later($);
		conn = res.conn;
		for (const f of res.frames) await onFrame($, f);
		void pump($);
		void poll($);
	} catch {
		later($);
	} finally {
		connecting = false;
	}
}

/** The session as it stands: its newest items, oldest first, and what describes it. */
async function helloFrame($: EngineInterface): Promise<Frame> {
	let items: Item[] = [];
	try {
		items = historyItems(await $.session.messages({ as: "api" }));
	} catch {}
	const start = Math.max(0, items.length - HELLO_ITEMS);
	older = items.slice(0, start);
	const m = await metaOf($);
	meta = JSON.stringify(m);
	const list = await commandList($);
	commands = JSON.stringify(list);
	return {
		t: "hello",
		v: VERSION,
		agent: "claude",
		session: { id: await $.session.id(), title: m.title, cwd: await $.session.cwd(), model: m.model },
		window: windowKey(await $.env.get("KITTY_LISTEN_ON"), await $.env.get("KITTY_WINDOW_ID")),
		term: await termOf($),
		pid: instance,
		busy: turnId !== undefined,
		ctx: m.ctx,
		items: items.slice(start),
		older: start > 0,
		commands: list,
	};
}

/** Where Claude runs, as Džep maps it to a terminal window (packages/dzep_core/lib/terminal.dart): the
 * terminals' variables, and its tty where only a tty tells (Terminal, Ghostty); read once. */
let term: Record<string, string> | undefined;
async function termOf($: EngineInterface): Promise<Record<string, string>> {
	if (term) return term;
	const vars: [string, string | undefined][] = [
		["TERM_PROGRAM", await $.env.get("TERM_PROGRAM")],
		["KITTY_WINDOW_ID", await $.env.get("KITTY_WINDOW_ID")],
		["KITTY_PID", await $.env.get("KITTY_PID")],
		["KITTY_LISTEN_ON", await $.env.get("KITTY_LISTEN_ON")],
		["TMUX", await $.env.get("TMUX")],
		["TMUX_PANE", await $.env.get("TMUX_PANE")],
		["WEZTERM_PANE", await $.env.get("WEZTERM_PANE")],
		["WEZTERM_UNIX_SOCKET", await $.env.get("WEZTERM_UNIX_SOCKET")],
		["ITERM_SESSION_ID", await $.env.get("ITERM_SESSION_ID")],
		["TERM_SESSION_ID", await $.env.get("TERM_SESSION_ID")],
	];
	const found: Record<string, string> = {};
	for (const [name, v] of vars) if (v) found[name] = v;
	if (!found.TMUX && (found.TERM_PROGRAM === "Apple_Terminal" || found.TERM_PROGRAM === "ghostty")) {
		try {
			// The hook's process shares Claude's controlling terminal; its parent is Claude.
			const r: unknown = await $.process.run(
				["/bin/sh", "-c", "t=$(ps -o tty= -p $$); case $t in ttys*) ;; *) t=$(ps -o tty= -p $PPID);; esac; echo $t"],
				{ timeoutMs: 3000 },
			);
			const out = r && typeof r === "object" && "stdout" in r ? r.stdout : undefined;
			const tty = typeof out === "string" ? out.trim() : "";
			if (/^ttys\d+$/.test(tty)) found.tty = `/dev/${tty}`;
		} catch {}
	}
	term = found;
	return found;
}

/** What isn't stored yet: the answer being written, and the question on screen. */
function inFlight(): Frame[] {
	const frames: Frame[] = [];
	for (const s of streams.values()) {
		if (!s.created) continue;
		frames.push({ t: "item", item: { id: s.id, k: "assistant", t: s.text || undefined } });
		s.pending = "";
	}
	if (asks[0]) frames.push({ t: "ask", ask: asks[0] });
	return frames;
}

async function metaOf($: EngineInterface): Promise<{ title: string; model: string; ctx: number | null }> {
	let ctx: number | null = null;
	try {
		const percent = (await $.session.usage()).context.percent;
		if (typeof percent === "number" && Number.isFinite(percent)) ctx = Math.round(percent);
	} catch {}
	let model = "";
	try {
		model = await $.session.model();
	} catch {}
	return { title: "", model, ctx };
}

async function commandList($: EngineInterface): Promise<{ name: string; description?: string }[]> {
	try {
		return commandsOf(await $.command.list());
	} catch {
		return [];
	}
}

/** A frame from the Mac: a prompt, a stop, a page of older history. */
async function onFrame($: EngineInterface, msg: Frame): Promise<void> {
	const reply = (extra: Frame = {}) => send($, { t: "reply", req: msg.req, ...extra });
	switch (msg.t) {
		case "prompt": {
			const text = typeof msg.text === "string" ? msg.text : "";
			const paths = (Array.isArray(msg.files) ? msg.files : []).filter((f): f is string => typeof f === "string");
			if (!text.trim() && paths.length === 0) return reply({ error: "Nothing to send." });
			for (const p of paths) files.add(p);
			// Claude Code can't steer a run: a prompt waits for it to end.
			submit($, promptText(text, paths));
			return reply();
		}
		case "abort":
			if (turnId !== undefined) {
				try {
					await $.turn.abort({ turnId });
				} catch (e) {
					return reply({ error: e instanceof Error ? e.message : String(e) });
				}
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
			return reply({ error: `Unknown request: ${String(msg.t)}` });
	}
}

// ------------------------------------------------------------ live: the session

function flush($: EngineInterface, s: Stream): void {
	s.timer = undefined;
	if (!s.pending) return;
	send($, { t: "append", id: s.id, text: s.pending });
	s.pending = "";
}

/** Text as it streams, sent every [APPEND_MS] at most. */
function streamText($: EngineInterface, key: string, text: string): void {
	if (!text) return;
	let s = streams.get(key);
	if (!s) {
		s = { id: newId(), text: "", pending: "", created: false };
		streams.set(key, s);
	}
	if (!s.created) {
		s.created = true;
		sendItem($, { id: s.id, k: "assistant" });
	}
	s.text += text;
	s.pending += text;
	const stream = s;
	s.timer ??= $.clock.after(APPEND_MS, () => flush($, stream));
}

/** The oldest streamed block, done now that its row is stored: its id goes to the row's text. */
function endStream(): Stream | undefined {
	const [key, s] = streams.entries().next().value ?? [];
	if (key === undefined || !s) return undefined;
	streams.delete(key);
	s.timer?.cancel();
	s.timer = undefined;
	return s;
}

function publishAsk($: EngineInterface, ask: Ask): void {
	if (asks.some((a) => a.id === ask.id)) return;
	asks.push(ask);
	if (asks.length === 1) send($, { t: "ask", ask });
}

function clearAsk($: EngineInterface, id: string): void {
	const at = asks.findIndex((a) => a.id === id);
	if (at < 0) return;
	asks.splice(at, 1);
	if (at === 0) send($, { t: "ask", ask: asks[0] ?? null });
}

/** One stored conversation row, of the main conversation unless it answers a tool call. */
function onRow(
	$: EngineInterface,
	message: { type: string; name?: string; isMeta?: true; content: readonly Block[] },
	uuid: string,
	agentId: string | undefined,
): void {
	const blocks = Array.isArray(message.content) ? message.content : [];
	for (const r of results(blocks)) {
		const id = r.tool_use_id as string;
		clearAsk($, id);
		const item = tools.get(id);
		if (agentId || !item) continue;
		applyResult(item, r);
		tools.delete(id);
		sendItem($, item);
	}
	if (agentId) return;
	switch (message.type) {
		case "assistant":
			for (const item of rowItems("assistant", blocks, uuid)) {
				if (item.k === "assistant") {
					const s = endStream();
					if (s) item.id = s.id;
				} else if (item.k === "tool") {
					if (tools.has(item.id)) continue;
					tools.set(item.id, item);
					const use = blocks.find((b) => b.id === item.id);
					const path = (use?.input as { file_path?: unknown } | undefined)?.file_path;
					if (typeof path === "string" && /\/plans\/[^/]+\.md$/.test(path)) planPath = path;
				}
				sendItem($, item);
			}
			return;
		case "user":
			if (message.isMeta) return;
			for (const item of rowItems("user", blocks, uuid)) {
				if (item.k === "notice" && item.t === "Interrupted") interrupted = true;
				sendItem($, item);
			}
			return;
		case "system": {
			const item = systemItem(message.name, blocks, uuid);
			if (item) sendItem($, item);
			return;
		}
	}
}

/** Title, model or context use changed, or the commands (a plugin reloaded): the Mac hears it. */
async function sendMeta($: EngineInterface): Promise<void> {
	const m = await metaOf($);
	const json = JSON.stringify(m);
	const list = await commandList($);
	const listJson = JSON.stringify(list);
	if (json === meta && listJson === commands) return;
	const changed = listJson !== commands;
	meta = json;
	commands = listJson;
	send($, { t: "meta", ...m, ...(changed ? { commands: list } : {}) });
}

/** Another conversation in this Claude Code (/clear, /resume): its own hello, once it's there. */
function restart($: EngineInterface): void {
	for (const s of streams.values()) s.timer?.cancel();
	streams.clear();
	tools.clear();
	asks.length = 0;
	older = [];
	turnId = undefined;
	planPath = undefined;
	$.clock.after(800, async () => {
		if (!active) return;
		if (!conn) return void connect($);
		send($, await helloFrame($));
	});
}

export function register(on: On): void {
	on("session.start", async ($, e, next) => {
		const result = await next(e);
		active = e.isInteractive && e.surface === "terminal";
		if (active) $.clock.after(0, () => void connect($));
		for (const spec of [
			{ name: "idea", description: "Capture an idea into Džep (under this repo's project), or /idea list, /idea do <n|text>", argumentHint: "<text> | list | do <n|text>" },
			{ name: "do", description: "Add a todo to Džep, or /do list, /do done <n|text>", argumentHint: "<text> | list | done <n|text>" },
			{ name: "note", description: "Write a quick note into Džep", argumentHint: "<text>" },
		]) {
			try {
				await $.command.register({ ...spec, immediate: true });
			} catch {}
		}
		return result;
	});

	on("command.run", { command: "idea" }, async ($, e) => command($, "idea", e.args));
	on("command.run", { command: "do" }, async ($, e) => command($, "do", e.args));
	on("command.run", { command: "note" }, async ($, e) => command($, "note", e.args));

	on("session.end", async ($, e, next) => {
		if (active) {
			if (e.reason === "clear" || e.reason === "resume") {
				restart($);
			} else {
				// Claude Code is quitting: the phone hears it now, not when the connection times out.
				active = false;
				const c = conn;
				conn = undefined;
				if (c) {
					try {
						await post($, { conn: c, frames: outbox.splice(0), close: true });
					} catch {}
				}
			}
		}
		return next(e);
	});

	on("turn.start", async ($, e, next) => {
		if (active && turnId === undefined) {
			turnId = e.turnId;
			interrupted = false;
			send($, { t: "busy", busy: true });
		}
		return next(e);
	});

	on("turn.step", async function* ($, e, next) {
		const stream = next(e);
		if (!active || e.agentId !== undefined) return yield* stream;
		let step = await stream.next();
		while (step.done !== true) {
			const chunk = step.value;
			if (chunk.kind === "text") {
				try {
					streamText($, `${e.turnId}:${e.index}:${chunk.index}`, chunk.text);
				} catch {}
			}
			yield chunk;
			step = await stream.next();
		}
		return step.value;
	});

	on("turn.complete", async ($, e, next) => {
		if (active && e.agentId === undefined && e.turnId === turnId) {
			turnId = undefined;
			for (const s of streams.values()) {
				s.timer?.cancel();
				flush($, s);
			}
			streams.clear();
			if (e.isAborted && !interrupted) sendItem($, { id: newId(), k: "notice", t: "Interrupted" });
			if (e.reason === "error") sendItem($, { id: newId(), k: "notice", t: "The answer broke off with an error." });
			if (asks.length > 0) {
				asks.length = 0;
				send($, { t: "ask", ask: null });
			}
			try {
				await sendMeta($);
			} catch {}
			// A phone prompt waits: the run goes on.
			if (queued === 0) send($, { t: "busy", busy: false, summary: summary(e.answer) || undefined });
		}
		return next(e);
	});

	on("session.append", async ($, e, next) => {
		if (active) {
			try {
				onRow($, e.message, e.uuid, e.agentId);
			} catch {}
		}
		return next(e);
	});

	on("tool.check", async ($, e, next) => {
		const decided = await next(e);
		if (!active || decided.decision !== "ask" || decided.decider !== undefined) return decided;
		const input = e.input as { file_path?: unknown; plan?: unknown } | undefined;
		// An image from the phone, which Džep saved for this session.
		if (e.tool === "Read" && typeof input?.file_path === "string" && files.has(input.file_path)) {
			return { decision: "allow", reason: "An image sent from the phone through Džep" };
		}
		if (!e.tool_use_id) return decided;
		let title = typeof input?.plan === "string" ? planTitle(input.plan) : "";
		if (e.tool === "ExitPlanMode" && !title && planPath) {
			try {
				title = planTitle(await $.fs.read(planPath));
			} catch {}
		}
		publishAsk($, askOf(e.tool_use_id, e.tool, e.input, title));
		return decided;
	});
}
