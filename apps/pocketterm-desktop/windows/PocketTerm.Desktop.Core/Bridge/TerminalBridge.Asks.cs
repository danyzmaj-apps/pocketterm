using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

// Asks on the screen: following plan reviews, Claude Code's approvals and pickers, answering them with keys, and the
// orchestrator.
public sealed partial class TerminalBridge
{
    private static List<LiveAnswer> Answers(JsonObject p) =>
        (p.Arr("answers") ?? []).Select(a => LiveAnswer.FromJson((JsonObject)a!)).ToList();

    /// <summary>Follows on its screen an ask whose end the agent's extension can't see: a plan review (dismissed with
    /// Esc at the computer), or Claude Code's approval (its plugin hears only once the tool has run). A plan's options
    /// are published once it has rendered, and again when its cursor moves. An ask gone from the screen twice running
    /// goes from the hub too.</summary>
    private async Task FollowAskAsync(string key, string id)
    {
        lock (_gate)
        {
            if (!_followed.Add(id)) return;
        }
        try
        {
            var misses = 0;
            for (var n = 0; !_stopped; n++)
            {
                var opening = n < AskOpening;
                await Task.Delay(opening ? AskSoon : AskEvery).ConfigureAwait(false);
                var s = _hub[key];
                var ask = s?.Ask;
                var window = s?.Window;
                if (s == null || ask == null || ask.Id != id || window == null || !_terms.Can(window, TermCap.Read)) return;
                string screen;
                try
                {
                    screen = await _terms.PlainScreenAsync(window).ConfigureAwait(false);
                }
                catch (TerminalException e)
                {
                    Log.Print($"PocketTerm: ask on screen {window}: {e.Message}");
                    if (opening) continue;
                    return;
                }
                var review = ask.IsPlan ? Live.ParsePlanReview(screen, s.Agent) : null;
                if (review != null)
                {
                    misses = 0;
                    if (!review.Options.SequenceEqual(ask.Options) || review.Current != ask.Selected)
                    {
                        _hub.UpdateAsk(key, id, LiveAsk.OfPlan(id, title: ask.Title, options: review.Options, selected: review.Current));
                    }
                }
                else if (Live.AskOnScreen(ask, screen, s.Agent))
                {
                    misses = 0;
                }
                else if (!opening && ++misses >= 2)
                {
                    _hub.UpdateAsk(key, id, null);
                    return;
                }
            }
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: ask on screen: {Describe(e)}");
        }
        finally
        {
            lock (_gate) _followed.Remove(id);
        }
    }

    /// <summary>Picks the plan review option the request names, once the screen still lists it there. Claude Code's
    /// rows go by their number. omp's cursor moves from where it is now (someone may have moved it at the computer)
    /// down or up to it, and Enter goes once the screen shows the cursor there: ↓/↑ skip an option omp has disabled,
    /// which plain text doesn't show, and a cursor that won't land on the option means omp won't take it.</summary>
    private async Task AnswerPlanAsync(string window, LiveAsk ask, Agent agent, JsonObject p)
    {
        var answers = Answers(p);
        var pick = answers.Count == 1 && answers[0].Picks.Count == 1 ? answers[0].Picks[0] : -1;
        if (pick < 0) throw new LiveException("Pick one option.");
        for (var tries = 0; tries < 4; tries++)
        {
            var review = Live.ParsePlanReview(await _terms.PlainScreenAsync(window).ConfigureAwait(false), agent)
                ?? throw new LiveException(
                    "The plan review isn't ready on the computer's screen. Open the screen to answer it there.");
            if (pick >= review.Options.Count || (pick < ask.Options.Count && review.Options[(int)pick] != ask.Options[(int)pick]))
            {
                throw new LiveException("The plan review on the computer has changed. Open the screen to answer it there.");
            }
            if (agent == Agent.Claude)
            {
                await _terms.PressKeysAsync(window, [Live.ClaudeRowKey(pick)]).ConfigureAwait(false);
                return;
            }
            if (review.Current == pick)
            {
                await _terms.PressKeysAsync(window, ["enter"]).ConfigureAwait(false);
                return;
            }
            await _terms.PressKeysAsync(window, Live.MenuKeys(review.Current, (int)pick, enter: false)).ConfigureAwait(false);
            await Task.Delay(200).ConfigureAwait(false);
        }
        throw new LiveException("omp won't move to that option. Open the screen to answer it there.");
    }

