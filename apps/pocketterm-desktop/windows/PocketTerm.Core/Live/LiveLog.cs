using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace PocketTerm.Core;

/// <summary>
/// The Mac's copy of one session's transcript. Every change gets the next <see cref="Seq"/>; a phone that has seen
/// up to some seq catches up with <see cref="Since"/>. <see cref="Epoch"/> changes when the transcript starts over
/// (another session in that omp, the extension reconnected), and a phone then drops what it has.
/// An item too big for one message is cut (<see cref="Live.MaxItemTextBytes"/>): its text keeps its start, a tool's
/// output its end.
/// </summary>
public sealed class LiveLog
{
    private readonly Dictionary<string, LiveItem> _items = new();

    /// <summary>Each item's text size as JSON (<see cref="Live.JsonBytes"/>), kept up as text streams in.</summary>
    private readonly Dictionary<string, int> _textBytes = new();
    private long _next;
    private long _min;

    public LiveLog(IEnumerable<LiveItem> snapshot, bool older, int cap = 3000, string? epoch = null)
    {
        Older = older;
        Cap = cap;
        Epoch = epoch ?? NewEpoch();
        foreach (var i in snapshot) Add(i);
        Trim();
    }

    public string Epoch { get; }

    /// <summary>The most items kept; the oldest go first (and <see cref="Older"/> turns true).</summary>
    public int Cap { get; }
    public long Seq { get; set; }

    /// <summary>The extension has items older than the oldest here.</summary>
    public bool Older { get; set; }

    /// <summary>Oldest first.</summary>
    public List<LiveItem> Items => _items.Values.OrderBy(i => i.Order).ToList();

    internal static string NewEpoch()
    {
        Span<char> c = stackalloc char[8];
        for (var i = 0; i < 8; i++) c[i] = "0123456789abcdefghijklmnopqrstuvwxyz"[RandomNumberGenerator.GetInt32(36)];
        return new string(c);
    }

    /// <summary>A copy of <paramref name="item"/> cut to what fits in a message.</summary>
    private LiveItem Fit(LiveItem item)
    {
        var copy = item.Copy();
        copy.Text = Live.ClipText(item.Text, Live.MaxItemTextBytes);
        copy.Title = Live.ClipText(item.Title, Live.MaxTitleBytes);
        copy.Args = Live.ClipText(item.Args, Live.MaxArgsBytes);
        if (Live.JsonBytes(copy.Output) > Live.MaxOutputBytes) copy.Output = "…" + Live.TailBytes(copy.Output, Live.MaxOutputBytes - 3);
        _textBytes[copy.Id] = Live.JsonBytes(copy.Text);
        return copy;
    }

    private LiveItem Add(LiveItem item)
    {
        _items.TryGetValue(item.Id, out var old);
        var copy = Fit(item);
        copy.Order = old?.Order ?? _next++;
        copy.Seq = ++Seq;
        return _items[item.Id] = copy;
    }

    /// <summary><paramref name="item"/>, new or changed. The op carries a snapshot: later appends go in ops of their own.</summary>
    public LiveOp Upsert(LiveItem item)
    {
        var copy = Add(item);
        Trim();
        return LiveOp.OfItem(copy.Seq, copy.Copy());
    }

    /// <summary>Streamed <paramref name="text"/> added to <paramref name="id"/>; null if there's no such item, or its
    /// text was already cut. Text past <see cref="Live.MaxItemTextBytes"/> is cut.</summary>
    public LiveOp? Append(string id, string text)
    {
        _items.TryGetValue(id, out var item);
        var had = _textBytes.GetValueOrDefault(id);
        if (item == null || text.Length == 0 || item.Text.EndsWith(Live.CutNote, StringComparison.Ordinal)) return null;
        var add = text;
        var bytes = Live.JsonBytes(text);
        if (had + bytes > Live.MaxItemTextBytes)
        {
            add = Live.HeadBytes(text, Math.Max(0, Live.MaxItemTextBytes - had - Live.JsonBytes(Live.CutNote))) + Live.CutNote;
            bytes = Live.JsonBytes(add);
        }
        _textBytes[id] = had + bytes;
        item.Text += add;
        item.Seq = ++Seq;
        return LiveOp.OfAppend(Seq, id, add);
    }

    /// <summary>Items from before the oldest one here (oldest first), placed above it.
    /// The ops come in seq order, newest item first.</summary>
    public List<LiveOp> AddOlder(IReadOnlyList<LiveItem> items, bool more)
    {
        Older = more;
        var ops = new List<LiveOp>();
        for (var k = items.Count - 1; k >= 0; k--)
        {
            var item = items[k];
            if (_items.ContainsKey(item.Id)) continue;
            var copy = Fit(item);
            copy.Order = --_min;
            copy.Seq = ++Seq;
            _items[copy.Id] = copy;
            ops.Add(LiveOp.OfItem(Seq, copy.Copy()));
        }
        return ops;
    }

    /// <summary>Items changed after <paramref name="since"/>, oldest first.</summary>
    public List<LiveItem> Since(long since) => Items.Where(i => i.Seq > since).ToList();

