// What this session looks like on the phone: Claude Code's conversation rows as transcript items, keyed like
// LiveItem.toJson in packages/dzep_core/lib/live.dart, and its questions and approvals as LiveAsk.toJson has
// them. Pure functions, used by dzep.ts and its tests.

const TAIL_LINES = 60;
const TAIL_CHARS = 4000;
const NOTICE_CHARS = 1000;
const SUMMARY_CHARS = 400;
const COMMAND_CHARS = 80;

/** One transcript entry (the Mac adds `o` and `s`). */
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

export type Ask =
	| { kind: "ask"; id: string; questions: Question[] }
	| { kind: "approval"; id: string; tool: string; summary?: string }
	| { kind: "plan"; id: string; title: string };

type Question = { id: string; question: string; header?: string; options: string[]; multi?: true };

/** A content block as the Messages API has it (what `session.append` and `$.session.messages({ as: "api" })` hand over). */
export type Block = { type: string; [field: string]: unknown };

export type Command = { name: string; description?: string };

const str = (v: unknown): string => (typeof v === "string" ? v : "");

export function clip(text: string, max: number): string {
	return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

export function oneLine(text: string, max = 200): string {
	return clip(text.replace(/\s+/g, " ").trim(), max);
}

/** The last thing the agent said, flattened to one short line. */
export function summary(answer: string): string {
	return oneLine(answer, SUMMARY_CHARS);
}

/** The end of a tool's output: its last lines, at most a few thousand characters. */
export function tail(text: string): string {
	let lines = text.replace(/\s+$/, "").split("\n");
	if (lines.length > TAIL_LINES) lines = lines.slice(-TAIL_LINES);
	const out = lines.join("\n");
	return out.length > TAIL_CHARS ? out.slice(-TAIL_CHARS) : out;
}

/** What a tool call works on, in one short line: Bash's command, a file's path, a search's pattern. */
export function brief(tool: string, input: unknown): string {
	const a = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
	let text = "";
	switch (tool) {
		case "Bash":
			text = str(a.command);
			break;
		case "Read":
		case "Write":
		case "Edit":
		case "MultiEdit":
			text = str(a.file_path);
			break;
		case "NotebookEdit":
			text = str(a.notebook_path);
			break;
		case "Grep":
		case "Glob":
			text = [str(a.pattern), str(a.path)].filter(Boolean).join(" in ");
			break;
		case "WebFetch":
			text = str(a.url);
			break;
		case "WebSearch":
			text = str(a.query);
			break;
		case "Task":
		case "Agent":
			text = str(a.description);
			break;
		case "AskUserQuestion": {
			const questions = Array.isArray(a.questions) ? (a.questions as { question?: unknown }[]) : [];
			text = questions.map((q) => str(q?.question)).join(" · ");
			break;
		}
	}
	if (!text) {
		try {
			text = Object.keys(a).length > 0 ? JSON.stringify(a) : "";
		} catch {
			text = "";
		}
	}
	return oneLine(text);
}

/** A tool call as a running item; Bash says what it does in `description`. */
export function toolItem(id: string, tool: string, input: unknown): Item {
	const description = str((input as { description?: unknown } | null | undefined)?.description).trim();
	return {
		id,
		k: "tool",
		tl: tool,
		ti: tool === "Bash" && description ? oneLine(description) : undefined,
		a: brief(tool, input) || undefined,
		st: "running",
	};
}

function blockText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return (content as Block[])
		.filter((b) => b?.type === "text")
		.map((b) => str(b.text))
		.join("\n");
}

/** A tool's result on its item. */
export function applyResult(item: Item, block: Block): void {
	item.out = tail(blockText(block.content)) || undefined;
	item.st = block.is_error === true ? "error" : "ok";
}