    /// <summary>Follows session <paramref name="key"/>'s screen for the pickers a slash command opens (/resume, /model,
    /// /tree …) and publishes each as a menu ask: its rows, cursor and search as they change, a new ask for each new
    /// picker (one can open another), none once it has gone two reads running. Read often for a while after the
    /// command or an answer, then less; it stops when no picker is up after that while, or nothing changed for
    /// <see cref="MenuIdle"/>. The agent's own asks come first: a picker never replaces one. Again for a session
    /// already followed just reads sooner.</summary>
    private async Task FollowMenusAsync(string key)
    {
        MenuWatch? known;
        var w = new MenuWatch();
        lock (_gate)
        {
            if (!_menus.TryGetValue(key, out known)) _menus[key] = w;
        }
        if (known != null)
        {
            known.Arm();
            return;
        }
        string? published = null;
        try
        {
            var misses = 0;
            while (!_stopped)
            {
                var now = DateTime.UtcNow;
                if (now - w.Changed > MenuIdle) break;
                var opening = now - w.Armed < MenuOpening;
                if (published == null && !opening) break;
                await w.SleepAsync(opening ? MenuSoon : MenuEvery).ConfigureAwait(false);
                var s = _hub[key];
                var window = s?.Window;
                if (s == null || window == null || _stopped || !_terms.Can(window, TermCap.Read)) break;
                var current = s.Ask;
                // The agent asks something itself, or the picker's ask went (a new session's hello).
                if (current != null && current.Id != published) break;
                if (current == null && published != null) published = null;
                string screen;
                try
                {
                    screen = await _terms.PlainScreenAsync(window).ConfigureAwait(false);
                }
                catch (TerminalException e)
                {
                    Log.Print($"PocketTerm: picker {window}: {e.Message}");
                    break;
                }
                now = DateTime.UtcNow;
                var menu = Live.ParseMenu(screen);
                if (menu == null)
                {
                    if (published != null && ++misses >= 2)
                    {
                        _hub.UpdateAsk(key, published, null);
                        published = null;
                        w.Query = "";
                    }
                    continue;
                }
                misses = 0;
                var same = current != null && current.Title == menu.Title;
                string id;
                if (same)
                {
                    id = current!.Id;
                }
                else
                {
                    lock (_gate) id = $"menu-{++_menuIds}";
                }
                var ask = LiveAsk.OfMenu(id, title: menu.Title, items: menu.Items, selected: menu.Current, filter: menu.Filter);
                if (same && DartJson.Encode(ask.ToJson()) == DartJson.Encode(current!.ToJson())) continue;
                if (!_hub.UpdateAsk(key, published, ask)) break;
                if (!same) w.Query = "";
                published = ask.Id;
                w.Changed = now;
            }
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: picker: {Describe(e)}");
        }
        finally
        {
            lock (_gate)
            {
                if (_menus.TryGetValue(key, out var mine) && ReferenceEquals(mine, w)) _menus.Remove(key);
            }
            if (published != null) _hub.UpdateAsk(key, published, null);
        }
    }

