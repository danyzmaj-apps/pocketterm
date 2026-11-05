using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;
using PocketTerm.Core.Tests;

namespace PocketTerm.Desktop.Tests;

/// <summary>apps/pocketterm-desktop/test/live_hub_test.dart: extensions on WebSockets to a hub.</summary>
public sealed class LiveHubTests : IAsyncLifetime
{
    private const string Key = "kitty-1/7";
    private readonly LiveTemp _tmp = new("pocketterm_hub");
    private readonly List<LiveExt> _exts = [];
    private LiveHub _hub = null!;
    private FakeHttp _server = null!;

    private LiveHub NewHub(Locate? locate = null) => new(locate, new PromptFiles(_tmp["files"]), _tmp["images"]);

    public async Task InitializeAsync()
    {
        _hub = NewHub();
        _server = await FakeHttp.Start(async ctx =>
        {
            var link = new SocketLink(await ctx.WebSockets.AcceptWebSocketAsync());
            await _hub.AcceptAsync(link.Frames(), link);
            await link.CloseAsync();
        });
    }

    public async Task DisposeAsync()
    {
        foreach (var e in _exts) await e.DisposeAsync();
        await _server.DisposeAsync();
        _tmp.Dispose();
    }

    private async Task<LiveExt> Connect()
    {
        var ext = await LiveExt.Connect($"ws://127.0.0.1:{_server.Port}");
        _exts.Add(ext);
        return ext;
    }

    private static JsonObject J(string json) => (JsonObject)DartJson.Decode(json)!;

    private static JsonObject Reply(JsonObject req, string? error = null)
    {
        var r = new JsonObject { ["t"] = "reply", ["req"] = req["req"]!.DeepClone() };
        if (error != null) r["error"] = error;
        return r;
    }

    private static Task Until(Func<bool> check) => Wait.Until(check);

    [Fact]
    public async Task A_session_is_known_by_its_kitty_window_with_its_snapshot_and_summary()
    {
        var ext = await Connect();
        ext.Hello(items: [J("""{"id":"u","k":"user","t":"hi"}"""), J("""{"id":"a","k":"assistant","t":"**Done.** All tests pass\nmore"}""")]);
        await Until(() => _hub[Key] != null);
        var s = _hub[Key]!;
        Assert.Equal(["u", "a"], s.Log.Items.Select(i => i.Id));
        Assert.Equal("Done. All tests pass", s.Summary.Preview);
        Assert.Equal("pocketterm", _hub.ProjectName(s));
    }

    [Fact]
    public async Task Two_projects_with_the_same_folder_name_are_told_apart_by_the_folder_above()
    {
        async Task<LiveSession> At(int n, string cwd)
        {
            (await Connect()).Send(new JsonObject
            {
                ["t"] = "hello",
                ["session"] = new JsonObject { ["id"] = $"s{n}", ["cwd"] = cwd },
                ["window"] = $"kitty-1/{n}",
            });
            await Until(() => _hub[$"kitty-1/{n}"] != null);
            return _hub[$"kitty-1/{n}"]!;
        }

        var work = await At(1, "/Users/me/work/api");
        Assert.Equal("api", _hub.ProjectName(work));
        var mine = await At(2, "/Users/me/My Projects/api/");
        var windows = await At(3, @"C:\Users\me\Ünïcode Dev\web");
        var unknown = await At(4, "");
        Assert.Equal("work/api", _hub.ProjectName(work));
        Assert.Equal("My Projects/api", _hub.ProjectName(mine));
        Assert.Equal("web", _hub.ProjectName(windows));
        Assert.Equal("", _hub.ProjectName(unknown));
    }

    [Fact]
    public async Task Frames_the_hub_cannot_read_are_skipped_and_the_session_goes_on()
    {
        var ext = await Connect();
        ext.Send(J("""{"t":"hello","session":{"id":"s1","cwd":"/tmp"},"window":"kitty-1/7","items":[{"k":"user"},"junk",{"id":"a","k":"assistant","t":"kept"}]}"""));
        ext.Send(J("""{"t":"item"}"""));
        ext.Send(J("""{"t":"append","text":"x"}"""));
        ext.Send(J("""{"t":"meta","title":7}"""));
        ext.Send(J("""{"t":"shiny-new-thing","what":true}"""));
        ext.SendRaw("[1, 2]");
        ext.SendRaw("not json");
        ext.Send(J("""{"t":"item","item":{"id":"b","k":"assistant","t":"after"}}"""));
        await Until(() => _hub[Key]?.Log.Items.Count == 2);
        Assert.Equal(["kept", "after"], _hub[Key]!.Log.Items.Select(i => i.Text));
    }

    [Fact]
    public async Task Outside_kitty_the_key_is_the_pid()
    {
        (await Connect()).Hello(window: null);
        await Until(() => _hub["pid:42"] != null);
    }