    private void Trim()
    {
        if (_items.Count <= Cap) return;
        foreach (var i in Items.Take(_items.Count - Cap))
        {
            _items.Remove(i.Id);
            _textBytes.Remove(i.Id);
        }
        _min = Items[0].Order;
        Older = true;
    }
}

/// <summary>
/// The phone's copy of one session's transcript, kept up with <see cref="LiveLog"/>'s ops and catch-ups, and cached
/// on disk between launches. Like <see cref="LiveLog"/>, it keeps at most <see cref="Cap"/> items: the oldest go as
/// newer ones come (and <see cref="Older"/> turns true, the Mac may still have them).
/// </summary>
public sealed class LiveView
{
    private readonly Dictionary<string, LiveItem> _byId = new();
    private List<LiveItem>? _sorted;

    /// <summary>The newest item's order: one past it grows the transcript, one before it is an earlier message
    /// paged in (kept, though past <see cref="Cap"/>).</summary>
    private long? _newest;

    public LiveView(string epoch, long seq = 0, bool older = false, int cap = 3000, IEnumerable<LiveItem>? items = null)
    {
        Epoch = epoch;
        Seq = seq;
        Older = older;
        Cap = cap;
        foreach (var i in items ?? []) Put(i);
        Trim();
    }

    public static LiveView FromJson(JsonObject j) => new(
        LiveJson.ReqStr(j, "epoch"),
        LiveJson.ReqInt(j, "seq"),
        LiveJson.IsTrue(j["older"]),
        items: ((j["items"] as JsonArray) ?? throw new InvalidCastException("'items' is not a List"))
            .Select(i => LiveItem.FromJson(i as JsonObject ?? throw new InvalidCastException("item is not a Map"))).ToList());

    public string Epoch { get; set; }
    public long Seq { get; set; }
    public bool Older { get; set; }
    public int Cap { get; }

    /// <summary>Oldest first.</summary>
    public List<LiveItem> Items => _sorted ??= _byId.Values.OrderBy(i => i.Order).ToList();

    private void Put(LiveItem i)
    {
        _byId[i.Id] = i;
        if (_newest is { } n && n >= i.Order) return;
        _newest = i.Order;
    }

    /// <summary>Past <see cref="Cap"/>: the oldest go.</summary>
    private void Trim()
    {
        if (_byId.Count <= Cap) return;
        var all = Items;
        foreach (var i in all.Take(all.Count - Cap)) _byId.Remove(i.Id);
        _sorted = null;
        Older = true;
    }

    /// <summary>Applies live ops; false if one is missing or the epoch moved on (catch up with a sync then).
    /// Ops already seen are skipped.</summary>
    public bool Apply(string epoch, IEnumerable<LiveOp> ops)
    {
        if (epoch != Epoch) return false;
        var grew = false;
        foreach (var op in ops)
        {
            if (op.Seq <= Seq) continue;
            if (op.Seq != Seq + 1) return false;
            if (op.Item is { } item)
            {
                _byId.TryGetValue(item.Id, out var old);
                if (old == null && (_newest == null || item.Order > _newest)) grew = true;
                Put(item);
                // The sorted list holds the old object: swap it in place, or sort again.
                var at = old == null || old.Order != item.Order ? -1 : _sorted?.IndexOf(old) ?? -1;
                if (at >= 0) _sorted![at] = item;
                else _sorted = null;
            }
            else
            {
                if (!_byId.TryGetValue(op.Id!, out var target)) return false;
                target.Text += op.Append!;
            }
            Seq = op.Seq;
        }
        if (grew) Trim();
        return true;
    }

    /// <summary>A catch-up from the Mac: <paramref name="items"/> changed up to <paramref name="seq"/>
    /// (<paramref name="reset"/>: all of them, in a new <paramref name="epoch"/>). <paramref name="last"/> is the
    /// final chunk of the answer.</summary>
    public void CatchUp(string epoch, long seq, bool reset, IEnumerable<LiveItem> items, bool last, bool? older = null)
    {
        if (reset && Epoch != epoch)
        {
            Epoch = epoch;
            Seq = 0;
            _byId.Clear();
            _newest = null;
        }
        else if (epoch != Epoch)
        {
            return;
        }
        foreach (var i in items) Put(i);
        _sorted = null;
        if (older is { } o) Older = o;
        Trim();
        if (last && seq > Seq) Seq = seq;
    }

    /// <summary>The newest <paramref name="keep"/> items, for the disk cache. Dropping older ones makes
    /// <see cref="Older"/> true: the Mac has them.</summary>
    public JsonObject ToJson(int keep = 600)
    {
        var all = Items;
        var kept = all.Count > keep ? all.GetRange(all.Count - keep, keep) : all;
        return new JsonObject
        {
            ["epoch"] = Epoch,
            ["seq"] = Seq,
            ["older"] = Older || kept.Count < all.Count,
            ["items"] = new JsonArray(kept.Select(i => (JsonNode?)i.ToJson()).ToArray()),
        };
    }
}
