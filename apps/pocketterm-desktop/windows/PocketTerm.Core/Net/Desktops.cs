using System.Text.Json.Nodes;

namespace PocketTerm.Core;

/// <summary>A computer running PocketTerm on this server (GET /v1/desktops): it refreshes <see cref="SeenAt"/>
/// every minute while its terminal bridge runs, and the phone talks to it on its own topic, its id.</summary>
/// <param name="Id">8 characters, a-z and 0-9.</param>
/// <param name="Platform"><c>macos</c> or <c>windows</c>.</param>
public sealed record Desktop(string Id, string Name, string Platform, DateTimeOffset SeenAt)
{
    /// <summary>How recently a computer has to have said it's there to count as <see cref="Online"/>.</summary>
    public static readonly TimeSpan OnlineWithin = TimeSpan.FromSeconds(150);

    public static Desktop FromJson(JsonObject j) => new(
        j.Str("id") ?? throw new InvalidCastException("A computer has an id."),
        j.Str("name") ?? throw new InvalidCastException("A computer has a name."),
        j.Str("platform") ?? throw new InvalidCastException("A computer has a platform."),
        DartDate.Parse(j.Str("seen_at") ?? throw new InvalidCastException("A computer has seen_at.")));

    public bool Windows => Platform == "windows";

    /// <summary>It has said so within two and a half of its one-minute beats.</summary>
    public bool Online => DateTimeOffset.UtcNow - SeenAt < OnlineWithin;

    public JsonObject ToJson() => new()
    {
        ["id"] = Id,
        ["name"] = Name,
        ["platform"] = Platform,
        ["seen_at"] = DartDate.ToIso8601Utc(SeenAt),
    };
}

/// <summary>Phone: the server's computers, newest seen first, and the one the Terminal tab shows
/// (<see cref="Selected"/>).</summary>
public sealed class Desktops : ObservableObject, IDisposable
{
    /// <summary>Computers seen this long ago or longer aren't listed.</summary>
    public static readonly TimeSpan KeepFor = TimeSpan.FromDays(30);

    private readonly IServer _server;
    private string? _selectedId;
    private string? _wanted;
    private bool _disposed;

    /// <param name="cached">The list as last seen, from before this launch (shown until the server says otherwise).</param>
    /// <param name="saved">The computer last shown, from before this launch.</param>
    /// <param name="onChanged">Keeps the list and the selection for the next launch.</param>
    public Desktops(IServer server, IReadOnlyList<Desktop>? cached = null, string? saved = null, Action<IReadOnlyList<Desktop>, string?>? onChanged = null)
    {
        _server = server;
        All = cached ?? [];
        _selectedId = saved;
        OnChanged = onChanged;
    }

    /// <summary>The list or the selection changed.</summary>
    public Action<IReadOnlyList<Desktop>, string?>? OnChanged { get; }

    public IReadOnlyList<Desktop> All { get; private set; }

    /// <summary>The server has answered since launch.</summary>
    public bool Loaded { get; private set; }

    public Desktop? Selected => All.FirstOrDefault(d => d.Id == _selectedId);

    /// <summary>Why the last <see cref="Refresh"/> got no list (the server can't be reached, say); null once one came.</summary>
    public string? Error { get; private set; }

    /// <summary>Fetches the list; on failure the last one stays, and <see cref="Error"/> says why. One that comes
    /// back after <see cref="Dispose"/> (signed out meanwhile) is dropped: it would keep the old server's computers
    /// for the next sign-in.</summary>
    public async Task Refresh()
    {
        try
        {
            var rows = await _server.Desktops().ConfigureAwait(false);
            Log.Timing("computers listed");
            if (!_disposed) Apply(rows);
        }
        catch (Exception e)
        {
            Log.Timing("computers failed");
            Log.Print($"PocketTerm: computers: {e.Message}");
            var why = e.Message;
            if (_disposed || why == Error) return;
            Error = why;
            NotifyChanged();
        }
    }

    public void Dispose() => _disposed = true;

    /// <summary>The rows from the server, newest seen first.</summary>
    internal void Apply(IEnumerable<JsonObject> rows)
    {
        var now = DateTimeOffset.UtcNow;
        All = rows.Select(Desktop.FromJson).Where(d => now - d.SeenAt < KeepFor).ToList();
        Loaded = true;
        Error = null;
        Pick();
        OnChanged?.Invoke(All, _selectedId);
        NotifyChanged();
    }

    /// <summary>The person shows <paramref name="id"/>'s sessions.</summary>
    public void Select(string id)
    {
        if (id == _selectedId || All.All(d => d.Id != id)) return;
        _selectedId = id;
        OnChanged?.Invoke(All, _selectedId);
        NotifyChanged();
    }

    /// <summary>The person just scanned <paramref name="id"/>'s code: it's shown now if listed, else as soon as
    /// <see cref="Apply"/> lists it, whichever computer was seen last.</summary>
    public void Show(string id)
    {
        if (All.Any(d => d.Id == id))
        {
            _wanted = null;
            Select(id);
        }
        else
        {
            _wanted = id;
        }
    }

    /// <summary>The one asked for by <see cref="Show"/> once listed; else the one shown stays while listed; else
    /// the newest seen (kept from then on, so it doesn't flip as computers take turns being newest); else none.</summary>
    private void Pick()
    {
        if (_wanted is { } w && All.Any(d => d.Id == w))
        {
            _selectedId = w;
            _wanted = null;
        }
        if (Selected == null) _selectedId = All.FirstOrDefault()?.Id;
    }
}