    [Fact]
    public async Task A_reported_term_names_the_window_tmux_pane_over_leaked_kitty_variables()
    {
        (await Connect()).Send(J("""
            {"t":"hello","v":1,"session":{"id":"s1","cwd":"/Users/me/Dev/pocketterm"},"window":"kitty-23224/116",
             "term":{"TERM_PROGRAM":"tmux","KITTY_WINDOW_ID":"116","KITTY_PID":"23224","TMUX":"/private/tmp/tmux-501/default,4226,0","TMUX_PANE":"%0"},
             "pid":42,"items":[]}
            """));
        await Until(() => _hub["tmux:default/0"] != null);
        Assert.Null(_hub["kitty-23224/116"]);
    }

    [Fact]
    public async Task A_term_that_names_no_window_keys_the_session_by_pid_not_by_the_leaked_kitty_window()
    {
        (await Connect()).Send(J("""
            {"t":"hello","v":1,"session":{"id":"s1","cwd":"/Users/me/Dev/pocketterm"},"window":"kitty-23224/116",
             "term":{"TERM_PROGRAM":"ghostty","KITTY_WINDOW_ID":"116","KITTY_PID":"23224","tty":"/dev/ttys011"},
             "pid":42,"items":[]}
            """));
        await Until(() => _hub["pid:42"] != null);
        Assert.Null(_hub["kitty-23224/116"]);
    }

    [Fact]
    public async Task Windows_sharing_a_folder_a_title_arriving_later_claims_its_window_the_other_the_one_left()
    {
        // As Terminals.LocateAsync does for Ghostty: the window titled after the session, else the one left.
        var listed = new List<(string Key, string Title)> { ("ghostty:A", "π > work"), ("ghostty:B", "π > work") };
        _hub = NewHub((term, cwd, title, agent, claimed) =>
        {
            lock (listed)
            {
                var free = listed.Where(w => !claimed.Contains(w.Key)).ToList();
                var titled = title.Length > 0 ? free.Where(w => w.Title.EndsWith(title, StringComparison.Ordinal)).ToList() : [];
                return Task.FromResult<string?>(titled.Count == 1 ? titled[0].Key : free.Count == 1 ? free[0].Key : null);
            }
        });

        async Task<LiveExt> Omp(int pid, string id = "s1")
        {
            var ext = await Connect();
            ext.Send(J($$"""
                {"t":"hello","v":1,"agent":"omp","session":{"id":"{{id}}","title":"","cwd":"/tmp/work"},
                 "term":{"TERM_PROGRAM":"ghostty","tty":"/dev/ttys0{{pid}}"},"pid":{{pid}},"items":[]}
                """));
            return ext;
        }

        var first = await Omp(41);
        await Omp(42);
        await Until(() => _hub["pid:41"] != null && _hub["pid:42"] != null);
        // Two untitled omps, two windows titled alike: neither is guessed.
        Assert.Equal([null, null], _hub.Sessions.Select(s => s.Window));

        // The first prompt names the session, and omp the window after it.
        lock (listed) listed[0] = ("ghostty:A", "π > Fix missing playable sources");
        first.Send(J("""{"t":"meta","title":"Fix missing playable sources"}"""));
        await Until(() => _hub["pid:41"]?.Window == "ghostty:A" && _hub["pid:42"]?.Window == "ghostty:B");
        // Under the keys the phone knows, each naming its window.
        Assert.Equal(
            new HashSet<(string?, string?)> { ("pid:41", "ghostty:A"), ("pid:42", "ghostty:B") },
            _hub.Sessions.Select(s => s.Summary.ToJson()).Select(j => (j.Str("key"), j.Str("window"))).ToHashSet());

        // /new in the first: the same window, under the same key.
        first.Send(J("""
            {"t":"hello","v":1,"agent":"omp","session":{"id":"s9","title":"","cwd":"/tmp/work"},
             "term":{"TERM_PROGRAM":"ghostty","tty":"/dev/ttys041"},"pid":41,"items":[]}
            """));
        await Until(() => _hub["pid:41"]?.Id == "s9");
        Assert.Equal("ghostty:A", _hub["pid:41"]!.Window);
        Assert.Null(_hub["ghostty:A"]);
    }

    [Fact]
    public async Task Slash_commands_come_with_the_hello_and_change_with_a_meta_ctx_and_cost_reach_the_phone()
    {
        var ext = await Connect();
        ext.Hello(commands: [J("""{"name":"new","description":"Start a new session"}"""), J("""{"name":"review"}""")]);
        await Until(() => _hub[Key] != null);
        var s = _hub[Key]!;
        Assert.Equal([new LiveCommand("new", "Start a new session"), new LiveCommand("review", "")], s.Summary.Commands);
        ext.Send(J("""{"t":"meta","ctx":40,"cost":43.34}"""));
        await Until(() => s.Ctx == 40);
        Assert.Equal(2, s.Commands.Count);
        var phone = LiveSummary.FromJson((JsonObject)DartJson.Decode(DartJson.Encode(s.Summary.ToJson()))!);
        Assert.Equal((40L, 43.34), (phone.Ctx, phone.Cost));
        ext.Send(J("""{"t":"meta","commands":[{"name":"skill:pdf","description":"Read PDFs"}]}"""));
        await Until(() => s.Commands.Count == 1);
        Assert.Equal("skill:pdf", s.Commands.Single().Name);
    }

