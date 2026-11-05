using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PocketTerm.Core;

// Terminal from the phone, version 2: coding sessions travel as transcript items (LiveItem, LiveLog → LiveView),
// terminal windows as screens (ScreenDiff). The frames and their fields are described in
// packages/pocketterm_server/PROTOCOL.md and at the top of the Dart live.dart this ports; every payload goes
// sealed with the computer's channel key.

/// <summary>The live protocol's helpers (Dart live.dart's top-level functions and constants).</summary>
public static partial class Live
{
    private const string W = LiveJson.Ws;

    // Dart's `.`: anything but a line terminator.
    private const string Dot = @"[^\r\n\u2028\u2029]";

    /// <summary>A session <paramref name="key"/> as pushes and links carry it: with the computer it's on,
    /// so a tap on the phone opens it there.</summary>
    public static string RoutedKey(string desktopId, string key) => $"{desktopId}/{key}";

    /// <summary>The computer and the session of a <see cref="RoutedKey"/>; null if <paramref name="s"/> isn't one.</summary>
    public static (string Desktop, string Key)? SplitRoutedKey(string s)
    {
        if (s.Length < 10 || s[8] != '/') return null;
        var desktop = s[..8];
        if (!DesktopId().IsMatch(desktop)) return null;
        return (desktop, s[9..]);
    }

    [GeneratedRegex(@"^[a-z0-9]{8}\z")]
    private static partial Regex DesktopId();

    // ------------------------------------------------------------ sizes

    /// <summary>The character of <paramref name="s"/> starting at code unit <paramref name="i"/>: how many bytes it
    /// takes inside a JSON string, UTF-8 encoded (quotes, backslashes and control characters escaped as jsonEncode
    /// does), and how many code units it is.</summary>
    private static (int Bytes, int Units) JsonChar(string s, int i)
    {
        int c = s[i];
        if (c == 0x22 || c == 0x5c) return (2, 1);
        if (c < 0x20) return (c is 0x08 or 0x09 or 0x0a or 0x0c or 0x0d ? 2 : 6, 1);
        if (c < 0x80) return (1, 1);
        if (c < 0x800) return (2, 1);
        if ((c & 0xfc00) == 0xd800 && i + 1 < s.Length && (s[i + 1] & 0xfc00) == 0xdc00) return (4, 2);
        // A lone surrogate is escaped.
        if ((c & 0xf800) == 0xd800) return (6, 1);
        return (3, 1);
    }

    /// <summary>How many bytes <paramref name="s"/> takes inside a JSON string, UTF-8 encoded.</summary>
    public static int JsonBytes(string s)
    {
        var n = 0;
        for (var i = 0; i < s.Length;)
        {
            var (bytes, units) = JsonChar(s, i);
            n += bytes;
            i += units;
        }
        return n;
    }

    /// <summary>The start of <paramref name="s"/> that takes at most <paramref name="max"/> bytes as JSON, never
    /// splitting a character.</summary>
    internal static string HeadBytes(string s, int max)
    {
        var n = 0;
        for (var i = 0; i < s.Length;)
        {
            var (bytes, units) = JsonChar(s, i);
            n += bytes;
            if (n > max) return s[..i];
            i += units;
        }
        return s;
    }

    /// <summary>The end of <paramref name="s"/> that takes at most <paramref name="max"/> bytes as JSON, never
    /// splitting a character.</summary>
    internal static string TailBytes(string s, int max)
    {
        var n = 0;
        for (var end = s.Length; end > 0;)
        {
            var pair = end >= 2 && (s[end - 1] & 0xfc00) == 0xdc00 && (s[end - 2] & 0xfc00) == 0xd800;
            var start = pair ? end - 2 : end - 1;
            n += JsonChar(s, start).Bytes;
            if (n > max) return s[end..];
            end = start;
        }
        return s;
    }

    /// <summary>How an item's text that was too long for the phone ends.</summary>
    public const string CutNote = "\n\n… (too long to show here: the rest is on the computer)";