    /// <summary>Answers a picker: a pick moves its cursor from where it is now to the row (once that row still reads
    /// the same) and presses Enter; typed text becomes its search, by typing what's new and erasing only what was
    /// typed from the phone before (Backspace on an empty search can mean something else: /resume deletes the
    /// session). The picker is then read again soon, as is whatever it opens next.</summary>
    private async Task AnswerMenuAsync(string key, string window, LiveAsk ask, JsonObject p)
    {
        var answers = Answers(p);
        var answer = answers.Count == 1 ? answers[0] : null;
        MenuWatch? w;
        lock (_gate) _menus.TryGetValue(key, out w);
        var menu = Live.ParseMenu(await _terms.PlainScreenAsync(window).ConfigureAwait(false));
        if (w == null || menu == null || menu.Title != ask.Title)
        {
            throw new LiveException("The menu isn't on the computer's screen anymore. Open the screen to see what is.");
        }
        var query = answer?.Custom;
        if (query != null && answer!.Picks.Count == 0)
        {
            if (!menu.Filter) throw new LiveException("This menu can't be searched.");
            var typed = w.Query;
            var same = 0;
            while (same < query.Length && same < typed.Length && query[same] == typed[same]) same++;
            await _terms.PressKeysAsync(window, Enumerable.Repeat("backspace", typed.Length - same).ToList()).ConfigureAwait(false);
            if (same < query.Length) await _terms.TypeAsync(window, query[same..]).ConfigureAwait(false);
            w.Query = query;
            w.Arm();
            return;
        }
        var pick = answer != null && answer.Picks.Count == 1 ? answer.Picks[0] : -1;
        if (pick < 0 || pick >= ask.Items.Count) throw new LiveException("Pick one item.");
        var shown = menu;
        for (var tries = 0; tries < 4; tries++)
        {
            if (pick >= shown.Items.Count || shown.Items[(int)pick].Label != ask.Items[(int)pick].Label)
            {
                throw new LiveException("The menu on the computer has changed. Pick again.");
            }
            if (shown.Current == pick)
            {
                await _terms.PressKeysAsync(window, ["enter"]).ConfigureAwait(false);
                w.Query = "";
                w.Arm();
                return;
            }
            await _terms.PressKeysAsync(window, Live.MenuKeys(shown.Current, (int)pick, enter: false)).ConfigureAwait(false);
            await Task.Delay(150).ConfigureAwait(false);
            var again = Live.ParseMenu(await _terms.PlainScreenAsync(window).ConfigureAwait(false));
            if (again == null || again.Title != ask.Title)
            {
                throw new LiveException("The menu isn't on the computer's screen anymore. Open the screen to see what is.");
            }
            shown = again;
        }
        throw new LiveException("The agent won't move to that item. Open the screen to pick it there.");
    }

    /// <summary>The phone's <c>orchestrator</c> op: the orchestrator's window key, starting it (omp in
    /// <see cref="LiveHub.OrchestratorDir"/>) unless one runs or is starting. Always omp, whatever new sessions
    /// start: only its extension has the orchestrator's tools.</summary>
    private async Task<string> OrchestratorAsync()
    {
        var running = _hub.Sessions.FirstOrDefault(s => s.Orchestrator);
        if (running != null) return running.Key;
        Task<string> start;
        bool mine;
        lock (_gate)
        {
            mine = _orchestratorStart == null;
            start = _orchestratorStart ??= StartOrchestratorAsync();
        }
        if (!mine) return await start.ConfigureAwait(false);
        try
        {
            return await start.ConfigureAwait(false);
        }
        finally
        {
            lock (_gate) _orchestratorStart = null;
        }
    }

    private async Task<string> StartOrchestratorAsync()
    {
        // Off the caller's stack: the lock that stored this task must be released before it runs.
        await Task.Yield();
        var dir = _hub.OrchestratorDir ?? throw new LiveException("PocketTerm's local API isn't running.");
        // omp already in its folder that hasn't said hello yet (slow to start): that one, not a second.
        var early = (await _terms.WindowsAsync().ConfigureAwait(false))
            .FirstOrDefault(w => w.Agent == Agent.Omp && Orchestrator.IsOrchestratorDir(w.Cwd, dir));
        if (early != null) return early.Key;
        AgentIntegration? omp;
        lock (_gate) omp = _agentsNow != null && _agentsNow.TryGetValue(Agent.Omp, out var i) ? i : null;
        switch (omp)
        {
            case AgentIntegration.Missing:
                throw new LiveException("Install PocketTerm in omp first: Settings → Coding agents on this computer.");
            case AgentIntegration.Outdated:
                throw new LiveException("Update PocketTerm in omp first: Settings → Coding agents on this computer.");
        }
        await Orchestrator.PrepareOrchestratorDirAsync(dir).ConfigureAwait(false);
        var opened = await _terms.LaunchAsync(
            dir,
            await _terms.OpensInAsync(_app()).ConfigureAwait(false),
            agent: Agent.Omp,
            placement: _placement(),
            flags: $"--append-system-prompt {Orchestrator.OrchestratorPromptFile}").ConfigureAwait(false);
        return opened.Window;
    }

