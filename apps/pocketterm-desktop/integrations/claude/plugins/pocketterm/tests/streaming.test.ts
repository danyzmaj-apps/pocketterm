import { expect, mock, test } from "claude-code/testing";
import { pingProof } from "../hooks/items.ts";

type Item = { id: string; k: string; t?: string };

test("an answer of several text blocks is one bubble on the phone, however Claude Code stores its rows", async ($, on) => {
	const clock = mock.clock(on);
	mock.env(on, { HOME: "/Users/me" });
	on("fs.read", ($, e) => ({ value: e.path === "/Users/me/.config/pocketterm/cli.json" ? '{"port":4321,"token":"t0k"}' : "" }));
	on("session.start", ($, e) => e);
	on("session.id", () => ({ value: "s1" }));
	on("session.cwd", () => ({ value: "/work/repo" }));
	on("turn.start", ($, e) => e);
	on("turn.complete", ($, e) => e);
	let chunks: { index: number; text: string }[] = [];
	on("turn.step", async function* ($, e) {
		for (const c of chunks) yield { kind: "text", ...c };
		return { turnId: e.turnId, index: e.index, answer: "", toolUses: [] } as never;
	});
	// The phone's view: each assistant item's text by id, as items and appends reach it.
	const shown = new Map<string, string>();
	on("http.fetch", async ($, e) => {
		const url = new URL(e.url);
		const nonce = url.searchParams.get("nonce");
		if (url.pathname === "/v1/ping" && nonce) {
			const proof = await pingProof("t0k", 4321, nonce);
			return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ app: "pocketterm", proof }) } };
		}
		const body = JSON.parse(e.init?.body ?? "{}") as { frames?: Record<string, unknown>[]; wait?: boolean };
		// A long poll waits for the Mac, which has nothing to say.
		if (body.wait) return Promise.withResolvers<never>().promise;
		for (const f of body.frames ?? []) {
			const item = f.item as Item | undefined;
			if (f.t === "item" && item?.k === "assistant") shown.set(item.id, item.t ?? shown.get(item.id) ?? "");
			if (f.t === "append" && typeof f.id === "string") shown.set(f.id, (shown.get(f.id) ?? "") + String(f.text));
		}
		return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ conn: "c1", frames: [] }) } };
	});
	await $.session.start({ cwd: "/work/repo", isInteractive: true, surface: "terminal" } as never);
	await clock.settle();

	const tool = { type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "ls" } };
	async function turn(id: string, rows: unknown[][]): Promise<void> {
		await $.turn.start({ turnId: id } as never);
		chunks = [
			{ index: 0, text: "First " },
			{ index: 0, text: "part." },
			{ index: 2, text: "Second part." },
		];
		const step = $.turn.step({ turnId: id, index: 0, model: "m" } as never);
		while ((await step.next()).done !== true) {}
		await clock.advance(200);
		for (const [i, content] of rows.entries()) {
			await $.session.append({ message: { type: "assistant", content }, uuid: `${id}-row${i}` } as never);
		}
		await clock.settle();
	}

	// One row for the whole message.
	await turn("t1", [[{ type: "text", text: "First part." }, tool, { type: "text", text: "Second part." }]]);
	expect([...shown.values()]).toEqual(["First part.\n\nSecond part."]);

	// A row for each block.
	shown.clear();
	await turn("t2", [[{ type: "text", text: "First part." }], [tool], [{ type: "text", text: "Second part." }]]);
	expect([...shown.values()]).toEqual(["First part.", "Second part."]);
});

test("a run the person stopped ends with stopped on the phone; one that finished doesn't", async ($, on) => {
	const clock = mock.clock(on);
	mock.env(on, { HOME: "/Users/me" });
	on("fs.read", ($, e) => ({ value: e.path === "/Users/me/.config/pocketterm/cli.json" ? '{"port":4321,"token":"t0k"}' : "" }));
	on("session.start", ($, e) => e);
	on("session.id", () => ({ value: "s1" }));
	on("session.cwd", () => ({ value: "/work/repo" }));
	on("turn.start", ($, e) => e);
	on("turn.complete", ($, e) => e);
	const busy: Record<string, unknown>[] = [];
	on("http.fetch", async ($, e) => {
		const url = new URL(e.url);
		const nonce = url.searchParams.get("nonce");
		if (url.pathname === "/v1/ping" && nonce) {
			const proof = await pingProof("t0k", 4321, nonce);
			return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ app: "pocketterm", proof }) } };
		}
		const body = JSON.parse(e.init?.body ?? "{}") as { frames?: Record<string, unknown>[]; wait?: boolean };
		if (body.wait) return Promise.withResolvers<never>().promise;
		for (const f of body.frames ?? []) if (f.t === "busy" && f.busy === false) busy.push(f);
		return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ conn: "c1", frames: [] }) } };
	});
	await $.session.start({ cwd: "/work/repo", isInteractive: true, surface: "terminal" } as never);
	await clock.settle();

	async function run(id: string, isAborted: boolean): Promise<Record<string, unknown>> {
		busy.length = 0;
		await $.turn.start({ turnId: id } as never);
		await $.turn.complete({ turnId: id, isAborted, reason: isAborted ? "aborted" : "completed", answer: "Done.", text: "Done." } as never);
		await clock.settle();
		expect(busy.length).toBe(1);
		return busy[0];
	}

	expect((await run("t1", true)).stopped).toBe(true);
	expect("stopped" in (await run("t2", false))).toBe(false);
});