const WRAPPED = /^<(system-reminder|local-command-caveat|command-message|command-args)>/;
const INTERRUPTED = /^\[Request interrupted by user/;

/**
 * A user turn's text blocks as the person sees them: what they typed, a slash command they ran (`/name args`),
 * a command's output (a notice), an interruption. Claude Code's own reminders are left out.
 */
function userText(text: string): { user?: string; notice?: string } {
	const t = text.trim();
	if (!t || WRAPPED.test(t)) return {};
	if (INTERRUPTED.test(t)) return { notice: "Interrupted" };
	const command = /<command-name>([^<]*)<\/command-name>/.exec(t);
	if (command) {
		const args = /<command-args>([^<]*)<\/command-args>/.exec(t)?.[1]?.trim();
		return { user: [command[1]?.trim() ?? "", args].filter(Boolean).join(" ") };
	}
	const out = /^<local-command-(?:stdout|stderr)>([\s\S]*)<\/local-command-(?:stdout|stderr)>$/.exec(t);
	if (out) {
		const notice = (out[1] ?? "").trim();
		return notice ? { notice: clip(notice, NOTICE_CHARS) } : {};
	}
	return { user: t };
}

/**
 * The items one conversation row makes ([id]: the row's; several items get `id:n`). An assistant row: its
 * text, then one running item per tool call. A user row: what the person typed (with how many images), a
 * command and its output, an interruption. Tool results aren't here: they change the item of their call
 * ([results]).
 */
export function rowItems(role: string, blocks: readonly Block[], id: string): Item[] {
	const items: Item[] = [];
	const next = () => (items.length === 0 ? id : `${id}:${items.length}`);
	if (role === "assistant") {
		const text = blocks
			.filter((b) => b?.type === "text")
			.map((b) => str(b.text).trim())
			.filter(Boolean)
			.join("\n\n");
		if (text) items.push({ id: next(), k: "assistant", t: text });
		for (const b of blocks) {
			if (b?.type === "tool_use" && typeof b.id === "string") items.push(toolItem(b.id, str(b.name) || "tool", b.input));
		}
		return items;
	}
	const typed: string[] = [];
	let images = 0;
	for (const b of blocks) {
		if (b?.type === "image") images++;
		if (b?.type !== "text") continue;
		const { user, notice } = userText(str(b.text));
		if (user) typed.push(user);
		if (notice) items.push({ id: next(), k: "notice", t: notice });
	}
	if (typed.length > 0 || images > 0) {
		items.unshift({ id: items.length === 0 ? id : `${id}:u`, k: "user", t: typed.join("\n\n") || undefined, im: images || undefined });
	}
	return items;
}

/** The tool results in a row. */
export function results(blocks: readonly Block[]): Block[] {
	return blocks.filter((b) => b?.type === "tool_result" && typeof b.tool_use_id === "string");
}

/** A system row (a notice: output of a local command, a compaction) as an item, if it is one the phone shows. */
export function systemItem(name: string | undefined, blocks: readonly Block[], id: string): Item | null {
	if (name === "compact_boundary") return { id, k: "notice", t: "Context compacted" };
	if (name !== "local_command") return null;
	const { notice } = userText(blockText(blocks));
	return notice ? { id, k: "notice", t: notice } : null;
}

/** The conversation ($.session.messages({ as: "api" }), oldest first) as items. */
export function historyItems(messages: readonly { role: string; content: readonly Block[] }[]): Item[] {
	const items: Item[] = [];
	const tools = new Map<string, Item>();
	messages.forEach((m, i) => {
		const blocks = Array.isArray(m?.content) ? m.content : [];
		for (const r of results(blocks)) {
			const item = tools.get(str(r.tool_use_id));
			if (item) applyResult(item, r);
		}
		for (const item of rowItems(m?.role ?? "", blocks, `h${i}`)) {
			items.push(item);
			if (item.k === "tool") tools.set(item.id, item);
		}
	});
	return items;
}

/** What Claude Code waits on when it asks for a tool call: questions, the plan review, or an approval. */
export function askOf(id: string, tool: string, input: unknown, planTitle = ""): Ask {
	if (tool === "ExitPlanMode") return { kind: "plan", id, title: planTitle || "Plan" };
	const questions = (input as { questions?: unknown } | null | undefined)?.questions;
	if (tool === "AskUserQuestion" && Array.isArray(questions)) {
		return {
			kind: "ask",
			id,
			questions: questions.map((q) => ({
				id: "",
				question: str(q?.question),
				header: str(q?.header) || undefined,
				options: (Array.isArray(q?.options) ? q.options : []).map((o: unknown) =>
					typeof o === "string" ? o : str((o as { label?: unknown } | null)?.label),
				),
				multi: q?.multiSelect === true ? true : undefined,
			})),
		};
	}
	const s = brief(tool, input);
	return { kind: "approval", id, tool, summary: s || undefined };
}

/** A plan file's title: its first heading, else its first line. */
export function planTitle(markdown: string): string {
	const lines = markdown.split("\n").map((l) => l.trim());
	const heading = lines.find((l) => /^#{1,6}\s+\S/.test(l));
	return oneLine((heading ?? lines.find(Boolean) ?? "").replace(/^#{1,6}\s+/, ""), 120);
}

/** The slash commands the phone offers, as `$.command.list()` gives them. */
export function commandsOf(list: readonly { name?: unknown; description?: unknown }[]): Command[] {
	const out: Command[] = [];
	const seen = new Set<string>();
	for (const c of list) {
		if (typeof c?.name !== "string" || !c.name || seen.has(c.name)) continue;
		seen.add(c.name);
		const description = oneLine(str(c.description), COMMAND_CHARS);
		out.push({ name: c.name, description: description || undefined });
	}
	return out;
}

/** The kitty window Claude Code runs in, as Džep keys it (`kitty-23224/24`), from its environment. */
export function windowKey(listenOn: string | undefined, windowId: string | undefined): string | null {
	if (!listenOn || !windowId) return null;
	const socket = listenOn.replace(/^unix:/, "").split("/").pop();
	return socket ? `${socket}/${windowId}` : null;
}

/** A phone prompt for Claude Code: the text, then the images the Mac saved, which Claude opens by path. */
export function promptText(text: string, files: readonly string[]): string {
	const images = files.map((f) => `[Image: ${f}]`).join("\n");
	return [text.trim(), images].filter(Boolean).join("\n\n");
}
