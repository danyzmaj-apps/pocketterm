import { expect, mock, test } from "claude-code/testing";
import { askOf, historyItems, pingProof, promptText, rowItems, windowKey } from "../hooks/items.ts";

test("the session goes only to a PocketTerm that proved it holds the token; an impostor at the port gets nothing", async ($, on) => {
	const clock = mock.clock(on);
	mock.env(on, { HOME: "/Users/me" });
	on("fs.read", ($, e) => ({ value: e.path === "/Users/me/.config/pocketterm/cli.json" ? '{"port":4321,"token":"t0k"}' : "" }));
	on("session.start", ($, e) => e);
	on("session.id", () => ({ value: "s1" }));
	on("session.cwd", () => ({ value: "/work/repo" }));
	let impostor = true;
	const pings: (string | undefined)[] = [];
	const posts: { authorization?: string; frames: { t: string }[] }[] = [];
	on("http.fetch", async ($, e) => {
		const url = new URL(e.url);
		expect(url.host).toBe("127.0.0.1:4321");
		const nonce = url.searchParams.get("nonce");
		if (url.pathname === "/v1/ping" && nonce) {
			pings.push(e.init?.headers?.authorization);
			const proof = impostor ? "0".repeat(64) : await pingProof("t0k", 4321, nonce);
			return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ app: "pocketterm", proof }) } };
		}
		expect(url.pathname).toBe("/v1/live/http");
		posts.push({ authorization: e.init?.headers?.authorization, frames: JSON.parse(e.init?.body ?? "{}").frames ?? [] });
		// The hello opens a connection; PocketTerm then forgets it, so the polls stop.
		return posts.length === 1
			? { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ conn: "c1", frames: [] }) } }
			: { value: { status: 404, ok: false, headers: {}, text: "{}" } };
	});
	await $.session.start({ cwd: "/work/repo", isInteractive: true, surface: "terminal" } as never);
	await clock.settle();
	expect(pings).toEqual([undefined]);
	expect(posts).toEqual([]);
	// PocketTerm itself answers by the next try.
	impostor = false;
	await clock.advance(3000);
	expect(pings).toEqual([undefined, undefined]);
	expect(posts[0]?.authorization).toBe("Bearer t0k");
	expect(posts[0]?.frames[0]?.t).toBe("hello");
});

test("the ping proof is the one PocketTerm makes (lib/local_api.dart pingProof)", async () => {
	expect(await pingProof("t0k", 4321, "0123456789abcdef0123456789abcdef")).toBe(
		"87157d67f806577028d1a61fa7e675e36d05fcf4991ac784f43ce11d5e62d726",
	);
	// A token longer than the hash block is hashed first.
	expect(await pingProof("k".repeat(100), 1, "n")).toBe(
		"bf7a6a42b4ec04b9607c7f97edd468effbba58de68aea6333c3eed47211afef3",
	);
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