    /// <summary>The most JSON bytes an item's text takes on the way to the phone, with <see cref="CutNote"/>; its
    /// tool output, arguments and title take less. An item then always fits in one message: the server closes a
    /// socket on a frame over 256 KiB, and sealing grows a message by a third.</summary>
    public const int MaxItemTextBytes = 64 * 1024;
    internal const int MaxOutputBytes = 16 * 1024;
    internal const int MaxArgsBytes = 4 * 1024;
    internal const int MaxTitleBytes = 1024;

    /// <summary><paramref name="s"/> cut to its first <paramref name="max"/> bytes, ending with <see cref="CutNote"/>.</summary>
    internal static string ClipText(string s, int max) =>
        JsonBytes(s) <= max ? s : HeadBytes(s, max - JsonBytes(CutNote)) + CutNote;

    /// <summary><paramref name="items"/> split into lists whose JSON stays under <paramref name="maxBytes"/> each:
    /// sealed and in base64 a message grows by a third, and the server closes a socket on a frame over 256 KB.</summary>
    public static List<List<JsonObject>> ChunkJson(IEnumerable<JsonObject> items, int maxBytes = 40000)
    {
        var output = new List<List<JsonObject>>();
        var current = new List<JsonObject>();
        var size = 0;
        foreach (var i in items)
        {
            var n = Encoding.UTF8.GetByteCount(DartJson.Encode(i)) + 1;
            if (current.Count > 0 && size + n > maxBytes)
            {
                output.Add(current);
                current = [];
                size = 0;
            }
            current.Add(i);
            size += n;
        }
        if (current.Count > 0 || output.Count == 0) output.Add(current);
        return output;
    }

    // ------------------------------------------------------------ answering dialogs

    /// <summary>The keystrokes that answer <paramref name="ask"/> in <paramref name="agent"/>'s terminal UI (a question
    /// or an approval). A plan review or a picker is answered from where its cursor is now: <see cref="MenuKeys"/>, or
    /// <see cref="ClaudeRowKey"/> for Claude Code's plan review.</summary>
    /// <exception cref="ArgumentException">A plan or picker, or answers that don't fit the questions.</exception>
    public static List<KeyStep> AnswerKeys(LiveAsk ask, IReadOnlyList<LiveAnswer>? answers = null, bool approve = false, Agent agent = Agent.Omp)
    {
        answers ??= [];
        if (ask.IsPlan || ask.IsMenu) throw new ArgumentException("A plan review or a picker is answered with menuKeys.");
        if (ask.Questions is { } questions)
        {
            if (answers.Count != questions.Count) throw new ArgumentException("One answer per question.");
            for (var i = 0; i < questions.Count; i++)
            {
                var q = questions[i];
                var a = answers[i];
                foreach (var p in a.Picks)
                {
                    if (p < 0 || p >= q.Options.Count) throw new ArgumentException($"No option {p} in \"{q.Question}\".");
                }
                if (!q.Multi && a.Picks.Count + (CustomOf(a) == null ? 0 : 1) != 1)
                    throw new ArgumentException($"Pick one answer for \"{q.Question}\".");
            }
        }
        return agent switch
        {
            Agent.Claude => ClaudeKeys(ask, answers, approve),
            _ => OmpKeys(ask, answers, approve),
        };
    }

    private static string? CustomOf(LiveAnswer a)
    {
        var custom = a.Custom?.DartTrim();
        return string.IsNullOrEmpty(custom) ? null : custom;
    }

    /// <summary>Steps that run consecutive key presses together, as one keys request.</summary>
    private sealed class Steps
    {
        public readonly List<KeyStep> List = [];

        public Steps Press(IEnumerable<string> keys)
        {
            if (List.Count > 0 && List[^1] is Keys last) last.KeyNames.AddRange(keys);
            else List.Add(new Keys([.. keys]));
            return this;
        }