    /// <summary>Answers the agent's question, approval, plan review or a picker with keystrokes in its terminal window,
    /// once its screen shows that it is up: only where the terminal can both show its screen and press keys.</summary>
    private async Task AnswerAsync(JsonObject p)
    {
        var s = _hub[Req(p, "session")];
        var ask = s?.Ask;
        if (s == null || ask == null || ask.Id != p.Str("ask")) throw new LiveException("That is no longer being asked.");
        var window = s.Window ?? throw new LiveException(
            "PocketTerm can't tell which terminal window this session runs in: answer it on the computer.");
        if (BridgeHelpers.CantAnswer(_terms, window) is { } why) throw new LiveException(why);
        if (ask.IsPlan)
        {
            await AnswerPlanAsync(window, ask, s.Agent, p).ConfigureAwait(false);
            return;
        }
        if (ask.IsMenu)
        {
            await AnswerMenuAsync(s.Key, window, ask, p).ConfigureAwait(false);
            return;
        }
        var steps = Live.AnswerKeys(ask, Answers(p), approve: p.Bool("approve") == true, agent: s.Agent);
        if (!Live.AskOnScreen(ask, await _terms.PlainScreenAsync(window).ConfigureAwait(false), s.Agent))
        {
            throw new LiveException("The question isn't on the computer's screen. Open the screen to answer it there.");
        }
        foreach (var step in steps)
        {
            switch (step)
            {
                case Keys k:
                    await _terms.PressKeysAsync(window, k.KeyNames).ConfigureAwait(false);
                    break;
                case Typed t:
                    await _terms.TypeAsync(window, t.Text).ConfigureAwait(false);
                    break;
                case Settle:
                    await Task.Delay(450).ConfigureAwait(false);
                    break;
            }
        }
        await AnsweredAsync(s, window, ask).ConfigureAwait(false);
    }

    /// <summary>Waits for the agent to take the answer: its extension drops the ask (omp's when the tool ends, Claude
    /// Code's once the tool has run), or the dialog leaves the screen, which comes first for an approved long command;
    /// the ask goes then. omp's dialog still waiting on its Submit tab gets one more Enter: keys that came while it
    /// redrew were dropped.</summary>
    private async Task AnsweredAsync(LiveSession s, string window, LiveAsk ask)
    {
        bool Pending() => _hub[s.Key]?.Ask?.Id == ask.Id;
        var nudged = false;
        var gone = 0;
        for (var i = 0; i < 16 && Pending(); i++)
        {
            await Task.Delay(250).ConfigureAwait(false);
            if (i < 2 || !Pending()) continue;
            var screen = await _terms.PlainScreenAsync(window).ConfigureAwait(false);
            if (!Live.AskOnScreen(ask, screen, s.Agent))
            {
                if (++gone < 2) continue;
                _hub.UpdateAsk(s.Key, ask.Id, null);
                return;
            }
            gone = 0;
            if (i >= 7 && !nudged && s.Agent == Agent.Omp && SubmitTab().IsMatch(screen))
            {
                nudged = true;
                await _terms.PressKeysAsync(window, ["enter"]).ConfigureAwait(false);
            }
        }
        if (Pending())
        {
            throw new LiveException($"{s.Agent.Label()} hasn't taken the answer yet. Open the screen to check what it's waiting for.");
        }
    }

    /// <summary>omp's ask dialog on its last tab, the answers listed above Submit.</summary>
    [GeneratedRegex(@"Review answers[\s\S]*❯\s*Submit")]
    private static partial Regex SubmitTab();
}