    [Fact]
    public async Task Items_and_streamed_text_become_ops_in_order()
    {
        var ext = await Connect();
        var ops = new List<LiveOp>();
        _hub.Ops += e =>
        {
            lock (ops) ops.AddRange(e.Ops);
        };
        ext.Hello();
        ext.Send(J("""{"t":"item","item":{"id":"a","k":"assistant","t":""}}"""));
        ext.Send(J("""{"t":"append","id":"a","text":"Hel"}"""));
        ext.Send(J("""{"t":"append","id":"a","text":"lo"}"""));
        ext.Send(J("""{"t":"append","id":"nope","text":"x"}"""));
        await Until(() =>
        {
            lock (ops) return ops.Count == 3;
        });
        var view = new LiveView(_hub[Key]!.Log.Epoch);
        Assert.True(view.Apply(view.Epoch, ops));
        Assert.Equal("Hello", view.Items.Single().Text);
    }

    private List<LiveEvent> Events()
    {
        var events = new List<LiveEvent>();
        _hub.Events += e =>
        {
            lock (events) events.Add(e);
        };
        return events;
    }

    private static int Count<T>(List<T> list)
    {
        lock (list) return list.Count;
    }

    [Fact]
    public async Task A_finished_run_and_a_question_are_events_a_run_that_will_go_on_is_not()
    {
        var ext = await Connect();
        var events = Events();
        ext.Hello();
        ext.Send(J("""{"t":"busy","busy":true}"""));
        ext.Send(J("""{"t":"busy","busy":false}"""));
        ext.Send(J("""{"t":"busy","busy":false,"summary":"All done"}"""));
        ext.Send(J("""{"t":"ask","ask":{"kind":"ask","id":"call1","questions":[{"id":"db","question":"Database?","options":["SQLite","Postgres"]}]}}"""));
        await Until(() => Count(events) == 2);
        Assert.Equal("All done", ((LiveFinished)events[0]).Summary);
        Assert.Equal(["SQLite", "Postgres"], ((LiveAsked)events[1]).Ask.Questions!.Single().Options);
        Assert.Equal("call1", _hub[Key]!.Summary.Ask?.Id);
        ext.Send(J("""{"t":"ask","ask":null}"""));
        await Until(() => _hub[Key]!.Ask == null);
    }

    [Fact]
    public async Task A_plan_review_is_an_event_its_options_read_off_the_screen_update_the_ask_without_another()
    {
        var ext = await Connect();
        var events = Events();
        var changes = 0;
        _hub.Changes += () => Interlocked.Increment(ref changes);
        ext.Hello();
        ext.Send(J("""{"t":"ask","ask":{"kind":"plan","id":"call9","title":"notes-plan"}}"""));
        await Until(() => Count(events) == 1);
        var asked = ((LiveAsked)events.Single()).Ask;
        Assert.True(asked.IsPlan);
        Assert.Equal("Plan ready: notes-plan", asked.Text);
        Assert.Empty(asked.Options);

        var before = Volatile.Read(ref changes);
        var read = LiveAsk.OfPlan("call9", "notes-plan", ["Approve and execute", "Refine plan"], 1);
        Assert.True(_hub.UpdateAsk(Key, "call9", read));
        Assert.Equal(before + 1, Volatile.Read(ref changes));
        Vectors.AssertJson(read.ToJson(), _hub[Key]!.Summary.ToJson()["ask"]);
        // An ask that's no longer there isn't brought back.
        Assert.False(_hub.UpdateAsk(Key, "other", read));
        Assert.True(_hub.UpdateAsk(Key, "call9", null));
        Assert.Null(_hub[Key]!.Ask);
        Assert.False(_hub.UpdateAsk(Key, "call9", read));
        await Task.Delay(20);
        Assert.Single(events);
    }

    [Fact]
    public async Task A_picker_read_off_the_screen_takes_a_free_asks_place_never_the_agents_and_makes_no_push()
    {
        var ext = await Connect();
        var events = Events();
        ext.Hello();
        await Until(() => _hub[Key] != null);
        var menu = LiveAsk.OfMenu("menu-1", "Select theme", [new MenuItem("dark", "")]);
        Assert.True(_hub.UpdateAsk(Key, null, menu));
        Assert.True(_hub[Key]!.Summary.Ask?.IsMenu);
        // Another picker opened from it (/model, then its thinking level) replaces it.
        var next = LiveAsk.OfMenu("menu-2", "Thinking level", [new MenuItem("high", "")]);
        Assert.True(_hub.UpdateAsk(Key, "menu-1", next));
        // omp's own question wins, and a picker doesn't push it aside.
        ext.Send(J("""{"t":"ask","ask":{"kind":"plan","id":"call9","title":"notes-plan"}}"""));
        await Until(() => _hub[Key]!.Ask?.IsPlan ?? false);
        Assert.False(_hub.UpdateAsk(Key, null, menu));
        Assert.False(_hub.UpdateAsk(Key, "menu-2", null));
        Assert.Equal("call9", _hub[Key]!.Ask?.Id);
        lock (events) Assert.Equal(["call9"], events.OfType<LiveAsked>().Select(e => e.Ask.Id));
    }