        public Steps Add(KeyStep step)
        {
            List.Add(step);
            return this;
        }

        public Steps DoSettle()
        {
            if (List.Count == 0 || List[^1] is not Settle) List.Add(new Settle());
            return this;
        }
    }

    private static IEnumerable<string> Repeat(string key, long n)
    {
        for (var k = 0L; k < n; k++) yield return key;
    }

    /// <summary>omp: the ask dialog lists each question's options and then "Other"; its cursor stops at the ends, so
    /// going up past the top and then down picks a row wherever the cursor started. Enter on a single-choice row
    /// answers and moves on, Space toggles a multiple-choice row and Enter moves on; after several questions a
    /// Submit tab takes a last Enter. A typed answer goes through an editor; its Enter closes it, and the next keys
    /// wait for that (<see cref="Settle"/>). An approval is omp's Approve/Deny menu, which opens on Approve.</summary>
    private static List<KeyStep> OmpKeys(LiveAsk ask, IReadOnlyList<LiveAnswer> answers, bool approve)
    {
        if (ask.IsApproval) return [new Keys(approve ? ["enter"] : ["down", "enter"])];
        var questions = ask.Questions!;
        var s = new Steps();
        var onSubmitTab = false;
        for (var i = 0; i < questions.Count; i++)
        {
            var q = questions[i];
            var a = answers[i];
            var rows = q.Options.Count + 1;
            IEnumerable<string> RowKeys(long row) => Repeat("up", rows).Concat(Repeat("down", row));
            var custom = CustomOf(a);
            if (q.Multi)
            {
                foreach (var p in a.Picks) s.Press([.. RowKeys(p), "space"]);
            }
            if (custom != null)
            {
                s.Press([.. RowKeys(q.Options.Count), "enter"]).Add(new Settle()).Add(new Typed(custom)).Press(["enter"]).Add(new Settle());
                // A lone multiple-choice question goes to its Submit tab after a typed answer.
                if (q.Multi && questions.Count == 1) onSubmitTab = true;
            }
            else if (q.Multi)
            {
                s.Press(["enter"]);
            }
            else
            {
                s.Press([.. RowKeys(a.Picks.Single()), "enter"]);
            }
        }
        if (questions.Count > 1 || onSubmitTab) s.DoSettle().Press(["enter"]);
        return s.List;
    }

    /// <summary>Claude Code numbers the rows of its dialogs from 1: a row's digit picks it (or toggles it, in a
    /// multiple-choice question) wherever the cursor is.</summary>
    public static string ClaudeRowKey(long row) => $"{row + 1}";

    /// <summary>Claude Code: a question lists its options, then "Type something", then (multiple choice) a Submit row.
    /// A single-choice row's digit answers and moves on; the typed row's digit opens it for typing, and Enter answers.
    /// Multiple choice: digits toggle rows without moving the cursor from the first, ↓ takes it to the typed row
    /// (whose text ticks it) and on to Submit, where Enter moves on. Several questions, or a multiple-choice one, end
    /// on a review tab whose first row submits. An approval opens on Yes; Esc refuses.</summary>
    private static List<KeyStep> ClaudeKeys(LiveAsk ask, IReadOnlyList<LiveAnswer> answers, bool approve)
    {
        if (ask.IsApproval) return [new Keys([approve ? ClaudeRowKey(0) : "esc"])];
        var questions = ask.Questions!;
        var s = new Steps();
        for (var i = 0; i < questions.Count; i++)
        {
            var q = questions[i];
            var a = answers[i];
            var n = q.Options.Count;
            var custom = CustomOf(a);
            if (i > 0) s.DoSettle();
            if (!q.Multi)
            {
                if (custom == null)
                {
                    s.Press([ClaudeRowKey(a.Picks.Single())]);
                    continue;
                }
                s.Press([ClaudeRowKey(n)]).Add(new Settle()).Add(new Typed(custom)).Add(new Settle()).Press(["enter"]);
                continue;
            }
            foreach (var p in a.Picks) s.Press([ClaudeRowKey(p)]);
            if (custom == null)
            {
                s.Press([.. Repeat("down", n + 1), "enter"]);
                continue;
            }
            s.Press([ClaudeRowKey(n), .. Repeat("down", n)]).Add(new Settle()).Add(new Typed(custom)).Add(new Settle()).Press(["down", "enter"]);
        }
        if (questions.Count > 1 || questions.Single().Multi) s.DoSettle().Press([ClaudeRowKey(0)]);
        return s.List;
    }

