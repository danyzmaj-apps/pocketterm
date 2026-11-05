using PocketTerm.Desktop.Tests.Store;

namespace PocketTerm.Desktop.Tests;

public sealed class JsonPreferenceStoreTests : IDisposable
{
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    [Fact]
    public void EveryKindSurvivesARestartAndIsWrittenAsJson()
    {
        var path = Path.Combine(_dir.Path, "nested", "preferences.json");
        var store = new JsonPreferenceStore(path);
        store.SetString("theme", "tokyoNight");
        store.SetBool("terminal_bridge", true);
        store.SetInt("hosting_port", 47900);
        store.SetDouble("ratio", 2);
        store.SetStringList("project_roots", [@"C:\Users\me\Dev", "D:\\work \"x\""]);
        store.SetString("gone", "soon");
        store.Remove("gone");

        Assert.Equal(
            """{"theme":"tokyoNight","terminal_bridge":true,"hosting_port":47900,"ratio":2.0,"project_roots":["C:\\Users\\me\\Dev","D:\\work \"x\""]}""",
            File.ReadAllText(path));
        Assert.False(File.Exists(path + ".tmp"));

        var again = new JsonPreferenceStore(path);
        Assert.Equal("tokyoNight", again.GetString("theme"));
        Assert.True(again.GetBool("terminal_bridge"));
        Assert.Equal(47900, again.GetInt("hosting_port"));
        Assert.Equal(2.0, again.GetDouble("ratio"));
        Assert.Equal([@"C:\Users\me\Dev", "D:\\work \"x\""], again.GetStringList("project_roots"));
        Assert.Null(again.GetString("gone"));
        Assert.False(again.ContainsKey("gone"));
    }

    [Fact]
    public void AValueOfAnotherKindReadsAsNone()
    {
        var store = new JsonPreferenceStore(_dir["preferences.json"]);
        store.SetDouble("ratio", 1);
        store.SetInt("port", 1);
        store.SetString("name", "1");
        Assert.Null(store.GetInt("ratio"));
        Assert.Null(store.GetDouble("port"));
        Assert.Null(store.GetInt("name"));
        Assert.Null(store.GetBool("name"));
        Assert.Null(store.GetStringList("name"));
    }

    [Fact]
    public void AnUnreadableFileStartsEmptyAndTheNextChangeReplacesIt()
    {
        var path = _dir["preferences.json"];
        File.WriteAllText(path, "{\"theme\":");
        var store = new JsonPreferenceStore(path);
        Assert.Null(store.GetString("theme"));
        store.SetString("theme", "dawn");
        Assert.Equal("""{"theme":"dawn"}""", File.ReadAllText(path));
    }

    [Fact]
    public async Task ChangesFromManyThreadsAtOnceAllStay()
    {
        var path = _dir["preferences.json"];
        var store = new JsonPreferenceStore(path);
        await Task.WhenAll(Enumerable.Range(0, 40).Select(i => Task.Run(() => store.SetInt($"k{i}", i))));
        var again = new JsonPreferenceStore(path);
        Assert.All(Enumerable.Range(0, 40), i => Assert.Equal(i, again.GetInt($"k{i}")));
    }
}