    [Fact]
    public async Task A_prompt_reaches_the_extension_and_its_reply_completes_it_an_error_reply_fails_it()
    {
        var ext = await Connect();
        ext.Hello();
        await Until(() => _hub[Key] != null);
        var ok = _hub.PromptAsync(Key, "go on", followUp: true);
        var req = await ext.Request();
        Assert.Equal("prompt", req.Str("t"));
        Assert.Equal("go on", req.Str("text"));
        Assert.Equal("followUp", req.Str("deliver"));
        ext.Send(Reply(req));
        await ok;

        var failing = _hub.AbortAsync(Key);
        var abort = await ext.Request();
        ext.Send(Reply(abort, "Nothing to stop."));
        var e = await Assert.ThrowsAsync<LiveException>(() => failing);
        Assert.Equal("Nothing to stop.", e.Message);
    }

    // ------------------------------------------------------------ the queue

    private List<string> Queued() => _hub[Key]!.Summary.Queue.Select(q => q.Text).ToList();

    /// <summary>An omp session at work.</summary>
    private async Task<LiveExt> Working()
    {
        var ext = await Connect();
        ext.Hello();
        ext.Send(J("""{"t":"busy","busy":true}"""));
        await Until(() => _hub[Key]?.Busy ?? false);
        return ext;
    }

    /// <summary>The prompt the hub hands <paramref name="ext"/> next, answered.</summary>
    private static async Task<JsonObject> Handed(LiveExt ext)
    {
        var req = await ext.Request();
        Assert.Equal("prompt", req.Str("t"));
        ext.Send(Reply(req));
        return req;
    }

    [Fact]
    public async Task A_prompt_sent_to_wait_goes_when_the_run_ends_one_per_run_and_the_session_never_looks_done_between()
    {
        var events = Events();
        var ext = await Working();
        var first = await _hub.PromptAsync(Key, "then the docs", followUp: true);
        await _hub.PromptAsync(Key, "then the changelog", followUp: true);
        Assert.NotNull(first);
        Assert.Equal(["then the docs", "then the changelog"], Queued());
        Assert.Equal(first, _hub[Key]!.Summary.Queue[0].Id);

        ext.Send(J("""{"t":"busy","busy":false,"summary":"Fixed."}"""));
        var req = await Handed(ext);
        Assert.Equal("then the docs", req.Str("text"));
        // An agent that started meanwhile keeps it for the run end.
        Assert.Equal("followUp", req.Str("deliver"));
        Assert.True(_hub[Key]!.Busy, "working from the hand-off on");
        Assert.Equal(["then the changelog"], Queued());

        ext.Send(J("""{"t":"busy","busy":true}"""));
        ext.Send(J("""{"t":"busy","busy":false,"summary":"Docs done."}"""));
        Assert.Equal("then the changelog", (await Handed(ext)).Str("text"));
        ext.Send(J("""{"t":"busy","busy":true}"""));
        ext.Send(J("""{"t":"busy","busy":false,"summary":"All done."}"""));
        await Until(() => !_hub[Key]!.Busy);
        Assert.Empty(Queued());
        await Task.Delay(20);
        lock (events) Assert.Equal(["All done."], events.OfType<LiveFinished>().Select(e => e.Summary));
    }

    [Fact]
    public async Task A_steer_and_a_prompt_to_an_agent_at_rest_go_now_Claude_Code_queues_any_prompt_while_it_works()
    {
        var ext = await Working();
        var steer = _hub.PromptAsync(Key, "look at the tests too");
        var req = await Handed(ext);
        Assert.Null(await steer);
        Assert.Equal("steer", req.Str("deliver"));

        var claude = await Connect();
        claude.Send(J("""{"t":"hello","agent":"claude","session":{"id":"c1","cwd":"/tmp"},"window":"kitty-1/8","busy":true}"""));
        await Until(() => _hub["kitty-1/8"]?.Busy ?? false);
        Assert.NotNull(await _hub.PromptAsync("kitty-1/8", "and then this"));
        Assert.Equal("and then this", _hub["kitty-1/8"]!.Summary.Queue.Single().Text);
        await Assert.ThrowsAsync<LiveException>(() => _hub.SendQueuedNowAsync("kitty-1/8", _hub["kitty-1/8"]!.Summary.Queue.Single().Id));
    }