    /// <summary>How to tell <paramref name="ask"/> is <paramref name="agent"/>'s dialog on the screen: some of its
    /// words in the screen's text, compared without spacing or Markdown marks (the terminal wraps and styles them).</summary>
    public static bool AskOnScreen(LiveAsk ask, string screen, Agent agent = Agent.Omp)
    {
        static string Flat(string s) => FlatMarks().Replace(s, "").ToLowerInvariant();
        var text = Flat(screen);
        if (ask.IsPlan)
            return (agent == Agent.Omp && text.Contains("planmode-nextstep", StringComparison.Ordinal)) || ParsePlanReview(screen, agent) != null;
        if (ask.IsMenu) return ParseMenu(screen)?.Title == ask.Title;
        if (ask.IsApproval)
        {
            return agent switch
            {
                // "Do you want to proceed?" (or "… to create notes.txt?") over "❯ 1. Yes".
                Agent.Claude => text.Contains("doyouwant", StringComparison.Ordinal) && text.Contains("❯1.yes", StringComparison.Ordinal),
                _ => text.Contains("approve", StringComparison.Ordinal) && text.Contains("deny", StringComparison.Ordinal),
            };
        }
        var q = Flat(ask.Questions!.First().Question);
        return text.Contains(q.Length > 24 ? q[..24] : q, StringComparison.Ordinal);
    }

    [GeneratedRegex($@"[{W}*_`#>]+")]
    private static partial Regex FlatMarks();

    // ------------------------------------------------------------ plan review

    /// <summary><paramref name="agent"/>'s plan review (the last step of plan mode), read off the plain text of its
    /// screen: its options and the one its cursor (❯) is on. Null unless a review is up with its options focused.</summary>
    public static PlanReview? ParsePlanReview(string screen, Agent agent = Agent.Omp) =>
        agent == Agent.Claude ? ClaudePlanReview(screen) : OmpPlanReview(screen);

    [GeneratedRegex(@"Would you like to proceed\?|Exit plan mode\?")]
    private static partial Regex ClaudePlanHeader();

    [GeneratedRegex($@"^[{W}]*(❯[{W}]*)?([0-9]+)\.[{W}]+([^{W}]{Dot}*?)[{W}]*\z")]
    private static partial Regex ClaudeRow();

    /// <summary>Claude Code's plan review: the numbered rows under its last "Would you like to proceed?" ("Exit plan
    /// mode?" when no plan was written). Lines between them (a row's hint) are skipped; a number out of turn ends them.</summary>
    private static PlanReview? ClaudePlanReview(string screen)
    {
        var lines = screen.Split('\n');
        var header = Array.FindLastIndex(lines, l => ClaudePlanHeader().IsMatch(l));
        if (header < 0) return null;
        var options = new List<string>();
        var current = -1;
        foreach (var l in lines.Skip(header + 1))
        {
            var m = ClaudeRow().Match(l);
            if (!m.Success) continue;
            if (!long.TryParse(m.Groups[2].Value, out var number) || number != options.Count + 1) break;
            if (m.Groups[1].Success) current = options.Count;
            options.Add(m.Groups[3].Value);
        }
        if (current < 0) return null;
        return new PlanReview(options, current);
    }

