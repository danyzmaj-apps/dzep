import { expect, mock, test } from "claude-code/testing";
import { askOf, historyItems, promptText, rowItems, windowKey } from "../hooks/items.ts";

/** The local API as the commands reach it: requests recorded, answers from [answer]. */
function dzep(on: Parameters<Parameters<typeof test>[1]>[1], answer: (method: string, path: string) => unknown) {
	const calls: { method: string; path: string; body?: unknown }[] = [];
	const toasts: string[] = [];
	mock.env(on, { HOME: "/Users/me" });
	on("fs.read", ($, e) => ({ value: e.path.endsWith("/.config/dzep/cli.json") ? '{"port":4321,"token":"t0k"}' : "" }));
	on("fs.exists", ($, e) => ({ value: e.path === "/work/repo/.git" }));
	on("session.cwd", () => ({ value: "/work/repo/src" }));
	on("ui.toast", ($, e) => {
		toasts.push(e.text);
		return { value: undefined };
	});
	on("http.fetch", ($, e) => {
		const url = new URL(e.url);
		const method = e.init?.method ?? "GET";
		const path = url.pathname + url.search;
		calls.push({ method, path, body: e.init?.body ? JSON.parse(e.init.body) : undefined });
		expect(url.host).toBe("127.0.0.1:4321");
		expect(e.init?.headers?.authorization).toBe("Bearer t0k");
		return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(answer(method, path)) } };
	});
	return { calls, toasts };
}

const IDEAS = [
	{ id: "a", title: "Dark mode", notes: "", project: "repo", created_at: "2026-10-01T10:00:00Z" },
	{ id: "b", title: "Faster sync", notes: "batch writes", project: "repo", created_at: "2026-10-02T10:00:00Z" },
];

test("/idea captures under the repo's name, found by walking up to .git", async ($, on) => {
	const { calls, toasts } = dzep(on, () => ({ idea: {} }));
	const out = await $.command.run({ command: "idea", args: "  try   a new  icon " });
	expect(calls).toEqual([{ method: "POST", path: "/v1/ideas", body: { title: "try a new icon", project: "repo" } }]);
	expect(toasts).toEqual(["Idea captured in Džep under @repo"]);
	expect(out.text).toBeUndefined();
});

test("/idea list prints the repo's ideas, numbered", async ($, on) => {
	const { calls } = dzep(on, () => ({ ideas: IDEAS }));
	const out = await $.command.run({ command: "idea", args: "list" });
	expect(calls[0]?.path).toBe("/v1/ideas?project=repo");
	expect(out.text).toMatch(/^Džep · @repo\n\n1\. Dark mode {2}· .+\n2\. Faster sync {2}· .+\n {5}batch writes$/);
});

test("/do done takes a number; an ambiguous word asks for it", async ($, on) => {
	const { calls, toasts } = dzep(on, (method) => (method === "GET" ? { ideas: IDEAS } : { idea: {} }));
	await $.command.run({ command: "do", args: "done 2" });
	expect(calls.at(-1)).toEqual({ method: "PATCH", path: "/v1/ideas/b", body: { done: true } });
	await $.command.run({ command: "do", args: "done a" });
	expect(toasts.at(-1)).toBe("Ambiguous — matches #1, #2. Use the number.");
});

test("a command says Džep isn't running when cli.json is missing", async ($, on) => {
	const toasts: string[] = [];
	mock.env(on, { HOME: "/Users/me" });
	on("fs.read", () => ({ deny: "ENOENT" }));
	on("session.cwd", () => ({ value: "/work" }));
	on("fs.exists", () => ({ value: false }));
	on("ui.toast", ($, e) => {
		toasts.push(e.text);
		return { value: undefined };
	});
	await $.command.run({ command: "note", args: "remember the milk" });
	expect(toasts).toEqual(["Džep isn't running. Open it (it lives in the menu bar), then try again."]);
});

test("rows become the phone's items: prompts, commands, answers, tool calls and results", () => {
	const items = historyItems([
		{
			role: "user",
			content: [
				{ type: "text", text: "<system-reminder>\nnoise\n</system-reminder>" },
				{ type: "text", text: "fix the build" },
				{ type: "image", source: {} },
			],
		},
		{
			role: "assistant",
			content: [
				{ type: "text", text: "Looking." },
				{ type: "tool_use", id: "tu1", name: "Bash", input: { command: "make", description: "Build it" } },
			],
		},
		{ role: "user", content: [{ type: "tool_result", tool_use_id: "tu1", content: "ok\ndone", is_error: false }] },
		{ role: "user", content: [{ type: "text", text: "[Request interrupted by user for tool use]" }] },
		{
			role: "user",
			content: [
				{ type: "text", text: "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>" },
			],
		},
	]);
	expect(items).toEqual([
		{ id: "h0", k: "user", t: "fix the build", im: 1 },
		{ id: "h1", k: "assistant", t: "Looking." },
		{ id: "tu1", k: "tool", tl: "Bash", ti: "Build it", a: "make", st: "ok", out: "ok\ndone" },
		{ id: "h3", k: "notice", t: "Interrupted" },
		{ id: "h4", k: "user", t: "/model opus", im: undefined },
	]);
	expect(rowItems("user", [{ type: "text", text: "<local-command-caveat>x</local-command-caveat>" }], "r")).toEqual([]);
});

test("asks: AskUserQuestion's questions, an approval with what it does, a plan review", () => {
	expect(
		askOf("t1", "AskUserQuestion", {
			questions: [{ question: "Which?", header: "Pick", multiSelect: true, options: [{ label: "A" }, { label: "B" }] }],
		}),
	).toEqual({ kind: "ask", id: "t1", questions: [{ id: "", question: "Which?", header: "Pick", options: ["A", "B"], multi: true }] });
	expect(askOf("t2", "Write", { file_path: "/w/notes.txt", content: "x" })).toEqual({
		kind: "approval",
		id: "t2",
		tool: "Write",
		summary: "/w/notes.txt",
	});
	expect(askOf("t3", "ExitPlanMode", {}, "Paint the button")).toEqual({ kind: "plan", id: "t3", title: "Paint the button" });
});

test("a phone prompt names its images by path; the window key is kitty's socket and window", () => {
	expect(promptText(" look ", ["/tmp/a.png", "/tmp/b.jpg"])).toBe("look\n\n[Image: /tmp/a.png]\n[Image: /tmp/b.jpg]");
	expect(windowKey("unix:/tmp/kitty-123", "7")).toBe("kitty-123/7");
	expect(windowKey(undefined, "7")).toBeNull();
});