    [Fact]
    public async Task Stop_holds_the_queue_until_Resume_so_does_a_run_stopped_at_the_computer()
    {
        var ext = await Working();
        await _hub.PromptAsync(Key, "next", followUp: true);
        var stopping = _hub.AbortAsync(Key);
        var abort = await ext.Request();
        Assert.Equal("abort", abort.Str("t"));
        ext.Send(Reply(abort));
        ext.Send(J("""{"t":"busy","busy":false,"stopped":true}"""));
        await stopping;
        await Until(() => !_hub[Key]!.Busy);
        Assert.True(_hub[Key]!.Summary.Paused);
        Assert.Equal(["next"], Queued());

        _hub.PauseQueue(Key, paused: false);
        Assert.Equal("next", (await Handed(ext)).Str("text"));

        // Esc at the computer: the extension says the run was stopped.
        ext.Send(J("""{"t":"busy","busy":true}"""));
        await Until(() => _hub[Key]!.Busy && Queued().Count == 0);
        await _hub.PromptAsync(Key, "after that", followUp: true);
        ext.Send(J("""{"t":"busy","busy":false,"stopped":true}"""));
        await Until(() => !_hub[Key]!.Busy);
        Assert.True(_hub[Key]!.Summary.Paused);
        Assert.Equal(["after that"], Queued());
    }

    [Fact]
    public async Task A_run_that_ended_in_an_error_shows_failed_until_the_next_run_starts()
    {
        var ext = await Working();
        ext.Send(J("""{"t":"busy","busy":false,"failed":true}"""));
        await Until(() => !_hub[Key]!.Busy);
        Assert.True(_hub[Key]!.Summary.Failed);
        Assert.True(LiveSummary.FromJson(_hub[Key]!.Summary.ToJson()).Failed, "it reaches the phone");

        ext.Send(J("""{"t":"busy","busy":true}"""));
        await Until(() => _hub[Key]!.Busy);
        Assert.False(_hub[Key]!.Summary.Failed);

        // Stopped is not failed: the phone hears nothing of it.
        ext.Send(J("""{"t":"busy","busy":false,"stopped":true}"""));
        await Until(() => !_hub[Key]!.Busy);
        Assert.False(_hub[Key]!.Summary.Failed);
        Assert.False(_hub[Key]!.Summary.ToJson().ContainsKey("failed"));
    }

    [Fact]
    public async Task Edits_moves_and_removals_change_what_goes_an_emptied_queue_is_no_longer_paused()
    {
        var ext = await Working();
        var a = (await _hub.PromptAsync(Key, "a", followUp: true))!;
        var b = (await _hub.PromptAsync(Key, "b", followUp: true))!;
        var c = (await _hub.PromptAsync(Key, "c", followUp: true))!;
        _hub.EditQueued(Key, b, "b, but better");
        _hub.MoveQueued(Key, c, 0);
        _hub.RemoveQueued(Key, a);
        Assert.Equal(["c", "b, but better"], Queued());
        Assert.Throws<LiveException>(() => _hub.EditQueued(Key, c, "  "));
        Assert.Throws<LiveException>(() => _hub.RemoveQueued(Key, a));

        _hub.PauseQueue(Key, paused: true);
        _hub.RemoveQueued(Key, c);
        _hub.RemoveQueued(Key, b);
        Assert.False(_hub[Key]!.Summary.Paused);

        await _hub.PromptAsync(Key, "d", followUp: true);
        ext.Send(J("""{"t":"busy","busy":false}"""));
        Assert.Equal("d", (await Handed(ext)).Str("text"));
    }

    [Fact]
    public async Task A_prompt_moves_to_any_place_last_included()
    {
        await Working();
        var a = (await _hub.PromptAsync(Key, "a", followUp: true))!;
        await _hub.PromptAsync(Key, "b", followUp: true);
        var c = (await _hub.PromptAsync(Key, "c", followUp: true))!;
        // The phone's "Move to bottom" asks for the last place.
        _hub.MoveQueued(Key, a, 2);
        Assert.Equal(["b", "c", "a"], Queued());
        _hub.MoveQueued(Key, c, 99);
        Assert.Equal(["b", "a", "c"], Queued());
        _hub.MoveQueued(Key, c, -1);
        Assert.Equal(["c", "b", "a"], Queued());
    }

    [Fact]
    public async Task Edits_past_what_the_queue_holds_are_refused()
    {
        await Working();
        var a = (await _hub.PromptAsync(Key, new string('a', LiveHub.MaxQueuedText - 10), followUp: true))!;
        await Assert.ThrowsAsync<LiveException>(() => _hub.PromptAsync(Key, new string('b', 11), followUp: true));
        await _hub.PromptAsync(Key, new string('b', 10), followUp: true);
        var e = Assert.Throws<LiveException>(() => _hub.EditQueued(Key, a, new string('a', LiveHub.MaxQueuedText - 9)));
        Assert.Equal("That is more text than the queue holds: send it when the run ends.", e.Message);
    }

    [Fact]
    public async Task Send_now_steers_the_run_with_it_out_of_the_queue()
    {
        var ext = await Working();
        await _hub.PromptAsync(Key, "first", followUp: true);
        var now = (await _hub.PromptAsync(Key, "right away", followUp: true))!;
        var sending = _hub.SendQueuedNowAsync(Key, now);
        var req = await Handed(ext);
        await sending;
        Assert.Equal("right away", req.Str("text"));
        Assert.Equal("steer", req.Str("deliver"));
        Assert.Equal(["first"], Queued());
    }

