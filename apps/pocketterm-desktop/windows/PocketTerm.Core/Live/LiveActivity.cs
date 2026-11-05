using System.Text.Json.Nodes;

namespace PocketTerm.Core;

// Coding sessions followed on the phone (Live Activities, Android ongoing notifications): the computer tells the
// server (POST /v1/push/activity) what a session's activity shows. A push carries only what's below, never text.

/// <summary>What a followed session's activity shows.</summary>
public enum ActivityState
{
    Working,
    Needs,
    Done,
    Ended,
}

/// <summary>What the agent waits for, when it needs you.</summary>
public enum ActivityKind
{
    Question,
    Approval,
    Plan,
}

/// <summary>An activity's state, and what it waits for when it needs you.</summary>
public readonly record struct ActivityStatus(ActivityState State, ActivityKind? Kind);

/// <summary>The pure parts of Dart live_activity.dart.</summary>
public static class LiveActivity
{
    /// <summary>What a session's activity shows: its agent asks something, works, or has stopped (done). A picker the
    /// person opened from the phone isn't the agent asking.</summary>
    public static ActivityStatus Status(bool busy, LiveAsk? ask = null) => ask?.Kind switch
    {
        AskKind.Questions => new(ActivityState.Needs, ActivityKind.Question),
        AskKind.Approval => new(ActivityState.Needs, ActivityKind.Approval),
        AskKind.Plan => new(ActivityState.Needs, ActivityKind.Plan),
        _ => new(busy ? ActivityState.Working : ActivityState.Done, null),
    };

    /// <summary>The same for a session in the Mac's state; null: it's gone (ended).</summary>
    public static ActivityStatus SummaryStatus(LiveSummary? s) =>
        s == null ? new(ActivityState.Ended, null) : Status(s.Busy, s.Ask);

    /// <summary>The <c>state</c> and <c>kind</c> of a push or a channel call.</summary>
    public static JsonObject ToJson(ActivityStatus s)
    {
        var o = new JsonObject { ["state"] = s.State.Name() };
        if (s.Kind is { } k) o["kind"] = k.Name();
        return o;
    }
}
