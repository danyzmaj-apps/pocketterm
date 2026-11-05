using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using PocketTerm.Core;
using PocketTerm.Desktop.Tests.Store;

namespace PocketTerm.Desktop.Tests;

/// <summary>test/integrations_test.dart.</summary>
public sealed class IntegrationsTests : IDisposable
{
    /// <summary>apps/pocketterm-desktop/integrations, which the app bundles.</summary>
    private static readonly string Bundled = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(ThisFile())!, "..", "..", "..", "integrations"));

    private readonly string _home = Directory.CreateTempSubdirectory("pocketterm-integrations").FullName;

    public void Dispose()
    {
        try
        {
            Directory.Delete(_home, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private static string ThisFile([CallerFilePath] string path = "") => path;

    private string H(string relative) => Path.Combine([_home, .. relative.Split('/')]);

    /// <summary>The files under <paramref name="dir"/>, by their path below it with <c>/</c>, hidden ones left out.</summary>
    private static SortedDictionary<string, string> FilesIn(string dir)
    {
        var files = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
        {
            if (Path.GetFileName(f).StartsWith('.')) continue;
            files[Path.GetRelativePath(dir, f).Replace('\\', '/')] = File.ReadAllText(f);
        }
        return files;
    }

    private Integrations Make(
        Integrations.Run? run = null, IReadOnlyList<string>? claudePaths = null, bool? windows = false,
        Func<string>? windowsPath = null, TimeSpan? claudeTimeout = null) =>
        new(home: _home, bundled: Bundled, run: run, claudePaths: claudePaths, windows: windows, windowsPath: windowsPath,
            claudeTimeout: claudeTimeout);

    // ------------------------------------------------------------ omp

    [Fact]
    public async Task OmpInstallsTheExtensionAndTellsAnOutdatedCopyFromACurrentOne()
    {
        var integrations = Make();
        Assert.Equal(new IntegrationState(false, false, null), await integrations.StateAsync(Agent.Omp));

        await integrations.InstallAsync(Agent.Omp);
        var dir = H(".omp/agent/extensions");
        Assert.Equal(FilesIn(Path.Combine(Bundled, "omp")), FilesIn(dir));
        Assert.Equal(["pocketterm-live.ts"], FilesIn(dir).Keys);
        Assert.Equal(new IntegrationState(true, true, null), await integrations.StateAsync(Agent.Omp));

        File.WriteAllText(Path.Combine(dir, "pocketterm-live.ts"), "// older");
        Assert.Equal(new IntegrationState(true, false, null), await integrations.StateAsync(Agent.Omp));

        File.Delete(Path.Combine(dir, "pocketterm-live.ts"));
        Assert.False((await integrations.StateAsync(Agent.Omp)).Installed);
    }

    [StorePosixFact]
    public async Task OmpReplacesASymlinkedExtensionInsteadOfWritingThroughIt()
    {
        var dir = Directory.CreateDirectory(H(".omp/agent/extensions")).FullName;
        var source = H("checkout-live.ts");
        File.WriteAllText(source, "// my checkout");
        File.CreateSymbolicLink(Path.Combine(dir, "pocketterm-live.ts"), source);

        await Make().InstallAsync(Agent.Omp);
        Assert.Equal("// my checkout", File.ReadAllText(source));
        Assert.Null(new FileInfo(Path.Combine(dir, "pocketterm-live.ts")).LinkTarget);
        Assert.Equal(File.ReadAllText(Path.Combine(Bundled, "omp", "pocketterm-live.ts")), File.ReadAllText(Path.Combine(dir, "pocketterm-live.ts")));
    }

    [Fact]
    public async Task OmpGoesIntoEveryProfileTooAndCountsAsInstalledOnlyWhereEachHasIt()
    {
        Directory.CreateDirectory(H(".omp/profiles/personal"));
        Directory.CreateDirectory(H(".omp/profiles/Bad"));
        File.WriteAllText(H(".omp/profiles/notes.txt"), "");
        var integrations = Make();
        Assert.Equal(["personal"], integrations.OmpProfiles());

        await integrations.InstallAsync(Agent.Omp);
        const string live = "pocketterm-live.ts";
        Assert.True(File.Exists(H($".omp/agent/extensions/{live}")));
        Assert.True(File.Exists(H($".omp/profiles/personal/agent/extensions/{live}")));
        Assert.False(Directory.Exists(H(".omp/profiles/Bad/agent")));
        Assert.Equal(new IntegrationState(true, true, null), await integrations.StateAsync(Agent.Omp));

        File.WriteAllText(H($".omp/profiles/personal/agent/extensions/{live}"), "// older");
        Assert.Equal(new IntegrationState(true, false, null), await integrations.StateAsync(Agent.Omp));

        File.Delete(H($".omp/profiles/personal/agent/extensions/{live}"));
        Assert.False((await integrations.StateAsync(Agent.Omp)).Installed);
    }

    [Fact]
    public void NoProfilesFolderNoProfiles() => Assert.Empty(Make().OmpProfiles());

    [Fact]
    public async Task OmpIsFoundByItsFolderOrItsExecutable()
    {
        var integrations = new Integrations(home: _home, bundled: Bundled, run: (_, _) => Task.FromResult(new Integrations.RunResult(1, "", "")),
            ompPaths: [H("bin/omp")], windows: false);
        Assert.False(await integrations.FoundAsync(Agent.Omp));
        Directory.CreateDirectory(H("bin"));
        File.WriteAllText(H("bin/omp"), "");
        Assert.True(await integrations.FoundAsync(Agent.Omp));
        File.Delete(H("bin/omp"));
        Directory.CreateDirectory(H(".omp"));
        Assert.True(await integrations.FoundAsync(Agent.Omp));
    }

    // ------------------------------------------------------------ Claude Code

    private (FakeClaude Claude, Integrations Integrations, string Dir) Claude()
    {
        var claude = new FakeClaude(H("bin/claude"));
        Directory.CreateDirectory(H("bin"));
        File.WriteAllText(claude.Path, "");
        return (claude, Make(claude.Run, [H("nope/claude"), claude.Path]), H(".config/pocketterm/claude-plugin"));
    }

    private static JsonObject Listed(string from, bool enabled = true) => new()
    {
        ["id"] = "pocketterm@pocketterm",
        ["enabled"] = enabled,
        ["readFromFolder"] = $"{from}/plugins/pocketterm",
    };

    [Fact]
    public async Task AFirstInstallCopiesTheMarketplaceWithoutItsTestsAddsItAndInstallsThePlugin()
    {
        var (claude, integrations, dir) = Claude();
        Directory.CreateDirectory(Path.Combine(dir, "plugins", "pocketterm", "hooks"));
        File.WriteAllText(Path.Combine(dir, "plugins", "pocketterm", "hooks", "gone.ts"), "");

        await integrations.InstallAsync(Agent.Claude);
        var expected = FilesIn(Path.Combine(Bundled, "claude"));
        foreach (var k in expected.Keys.Where(f => f.StartsWith("plugins/pocketterm/tests/", StringComparison.Ordinal)).ToList()) expected.Remove(k);
        Assert.Equal(expected, FilesIn(dir));
        Assert.Equal(
            File.ReadAllText(Path.Combine(Bundled, "claude", ".claude-plugin", "marketplace.json")),
            File.ReadAllText(Path.Combine(dir, ".claude-plugin", "marketplace.json")));
        Assert.True(File.Exists(Path.Combine(dir, "plugins", "pocketterm", ".claude-plugin", "plugin.json")));
        Assert.False(Directory.Exists(Path.Combine(dir, "plugins", "pocketterm", "tests")));
        Assert.False(File.Exists(Path.Combine(dir, "plugins", "pocketterm", ".gitignore")));
        Assert.Equal(
        [
            "--version",
            "plugin list --json",
            $"plugin marketplace add {dir} --json",
            "plugin install pocketterm@pocketterm --json",
        ], claude.Calls);

        claude.List = [Listed(dir)];
        Assert.Equal(new IntegrationState(true, true, null), await integrations.StateAsync(Agent.Claude));
        File.WriteAllText(Path.Combine(dir, "plugins", "pocketterm", "hooks", "hooks.json"), "{}");
        Assert.Equal(new IntegrationState(true, false, null), await integrations.StateAsync(Agent.Claude));
        // A file of its own there makes it out of date too (Claude Code loads the folder whole).
        File.WriteAllText(Path.Combine(dir, "plugins", "pocketterm", "hooks", "hooks.json"),
            File.ReadAllText(Path.Combine(Bundled, "claude", "plugins", "pocketterm", "hooks", "hooks.json")));
        File.WriteAllText(Path.Combine(dir, "plugins", "pocketterm", "hooks", "extra.ts"), "");
        Assert.Equal(new IntegrationState(true, false, null), await integrations.StateAsync(Agent.Claude));
    }

    [Fact]
    public async Task UpdatingRefreshesTheMarketplaceAndThePluginAndTurnsADisabledOneBackOn()
    {
        var (claude, integrations, dir) = Claude();
        claude.List = [Listed(dir, enabled: false)];
        Assert.False((await integrations.StateAsync(Agent.Claude)).Installed);
        claude.Calls.Clear();

        await integrations.InstallAsync(Agent.Claude);
        Assert.Equal(
        [
            "--version",
            "plugin list --json",
            "plugin marketplace update pocketterm --json",
            "plugin update pocketterm@pocketterm --json",
            "plugin enable pocketterm@pocketterm --json",
        ], claude.Calls);
    }

    [Fact]
    public async Task APocketTermPluginLoadingFromElsewhereIsMovedOverToTheCopy()
    {
        var (claude, integrations, dir) = Claude();
        claude.List = [Listed(H("Dev/pocketterm/apps/pocketterm-desktop/integrations/claude"))];
        Assert.False((await integrations.StateAsync(Agent.Claude)).Installed);
        claude.Calls.Clear();

        await integrations.InstallAsync(Agent.Claude);
        Assert.Equal(
        [
            $"plugin marketplace add {dir} --json",
            "plugin update pocketterm@pocketterm --json",
        ], claude.Calls.Skip(2));
    }

    [Fact]
    public async Task AMissingClaudeIsSaidPlainlyAndNothingIsRunOrCopied()
    {
        var (claude, integrations, dir) = Claude();
        File.Delete(claude.Path);
        Assert.Equal(new IntegrationState(false, false, "Claude Code isn't installed"), await integrations.StateAsync(Agent.Claude));
        var e = await Assert.ThrowsAsync<IntegrationException>(() => integrations.InstallAsync(Agent.Claude));
        Assert.Equal("Claude Code isn't installed", e.Message);
        Assert.Empty(claude.Calls);
        Assert.False(Directory.Exists(dir));
        Assert.False(await integrations.FoundAsync(Agent.Claude));
    }

    [Fact]
    public async Task AClaudeThatNeverAnswersIsSaidPlainlyInsteadOfKeepingSettingsChecking()
    {
        var (claude, _, _) = Claude();
        var hung = Make(
            (exe, args) => args[0] == "plugin" ? new TaskCompletionSource<Integrations.RunResult>().Task : claude.Run(exe, args),
            [claude.Path],
            claudeTimeout: TimeSpan.FromMilliseconds(50));
        Assert.Equal(new IntegrationState(false, false, Integrations.NoAnswer), await hung.StateAsync(Agent.Claude));
        Assert.False(await hung.ClaudeModsOffAsync());
        var e = await Assert.ThrowsAsync<IntegrationException>(() => hung.InstallAsync(Agent.Claude));
        Assert.Equal(Integrations.NoAnswer, e.Message);
    }

    [StorePosixFact]
    public async Task AClaudeProcessThatHangsIsStoppedAtTheTimeout()
    {
        var script = H("hangs/claude");
        Directory.CreateDirectory(H("hangs"));
        File.WriteAllText(script, "#!/bin/sh\nexec sleep 30\n");
        Chmod(script);
        var hangs = Make(claudePaths: [script], claudeTimeout: TimeSpan.FromMilliseconds(300));
        var clock = Stopwatch.StartNew();
        Assert.Equal(Integrations.NoAnswer, (await hangs.StateAsync(Agent.Claude)).Problem);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10));
    }

    // The login shell answers with POSIX paths ('/…'), which a Windows test folder isn't.
    [StorePosixFact]
    public async Task ClaudeFoundOnlyByTheLoginShellsPathIsUsed()
    {
        var (claude, _, _) = Claude();
        File.Move(claude.Path, H("claude"));
        var onPath = new FakeClaude(H("claude")) { OnPath = $"{H("claude")}\n" };
        var found = Make(onPath.Run, [claude.Path]);
        Assert.Equal(new IntegrationState(false, false, null), await found.StateAsync(Agent.Claude));
        Assert.Equal(["--version", "plugin list --json"], onPath.Calls);
    }

    [StorePosixFact]
    public async Task AProfileThatPrintsSomethingBeforeTheShellsAnswerDoesntHideClaude()
    {
        var (claude, _, _) = Claude();
        File.Move(claude.Path, H("claude"));
        var onPath = new FakeClaude(H("claude")) { OnPath = $"Welcome back!\n\u001b[1mbanner\u001b[0m\n{H("claude")}\n" };
        var found = Make(onPath.Run, [claude.Path]);
        Assert.Equal(new IntegrationState(false, false, null), await found.StateAsync(Agent.Claude));
    }

    [Fact]
    public async Task FromFinderClaudeInstalledWithNvmNewestNodeFirstIsFoundWithoutAShell()
    {
        var shell = new List<string>();
        foreach (var v in new[] { "v9.11.2", "v20.10.0", "v18.19.1" })
        {
            Directory.CreateDirectory(H($".nvm/versions/node/{v}/bin"));
            File.WriteAllText(H($".nvm/versions/node/{v}/bin/claude"), "");
        }
        var nvm = new FakeClaude(H(".nvm/versions/node/v20.10.0/bin/claude"));
        var integrations = Make((exe, args) =>
        {
            if (exe == "/bin/zsh") shell.Add(string.Join(' ', args));
            return nvm.Run(exe, args);
        }, claudePaths: null);
        Assert.Null((await integrations.StateAsync(Agent.Claude)).Problem);
        Assert.Empty(shell);
    }

    [StorePosixFact]
    public async Task FromFinderClaudeInstalledWithNpmRunsOnTheNodeItWasInstalledWith()
    {
        // npm's claude: a `#!/usr/bin/env node` script in the global prefix; the Node it was installed with in nvm.
        var node = H(".nvm/versions/node/v20.10.0/bin/node");
        Directory.CreateDirectory(Path.GetDirectoryName(node)!);
        File.WriteAllText(node, """
            #!/bin/sh
            case "$*" in
              *--version*) echo '2.1.400 (Claude Code)' ;;
              *"plugin list"*) echo '[]' ;;
            esac

            """);
        var script = H(".npm-global/bin/claude");
        Directory.CreateDirectory(Path.GetDirectoryName(script)!);
        File.WriteAllText(script, "#!/usr/bin/env node\nconsole.log(\"not this node\");\n");
        Chmod(node);
        Chmod(script);
        var npm = Make(claudePaths: [script]);
        Assert.Equal(new IntegrationState(false, false, null), await npm.StateAsync(Agent.Claude));
    }

    [Fact]
    public async Task OnWindowsClaudeIsTheNativeInstallersClaudeExeAndNoLoginShellIsAsked()
    {
        var exe = new FakeClaude(H(".local/bin/claude.exe")) { OnPath = $"{H("claude")}\n" };
        Directory.CreateDirectory(H(".local/bin"));
        File.WriteAllText(exe.Path, "");
        var ran = new List<string>();
        var windows = Make((e, args) =>
        {
            ran.Add(e);
            return exe.Run(e, args);
        }, claudePaths: null, windows: true, windowsPath: () => @"C:\Windows\system32");
        Assert.Equal(new IntegrationState(false, false, null), await windows.StateAsync(Agent.Claude));
        Assert.Equal(["--version", "plugin list --json"], exe.Calls);

        File.Delete(exe.Path);
        Assert.Equal("Claude Code isn't installed", (await windows.StateAsync(Agent.Claude)).Problem);
        Assert.DoesNotContain("/bin/zsh", ran);
    }

    [Fact]
    public async Task OnWindowsClaudeInstalledWithNpmWhilePocketTermRunsIsFoundOnThePathANewLoginHas()
    {
        var npm = H("AppData/Roaming/npm");
        var exe = new FakeClaude(Path.Combine(npm, "claude.cmd"));
        Directory.CreateDirectory(npm);
        File.WriteAllText(exe.Path, "");
        var path = @"C:\Windows\system32";
        var windows = Make(exe.Run, claudePaths: null, windows: true, windowsPath: () => path);
        Assert.Equal("Claude Code isn't installed", (await windows.StateAsync(Agent.Claude)).Problem);
        // npm's installer added its folder to the user's Path in the registry.
        path = $"{path};{npm}";
        Assert.True(await windows.FoundAsync(Agent.Claude));
        Assert.Null((await windows.StateAsync(Agent.Claude)).Problem);
    }

    [Fact]
    public async Task AClaudeCodeOlderThanModsIsTooOld()
    {
        var (claude, integrations, _) = Claude();
        claude.Version = "2.1.286 (Claude Code)";
        Assert.Equal("Claude Code 2.1.286 is too old: update it to 2.1.287 or later", (await integrations.StateAsync(Agent.Claude)).Problem);
        claude.Version = "2.2.0 (Claude Code)";
        Assert.Null((await integrations.StateAsync(Agent.Claude)).Problem);
        claude.Version = "3.0.0 (Claude Code)";
        Assert.Null((await integrations.StateAsync(Agent.Claude)).Problem);
        claude.Version = "command not found";
        Assert.Equal("Couldn't run Claude Code: exit code 0", (await integrations.StateAsync(Agent.Claude)).Problem);
    }

    [Fact]
    public async Task ModsSwitchedOffAreNoticedThroughClaudePluginTest()
    {
        var (claude, integrations, _) = Claude();
        Assert.False(await integrations.ClaudeModsOffAsync());
        claude.ModsOff = true;
        Assert.True(await integrations.ClaudeModsOffAsync());
        Assert.StartsWith("plugin test ", claude.Calls[^1]);
        // The empty directory it tests is gone again.
        Assert.False(Directory.Exists(claude.Calls[^1]["plugin test ".Length..]));

        File.Delete(claude.Path);
        Assert.False(await integrations.ClaudeModsOffAsync());
    }

    [Fact]
    public async Task AFailingClaudeCommandFailsTheInstallWithWhatItSaid()
    {
        var (claude, integrations, _) = Claude();
        claude.Fail = "plugin install pocketterm@pocketterm --json";
        var e = await Assert.ThrowsAsync<IntegrationException>(() => integrations.InstallAsync(Agent.Claude));
        Assert.Equal("Plugin \"pocketterm\" not found", e.Message);
    }

    [Fact]
    public void ThePhoneHearsMissingBeforeOutdatedBeforeModsOff()
    {
        Assert.Equal(AgentIntegration.Missing, Integrations.IntegrationOf(new(new(false, false, null), false)));
        Assert.Equal(AgentIntegration.Missing, Integrations.IntegrationOf(new(new(true, true, "Claude Code didn't answer"), true)));
        Assert.Equal(AgentIntegration.Outdated, Integrations.IntegrationOf(new(new(true, false, null), true)));
        Assert.Equal(AgentIntegration.Off, Integrations.IntegrationOf(new(new(true, true, null), true)));
        Assert.Equal(AgentIntegration.Installed, Integrations.IntegrationOf(new(new(true, true, null), false)));
    }

    private static void Chmod(string path)
    {
        if (OperatingSystem.IsWindows()) return;
        File.SetUnixFileMode(path, (UnixFileMode)0b111_101_101);
    }

    /// <summary>Claude Code's CLI as a test sets it up (test/app_fakes.dart's FakeClaude), recording every
    /// call in <see cref="Calls"/>.</summary>
    private sealed class FakeClaude(string path)
    {
        public string Path { get; } = path;

        public string Version { get; set; } = "2.1.296 (Claude Code)";

        public JsonArray List { get; set; } = [];

        public string? Fail { get; set; }

        public bool ModsOff { get; set; }

        /// <summary>What a login shell's <c>command -v claude</c> prints; null: nothing found.</summary>
        public string? OnPath { get; set; }

        public List<string> Calls { get; } = [];

        public Task<Integrations.RunResult> Run(string exe, IReadOnlyList<string> args)
        {
            if (exe == "/bin/zsh") return Done(OnPath == null ? 1 : 0, OnPath ?? "", "");
            Assert.Equal(Path, exe);
            var call = string.Join(' ', args);
            Calls.Add(call);
            if (call == Fail)
            {
                return Done(1, "{\"outcome\":\"failed\",\"message\":\"Plugin \\\"pocketterm\\\" not found\"}\n", "✘ Failed");
            }
            if (call == "--version") return Done(0, $"{Version}\n", "");
            if (string.Join(' ', args.Take(2)) == "plugin test" && ModsOff)
            {
                return Done(1, "",
                    "claude plugin test: hooks modules are turned off in this process: the rollout switch was saved off " +
                    "by an earlier session and is not refreshed yet.\n");
            }
            if (call == "plugin list --json") return Done(0, DartJson.Encode(List), "");
            return Done(0, "{\"outcome\":\"ok\"}\n", "");
        }

        private static Task<Integrations.RunResult> Done(int code, string stdout, string stderr) =>
            Task.FromResult(new Integrations.RunResult(code, stdout, stderr));
    }
}