    [Fact]
    public async Task One_the_agent_does_not_take_goes_back_first_and_the_queue_pauses()
    {
        var ext = await Working();
        await _hub.PromptAsync(Key, "one", followUp: true);
        await _hub.PromptAsync(Key, "two", followUp: true);
        ext.Send(J("""{"t":"busy","busy":false}"""));
        var req = await ext.Request();
        ext.Send(Reply(req, "No model."));
        await Until(() => !_hub[Key]!.Busy);
        Assert.Equal(["one", "two"], Queued());
        Assert.True(_hub[Key]!.Summary.Paused);
    }

    [Fact]
    public async Task The_same_agent_back_in_the_same_window_keeps_the_queue()
    {
        var ext = await Working();
        await _hub.PromptAsync(Key, "still wanted", followUp: true);
        await ext.CloseAsync();
        await Until(() => _hub[Key] == null);

        var again = await Connect();
        again.Send(J("""{"t":"hello","session":{"id":"s1","cwd":"/tmp"},"window":"kitty-1/7","busy":true}"""));
        await Until(() => _hub[Key] != null);
        Assert.Equal(["still wanted"], Queued());
    }

    [Fact]
    public async Task It_holds_at_most_MaxQueued_prompts()
    {
        await Working();
        for (var i = 0; i < LiveHub.MaxQueued; i++) await _hub.PromptAsync(Key, $"p{i}", followUp: true);
        var e = await Assert.ThrowsAsync<LiveException>(() => _hub.PromptAsync(Key, "one more", followUp: true));
        Assert.Equal("The queue is full: 20 prompts wait already.", e.Message);
        Assert.Equal(LiveHub.MaxQueued, Queued().Count);
    }