    [GeneratedRegex($@"plan mode[{W}]*[-–—][{W}]*next step", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PlanHeader();

    // Dart's \b is ASCII.
    [GeneratedRegex(@"(?<![A-Za-z0-9_])select(?![A-Za-z0-9_])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PlanHelp();

    [GeneratedRegex($@"^[{W}]*[│┃║|]")]
    private static partial Regex LeftEdge();

    [GeneratedRegex($@"[{W}]*[│┃║|][{W}]*\z")]
    private static partial Regex RightEdge();

    [GeneratedRegex($@"^([{W}]*)[❯›>][{W}]+(?=[^{W}])")]
    private static partial Regex Cursor();

    [GeneratedRegex(@"^[─━═┄┈╌\-+├┤┼┬┴╭╮╰╯]+\z")]
    private static partial Regex Rule();

    [GeneratedRegex($@"[{W}]+")]
    private static partial Regex Spaces();

    [GeneratedRegex($@"[{W}]")]
    private static partial Regex AnySpace();

    private static int Indent(string s) => s.Length - s.DartTrimLeft().Length;

    private static int FindIndex(IReadOnlyList<string> list, Func<string, bool> test, int start = 0)
    {
        for (var i = start; i < list.Count; i++)
        {
            if (test(list[i])) return i;
        }
        return -1;
    }

    /// <summary>omp's plan review, read off the plain text of its screen: the options listed between its "Plan mode -
    /// next step" header and the help line under them ("↑/↓ select · ⏎ confirm · …"), and the one its cursor (❯) is
    /// on. The model slider above them ("continue with ◂ smol default slow ▸" and its "↳ model" line) is skipped, and
    /// a row the terminal wrapped is joined again. Null unless a review is up with its options focused, the only time
    /// ↑/↓ move between them.</summary>
    private static PlanReview? OmpPlanReview(string screen)
    {
        var lines = screen.Split('\n');
        var header = Array.FindLastIndex(lines, l => PlanHeader().IsMatch(l));
        if (header < 0) return null;
        var help = FindIndex(lines, l => PlanHelp().IsMatch(l), header + 1);
        if (help < 0) return null;
        // Inside the review's box every row starts with its edge; a row too wide
        // for the terminal goes on, without one, on the next line.
        var boxed = LeftEdge().IsMatch(lines[header]);
        var rows = lines[(header + 1)..help]
            .Select(l => (Edge: LeftEdge().IsMatch(l), Text: RightEdge().Replace(LeftEdge().Replace(l, "", 1), "", 1)))
            .ToList();
        var at = rows.FindIndex(r => Cursor().IsMatch(r.Text));
        if (at < 0) return null;
        // Where the labels start: past the cursor on its row, past the indent on the others.
        var cm = Cursor().Match(rows[at].Text);
        var column = cm.Index + cm.Length;

        var options = new List<string>();
        var current = -1;
        var afterOption = false;
        for (var i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var t = r.Text.DartTrim();
            if (t.Length == 0 || Rule().IsMatch(t))
            {
                afterOption = false;
                continue;
            }
            if (boxed ? !r.Edge : i != at && Indent(r.Text) != column)
            {
                if (afterOption) options[^1] += boxed ? r.Text : $" {r.Text}";
                continue;
            }
            afterOption = false;
            if (t.StartsWith('↳') || t.Contains("continue with", StringComparison.Ordinal) || t.Contains('◂') || t.Contains('▸')) continue;
            if (i == at)
            {
                current = options.Count;
                options.Add(r.Text[column..]);
            }
            else if (Indent(r.Text) == column)
            {
                options.Add(r.Text[column..]);
            }
            else
            {
                continue;
            }
            afterOption = true;
        }
        if (current < 0) return null;
        return new PlanReview(options.Select(o => Spaces().Replace(o, " ").DartTrim()).ToList(), current);
    }

    /// <summary>The keys that move a menu's cursor (a picker's, the plan review's) from row <paramref name="current"/>
    /// to <paramref name="target"/>, then (with <paramref name="enter"/>) pick it. Never above row 0: the plan review's
    /// ↑ there leaves its options for the plan's text.</summary>
    /// <exception cref="ArgumentException">A negative row.</exception>
    public static List<string> MenuKeys(int current, int target, bool enter = true)
    {
        if (current < 0 || target < 0) throw new ArgumentException($"No row {target}.");
        var keys = new List<string>();
        for (var k = current; k < target; k++) keys.Add("down");
        for (var k = target; k < current; k++) keys.Add("up");
        if (enter) keys.Add("enter");
        return keys;
    }

    // ------------------------------------------------------------ pickers

    [GeneratedRegex($@"^[{W}]*❯ ")]
    private static partial Regex MenuCursor();

    /// <summary>Claude Code's prompt line: ❯ and a no-break space. It shows only while no picker is up; the
    /// <c>❯ </c> rows above it are prompts in its transcript.</summary>
    [GeneratedRegex($"^[{W}]*❯\u00a0")]
    private static partial Regex ClaudePrompt();

    [GeneratedRegex($@"^[{W}]*[│┃║]")]
    private static partial Regex MenuLeft();

    [GeneratedRegex($@"([{W}]*[│┃║█])+[{W}]*\z")]
    private static partial Regex MenuRight();

    [GeneratedRegex($@"^[{W}─━═╭╮┌┐╔╗├┤╰╯└┘]+|[{W}─━═╭╮┌┐╔╗├┤╰╯└┘]+\z")]
    private static partial Regex MenuChrome();

    [GeneratedRegex($@"^(\([0-9]+/[0-9]+[^)]*\)[{W}]*)?(type to search|search:|no match|no items|no sessions)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex MenuStatus();

    [GeneratedRegex($@"[{W}]{{2,}}")]
    private static partial Regex MenuGap();

    /// <summary>A numbered row's number (Claude Code's pickers: <c>1.  Default</c>), whose gap is part of the label,
    /// not the one before its detail.</summary>
    [GeneratedRegex($@"^([0-9]+\.)[{W}]+")]
    private static partial Regex MenuNumber();

    /// <summary>A vertical rule inside a row: another pane beside the list.</summary>
    [GeneratedRegex("[│┃║]")]
    private static partial Regex PaneSplit();

    /// <summary>
    /// A picker the agent's terminal UI shows (/resume, /model, /tree, a hook's selector …), read off the plain text
    /// of its screen: the rows around the last cursor (❯) at the cursor's label column, a <c>title</c> above them (its
    /// box's top border, or a line of its own) and whether typing filters them (a <c>&gt;</c> search line above, or
    /// "Type to search" under them). Rows apart by blank lines are one item each (first line its label, the rest its
    /// detail); otherwise every line is one, with what's indented deeper or set apart by a wide gap as its detail. Box
    /// edges, scrollbars, padding and lone "…" lines are left out; a footer of keys ends the rows. Null for anything
    /// else: the plan review, or Claude Code's prompt under a transcript whose prompts read <c>❯ …</c> too.
    /// </summary>
    public static ParsedMenu? ParseMenu(string screen)
    {
        if (PlanHeader().IsMatch(screen)) return null;
        var lines = screen.Split('\n').Select(l => MenuRight().Replace(MenuLeft().Replace(l, "", 1), "", 1)).ToArray();
        var at = Array.FindLastIndex(lines, l => MenuCursor().IsMatch(l));
        if (at < 0 || lines.Skip(at + 1).Any(l => ClaudePrompt().IsMatch(l))) return null;
        var cm = MenuCursor().Match(lines[at]);
        var column = cm.Index + cm.Length;
        var filter = false;

        bool InList(int i)
        {
            var t = lines[i].DartTrim();
            if (t.Length == 0 || i == at) return true;
            if (MenuStatus().IsMatch(t))
            {
                filter |= t.ToLowerInvariant().Contains("search", StringComparison.Ordinal);
                return false;
            }
            return Indent(lines[i]) >= column;
        }

        var top = at;
        while (top > 0 && InList(top - 1)) top--;
        var bottom = at;
        while (bottom + 1 < lines.Length && InList(bottom + 1)) bottom++;
        var rows = new List<(int I, string Text)>();
        for (var i = top; i <= bottom; i++)
        {
            if (lines[i].DartTrim() != "…") rows.Add((i, lines[i]));
        }
        bool IsItem((int I, string Text) r) => r.I == at || (r.Text.DartTrim().Length > 0 && Indent(r.Text) == column);
        var first = rows.FindIndex(r => IsItem(r));
        var last = rows.FindLastIndex(r => IsItem(r));
        var blocks = rows.GetRange(first, last + 1 - first).Any(r => r.Text.DartTrim().Length == 0);

        var items = new List<List<string>>();
        var current = -1;
        var gap = true;
        foreach (var r in rows)
        {
            var t = r.Text.DartTrim();
            if (t.Length == 0)
            {
                gap = true;
                continue;
            }
            if (IsItem(r) && (!blocks || gap || items.Count == 0))
            {
                var row = MenuNumber().Replace(r.Text[column..].DartTrim(), m => $"{m.Groups[1].Value} ", 1);
                var split = MenuGap().Match(row);
                items.Add(split.Success ? [row[..split.Index], row[(split.Index + split.Length)..]] : [row]);
            }
            else if (items.Count > 0)
            {
                items[^1].Add(t);
            }
            else
            {
                continue;
            }
            if (r.I == at) current = items.Count - 1;
            gap = false;
        }
        if (current < 0) return null;
        // Panes side by side (/model's providers | models): a list of the left pane
        // alone would mislead, so leave it to the screen.
        if (rows.Any(r => PaneSplit().IsMatch(r.Text[Math.Min(column, r.Text.Length)..]))) return null;

        // The title: the first line above the rows that isn't blank or the search line.
        var title = "";
        for (var i = top - 1; i >= 0; i--)
        {
            var t = lines[i].DartTrim();
            if (t.Length == 0) continue;
            if (t.StartsWith('>'))
            {
                filter = true;
                continue;
            }
            title = MenuChrome().Replace(t, "");
            break;
        }
        static string Flat(string s) => Spaces().Replace(s, " ").DartTrim();
        return new ParsedMenu(
            Flat(title),
            items.Select(it => new MenuItem(Flat(it[0]), string.Join(" · ", it.Skip(1).Select(Flat)))).ToList(),
            current,
            filter);
    }

    // ------------------------------------------------------------ slash commands

    /// <summary>The extension's <c>commands</c> (<c>[{name, description?}]</c>).</summary>
    public static List<LiveCommand> LiveCommands(JsonNode? json)
    {
        var list = new List<LiveCommand>();
        if (json is not JsonArray a) return list;
        foreach (var c in a)
        {
            if (c is JsonObject m && DartJson.AsString(m["name"]) is { } name)
                list.Add(new LiveCommand(name, DartJson.AsString(m["description"]) ?? ""));
        }
        return list;
    }

    /// <summary>The <paramref name="commands"/> the composer offers for <paramref name="text"/> (<c>/</c> and the
    /// start of a name), at most <paramref name="max"/>: names that start with what was typed, then names that
    /// contain it, each in omp's order. None once there's a space.</summary>
    public static List<LiveCommand> MatchCommands(IReadOnlyList<LiveCommand> commands, string text, int max = 6)
    {
        if (!text.StartsWith('/') || AnySpace().IsMatch(text)) return [];
        var q = text[1..].ToLowerInvariant();
        var names = commands.Select(c => c.Name.ToLowerInvariant()).ToList();
        var starts = commands.Where((_, i) => names[i].StartsWith(q, StringComparison.Ordinal));
        var contains = commands.Where((_, i) => !names[i].StartsWith(q, StringComparison.Ordinal) && names[i].Contains(q, StringComparison.Ordinal));
        return starts.Concat(contains).Take(max).ToList();
    }
}
