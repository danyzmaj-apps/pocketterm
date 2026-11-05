using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Core.Tests;

/// <summary>The logic parts of packages/pocketterm_core/test/live_activity_test.dart, and agent_test.dart.</summary>
public class LiveActivityTests
{
    private static LiveSummary Summary(bool busy = false, LiveAsk? ask = null) =>
        new() { Key = "kitty-1/2", Id = "s", Title = "Fix it", Cwd = "/x/pocketterm", Busy = busy, Ask = ask, Epoch = "e", Seq = 0 };

    [Fact]
    public void LiveActivitySessionMapsToState()
    {
        var question = LiveAsk.OfQuestions("q", [new LiveQuestion("a", "Which?", ["A", "B"])]);
        Assert.Equal(new ActivityStatus(ActivityState.Working, null), LiveActivity.SummaryStatus(Summary(busy: true)));
        Assert.Equal(new ActivityStatus(ActivityState.Done, null), LiveActivity.SummaryStatus(Summary()));
        Assert.Equal(new ActivityStatus(ActivityState.Needs, ActivityKind.Question), LiveActivity.SummaryStatus(Summary(ask: question)));
        Assert.Equal(new ActivityStatus(ActivityState.Needs, ActivityKind.Approval), LiveActivity.SummaryStatus(Summary(true, LiveAsk.OfApproval("t", "bash"))));
        Assert.Equal(new ActivityStatus(ActivityState.Needs, ActivityKind.Plan), LiveActivity.SummaryStatus(Summary(true, LiveAsk.OfPlan("p"))));
        // A picker the person opened isn't the agent asking.
        Assert.Equal(new ActivityStatus(ActivityState.Working, null), LiveActivity.SummaryStatus(Summary(true, LiveAsk.OfMenu("m", "Select", []))));
    }

    [Fact]
    public void LiveActivityGoneSessionEnded() =>
        Assert.Equal(new ActivityStatus(ActivityState.Ended, null), LiveActivity.SummaryStatus(null));

    [Fact]
    public void LiveActivityJsonCarriesKindOnlyWhenNeeded()
    {
        Assert.Equal("{\"state\":\"working\"}", DartJson.Encode(LiveActivity.ToJson(new(ActivityState.Working, null))));
        Assert.Equal("{\"state\":\"needs\",\"kind\":\"plan\"}", DartJson.Encode(LiveActivity.ToJson(new(ActivityState.Needs, ActivityKind.Plan))));
    }
}

/// <summary>Port of packages/pocketterm_core/test/agent_test.dart.</summary>
public class LiveAgentTests
{
    [Fact]
    public void LiveAgentProfileOfArgs()
    {
        Assert.Equal("personal", Agents.OmpProfileOfArgs("omp --profile=personal"));
        Assert.Equal("work", Agents.OmpProfileOfArgs("/opt/homebrew/bin/omp --profile work -c"));
        Assert.Equal("", Agents.OmpProfileOfArgs("omp --profile=Work"));
        Assert.Equal("", Agents.OmpProfileOfArgs("omp --profile"));
        Assert.Equal("", Agents.OmpProfileOfArgs("omp --resume /x.jsonl"));
        Assert.Equal("", Agents.OmpProfileOfArgs("omp"));
        Assert.Equal("personal", Agents.OmpProfileOfArgs("omp --profile=work --profile personal"));
        Assert.Equal("work", Agents.OmpProfileOfArgs("omp --profile=work -- --profile x"));
        Assert.Equal("", Agents.OmpProfileOfArgs("omp --profile=default"));
    }

    [Fact]
    public void LiveAgentProfileNames()
    {
        Assert.True(Agents.IsOmpProfile("personal"));
        Assert.True(Agents.IsOmpProfile("a.b_c-1"));
        Assert.False(Agents.IsOmpProfile("a."));
        Assert.False(Agents.IsOmpProfile(".a"));
        Assert.False(Agents.IsOmpProfile(""));
        Assert.False(Agents.IsOmpProfile("a; rm -rf ~"));
        Assert.False(Agents.IsOmpProfile(new string('a', 65)));
    }

    [Fact]
    public void LiveAgentOnlyOmpRunsInAProfile()
    {
        Assert.Equal("omp --profile=personal", Agent.Omp.CommandIn("personal"));
        Assert.Equal("omp", Agent.Omp.CommandIn(""));
        Assert.Equal("claude", Agent.Claude.CommandIn("personal"));
        Assert.Equal("omp · personal", Agent.Omp.LabelIn("personal"));
        Assert.Equal("omp", Agent.Omp.LabelIn(""));
        Assert.Equal("Claude", Agent.Claude.LabelIn("personal"));
        static string Typed(string s) => s.Replace("\u00A0", " ").Replace("\u2060", "");
        Assert.Equal("omp --profile=personal -c", Typed(Agent.Omp.ResumeIn("personal")));
        Assert.Equal(Agent.Omp.Resume(), Agent.Omp.ResumeIn(""));
        Assert.Equal("/reload-plugins", Agent.Claude.PickUpIn("personal"));
    }
}