    // ------------------------------------------------------------ a prompt with files

    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 1];

    private static readonly PromptFile[] Files =
    [
        new("notes.txt", "text/plain", "the notes"u8.ToArray()),
        new("../my plan.md", "text/markdown", "# plan"u8.ToArray()),
    ];

    /// <summary>The paths <paramref name="text"/> names as @path or @"path".</summary>
    private static List<string> Mentioned(string text) =>
        Regex.Matches(text, "@(?:\"([^\"]+)\"|(\\S+))").Select(m => m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value).ToList();

    private bool Within(string path) => path.StartsWith(_tmp["files"] + Path.DirectorySeparatorChar, StringComparison.Ordinal);

    [Fact]
    public async Task Omp_gets_files_named_in_the_text_as_at_path_saved_on_this_computer_and_the_images_inline()
    {
        var ext = await Connect();
        ext.Hello();
        await Until(() => _hub[Key] != null);
        var done = _hub.PromptAsync(Key, "read these", [(Png, "image/png")], Files);
        var req = await ext.Request();
        ext.Send(Reply(req));
        await done;

        var text = req.Str("text")!;
        Assert.StartsWith("read these\n\n@", text);
        var paths = Mentioned(text);
        Assert.Equal(["notes.txt", "my plan.md"], paths.Select(Path.GetFileName));
        Assert.Contains($"@\"{paths[^1]}\"", text);
        Assert.Equal(["the notes", "# plan"], paths.Select(File.ReadAllText));
        Assert.All(paths, p => Assert.True(Within(p), p));
        Vectors.AssertJson(new JsonObject { ["data"] = Convert.ToBase64String(Png), ["mimeType"] = "image/png" }, req.Arr("images")!.Single());
        Assert.False(req.ContainsKey("docs"));
    }

    [Fact]
    public async Task Claude_Code_gets_files_named_in_the_text_and_their_paths_to_read_without_asking()
    {
        var ext = await Connect();
        ext.Send(J("""{"t":"hello","v":1,"agent":"claude","session":{"id":"c1","title":"","cwd":"/Users/me/Dev/pocketterm"},"window":"kitty-1/7","items":[]}"""));
        await Until(() => _hub[Key]?.Agent == Agent.Claude);
        var done = _hub.PromptAsync(Key, "", [(Png, "image/png")], Files);
        var req = await ext.Request();
        ext.Send(Reply(req));
        await done;

        var docs = req.Arr("docs")!.Select(d => DartJson.AsString(d)!).ToList();
        // Nothing but the mentions, with no words.
        Assert.Equal(docs, Mentioned(req.Str("text")!));
        Assert.Equal(["notes.txt", "my plan.md"], docs.Select(Path.GetFileName));
        Assert.Empty(req.Arr("images")!);
        Assert.Equal(Png, File.ReadAllBytes(DartJson.AsString(req.Arr("files")!.Single())!));
        Assert.Equal("followUp", req.Str("deliver"));
    }

    [Fact]
    public async Task Images_and_files_older_than_a_day_go_when_PocketTerm_starts_newer_ones_stay()
    {
        var images = Directory.CreateDirectory(_tmp["start-images"]).FullName;
        var files = Directory.CreateDirectory(_tmp["start-files"]).FullName;
        var oldImage = Path.Combine(images, "old.png");
        File.WriteAllBytes(oldImage, Png);
        File.SetLastWriteTimeUtc(oldImage, DateTime.UtcNow.AddDays(-2));
        var newImage = Path.Combine(images, "new.png");
        File.WriteAllBytes(newImage, Png);
        var oldFolder = Directory.CreateDirectory(Path.Combine(files, "old")).FullName;
        File.WriteAllText(Path.Combine(oldFolder, "notes.txt"), "the notes");
        Directory.SetLastWriteTimeUtc(oldFolder, new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        _ = new LiveHub(files: new PromptFiles(files), images: images);
        await Until(() => !Directory.Exists(oldFolder));
        Assert.False(File.Exists(oldImage));
        Assert.True(File.Exists(newImage));
    }

    // ------------------------------------------------------------ transcripts

    [Fact]
    public async Task Older_items_arrive_as_ops_above_the_oldest()
    {
        var ext = await Connect();
        var ops = new List<LiveOp>();
        _hub.Ops += e =>
        {
            lock (ops) ops.AddRange(e.Ops);
        };
        ext.Send(J("""{"t":"hello","session":{"id":"s"},"window":"kitty-1/7","items":[{"id":"c","k":"user","t":"c"}],"older":true}"""));
        await Until(() => _hub[Key] != null);
        var done = _hub.OlderAsync(Key);
        var req = await ext.Request();
        Assert.Equal(150, req.Int("limit"));
        var reply = Reply(req);
        reply["items"] = new JsonArray(J("""{"id":"a","k":"user","t":"a"}"""), J("""{"id":"b","k":"user","t":"b"}"""));
        reply["older"] = false;
        ext.Send(reply);
        await done;
        Assert.Equal(["a", "b", "c"], _hub[Key]!.Log.Items.Select(i => i.Id));
        Assert.False(_hub[Key]!.Log.Older);
        Assert.Equal(2, Count(ops));
    }

    [Fact]
    public async Task New_in_the_same_omp_starts_a_new_transcript_under_the_same_key()
    {
        var ext = await Connect();
        ext.Hello(items: [J("""{"id":"x","k":"user","t":"old"}""")]);
        await Until(() => _hub[Key] != null);
        var epoch = _hub[Key]!.Log.Epoch;
        ext.Hello(id: "s2");
        await Until(() => _hub[Key]!.Id == "s2");
        Assert.NotEqual(epoch, _hub[Key]!.Log.Epoch);
        Assert.Empty(_hub[Key]!.Log.Items);
    }

    [Fact]
    public async Task A_new_omp_in_the_same_window_replaces_the_old_one_its_end_removes_it_and_fails_what_waits()
    {
        var first = await Connect();
        first.Hello();
        await Until(() => _hub[Key] != null);
        var pending = _hub.PromptAsync(Key, "x");
        await first.Request();
        var second = await Connect();
        second.Hello(id: "s9");
        await Until(() => _hub[Key]?.Id == "s9");
        var e = await Assert.ThrowsAsync<LiveException>(() => pending);
        Assert.Equal("The omp session ended.", e.Message);
        await second.CloseAsync();
        await Until(() => _hub[Key] == null);
        Assert.Empty(_hub.Sessions);
    }

    // ------------------------------------------------------------ the orchestrator

    private string OrchestratorDir()
    {
        var dir = Directory.CreateDirectory(_tmp["orch/orchestrator"]).FullName;
        _hub.OrchestratorDir = dir;
        return dir;
    }

    private async Task<LiveExt> At(string window, string cwd, string title = "Fix bug", bool busy = false, JsonArray? items = null)
    {
        var ext = await Connect();
        ext.Send(new JsonObject
        {
            ["t"] = "hello",
            ["session"] = new JsonObject { ["id"] = window, ["title"] = title, ["cwd"] = cwd },
            ["window"] = window,
            ["busy"] = busy,
            ["items"] = items ?? [],
        });
        await Until(() => _hub[window] != null);
        return ext;
    }

    private int _calls;

    private async Task<JsonObject> Call(LiveExt ext, JsonObject m)
    {
        var id = ++_calls;
        var call = new JsonObject { ["t"] = "call", ["id"] = id };
        foreach (var (k, v) in m) call[k] = v?.DeepClone();
        ext.Send(call);
        var r = await ext.Request();
        Assert.Equal("result", r.Str("t"));
        Assert.Equal(id, r.Int("id"));
        return r;
    }

    [Fact]
    public async Task A_session_in_its_folder_is_the_orchestrator_through_a_symlink_too_one_elsewhere_is_not()
    {
        var dir = OrchestratorDir();
        await At("kitty-1/1", dir);
        await At("kitty-1/3", "/Users/me/Dev/api");
        Assert.True(_hub["kitty-1/1"]!.Summary.Orchestrator);
        Assert.False(_hub["kitty-1/3"]!.Summary.Orchestrator);
        Assert.True(LiveSummary.FromJson(_hub["kitty-1/1"]!.Summary.ToJson()).Orchestrator);
        // Symlinks need a privilege on Windows.
        if (!OperatingSystem.IsWindows())
        {
            var link = Directory.CreateSymbolicLink(_tmp["via"], dir).FullName;
            await At("kitty-1/2", link);
            Assert.True(_hub["kitty-1/2"]!.Summary.Orchestrator);
        }
    }

    [Fact]
    public async Task Sessions_lists_every_session_but_the_orchestrator()
    {
        var orch = await At("kitty-1/1", OrchestratorDir());
        Assert.Equal("No other coding sessions are running on this computer.", (await Call(orch, new JsonObject { ["op"] = "sessions" })).Str("text"));
        await At("kitty-1/2", "/Users/me/Dev/api", title: "Add login");
        var text = (await Call(orch, new JsonObject { ["op"] = "sessions" })).Str("text")!;
        Assert.StartsWith("1 coding session on this computer:", text);
        Assert.Contains("kitty-1/2 | api | \"Add login\" | omp | idle", text);
        Assert.DoesNotContain("kitty-1/1", text);
    }

    [Fact]
    public async Task Only_the_orchestrator_may_call()
    {
        OrchestratorDir();
        var other = await At("kitty-1/2", "/Users/me/Dev/api");
        var r = await Call(other, new JsonObject { ["op"] = "sessions" });
        Assert.Equal("Only the PocketTerm orchestrator can do that.", r.Str("error"));
        Assert.False(r.ContainsKey("text"));
    }

    [Fact]
    public async Task Prompt_steers_an_idle_session_queues_for_a_busy_one_and_never_the_orchestrator_or_a_command()
    {
        var orch = await At("kitty-1/1", OrchestratorDir());
        var idle = await At("kitty-1/2", "/Users/me/Dev/api", title: "Add login");
        orch.Send(J("""{"t":"call","id":1,"op":"prompt","session":"kitty-1/2","text":"run the tests","deliver":"steer"}"""));
        var req = await idle.Request();
        Assert.Equal("prompt", req.Str("t"));
        Assert.Equal("run the tests", req.Str("text"));
        Assert.Equal("steer", req.Str("deliver"));
        idle.Send(Reply(req));
        var sent = await orch.Request();
        Assert.StartsWith("Sent to api \"Add login\" (kitty-1/2)", sent.Str("text"));

        await At("kitty-1/3", "/Users/me/Dev/web", busy: true);
        var queued = await Call(orch, new JsonObject { ["op"] = "prompt", ["session"] = "kitty-1/3", ["text"] = "then the docs" });
        Assert.StartsWith("Queued in", queued.Str("text"));
        Assert.Equal("then the docs", _hub["kitty-1/3"]!.Summary.Queue.Single().Text);

        var self = await Call(orch, new JsonObject { ["op"] = "prompt", ["session"] = "kitty-1/1", ["text"] = "hi" });
        Assert.Equal("That is the orchestrator itself.", self.Str("error"));
        var slash = await Call(orch, new JsonObject { ["op"] = "prompt", ["session"] = "kitty-1/2", ["text"] = "/model" });
        Assert.Equal("Slash commands can't be sent from the orchestrator.", slash.Str("error"));
    }

    [Fact]
    public async Task Stop_stops_a_session_and_says_what_waits_in_its_queue()
    {
        var orch = await At("kitty-1/1", OrchestratorDir());
        var busy = await At("kitty-1/2", "/Users/me/Dev/api", title: "Add login", busy: true);
        await _hub.PromptAsync("kitty-1/2", "then the docs", followUp: true);
        orch.Send(J("""{"t":"call","id":"c7","op":"stop","session":"kitty-1/2"}"""));
        var abort = await busy.Request();
        Assert.Equal("abort", abort.Str("t"));
        busy.Send(Reply(abort));
        var r = await orch.Request();
        Assert.Equal("c7", r.Str("id"));
        Assert.Equal("Stopped api \"Add login\" (kitty-1/2). Its 1 queued prompt waits until the person resumes them.", r.Str("text"));
        Assert.True(_hub["kitty-1/2"]!.Paused);
    }

    [Fact]
    public async Task Read_gives_the_newest_items_oldest_first_each_clipped()
    {
        var orch = await At("kitty-1/1", OrchestratorDir());
        await At("kitty-1/2", "/Users/me/Dev/api", items:
        [
            J("""{"id":"a","k":"user","t":"first question"}"""),
            J("""{"id":"b","k":"assistant","t":"first answer"}"""),
            J("""{"id":"c","k":"user","t":"second question"}"""),
            new JsonObject { ["id"] = "d", ["k"] = "assistant", ["t"] = new string('x', 10000) },
        ]);
        var text = (await Call(orch, new JsonObject { ["op"] = "read", ["session"] = "kitty-1/2", ["last"] = 2 })).Str("text")!;
        Assert.Contains("(earlier items left out)", text);
        Assert.DoesNotContain("first", text);
        Assert.True(text.IndexOf("[user] second question", StringComparison.Ordinal) < text.IndexOf("[assistant] ", StringComparison.Ordinal));
        Assert.Contains(new string('x', 6000) + "…", text);
        Assert.DoesNotContain(new string('x', 6001), text);
    }
}
