using System.Text;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

/// <summary>apps/pocketterm-desktop/test/prompt_files_test.dart.</summary>
public sealed class PromptFilesTests : IDisposable
{
    private readonly LiveTemp _tmp = new("pocketterm_prompt_files");
    private readonly PromptFiles _files;

    public PromptFilesTests()
    {
        _files = new PromptFiles(_tmp["pocketterm-files"]);
    }

    public void Dispose() => _tmp.Dispose();

    private static PromptFile F(string name, string text, string mime = "") => new(name, mime, Encoding.UTF8.GetBytes(text));

    private bool Within(string path) => path.StartsWith(_files.Dir + Path.DirectorySeparatorChar, StringComparison.Ordinal);

    [Fact]
    public async Task Files_land_under_their_own_names_in_a_folder_of_their_own_per_prompt_nothing_overwritten()
    {
        var first = await _files.SaveAsync([F("notes.txt", "one"), F("notes.txt", "two"), F("notes.txt", "three")]);
        Assert.Equal(["notes.txt", "notes (2).txt", "notes (3).txt"], first.Select(Path.GetFileName));
        Assert.Equal(["one", "two", "three"], first.Select(File.ReadAllText));
        Assert.Single(first.Select(Path.GetDirectoryName).Distinct());
        Assert.True(Within(first[0]));

        var second = await _files.SaveAsync([F("notes.txt", "later")]);
        Assert.Equal("notes.txt", Path.GetFileName(second.Single()));
        Assert.NotEqual(Path.GetDirectoryName(first[0]), Path.GetDirectoryName(second.Single()));
        Assert.Equal("one", File.ReadAllText(first[0]));
    }

    [Fact]
    public async Task A_name_that_tries_to_leave_its_folder_stays_in_it()
    {
        var saved = await _files.SaveAsync(
        [
            F("../../.ssh/authorized_keys", "a"),
            F(@"..\..\Windows\evil.bat", "b"),
            F("..", "c"),
            F("/etc/passwd", "d"),
            F("a\u0000b\nc.txt", "e"),
        ]);
        foreach (var path in saved)
        {
            Assert.True(Within(path), path);
            Assert.Equal(2, Path.GetRelativePath(_files.Dir, path).Split(Path.DirectorySeparatorChar).Length);
        }
        Assert.Equal(["authorized_keys", "evil.bat", "file", "passwd", "abc.txt"], saved.Select(Path.GetFileName));
    }

    [Fact]
    public void Safe_names_have_no_characters_Windows_refuses_no_device_names_no_trailing_dots_and_a_capped_length()
    {
        Assert.Equal("re plan v2.md", PromptFiles.SafeFileName("re: \"plan\" <v2>?.md"));
        Assert.Equal("_CON.txt", PromptFiles.SafeFileName("CON.txt"));
        Assert.Equal("report", PromptFiles.SafeFileName("report. . "));
        Assert.Equal("file", PromptFiles.SafeFileName("..."));
        // A hidden file keeps its name.
        Assert.Equal(".env", PromptFiles.SafeFileName(".env"));
        Assert.Equal("scan.pdf", PromptFiles.SafeFileName("scan", mime: "application/pdf"));
        Assert.Equal("scan", PromptFiles.SafeFileName("scan", mime: "application/x-unknown"));
        var longName = PromptFiles.SafeFileName(new string('a', 300) + ".pdf");
        Assert.Equal(120, longName.Length);
        Assert.EndsWith(".pdf", longName);
    }

    [Fact]
    public void Every_name_Windows_opens_as_a_device_gets_a_prefix_however_it_is_written()
    {
        foreach (var name in new[] { "conin$", "CONOUT$.txt", "COM¹.log", "lpt³", "CON .txt", "nul.tar.gz", "Aux" })
        {
            Assert.Equal($"_{name}", PromptFiles.SafeFileName(name));
        }
        foreach (var name in new[] { "console.txt", "com10.txt", "conin.txt", "lpt.md" })
        {
            Assert.Equal(name, PromptFiles.SafeFileName(name));
        }
    }

    [Fact]
    public void A_prompt_names_its_files_as_omp_and_Claude_Code_take_them_at_the_computer()
    {
        Assert.Equal(
            "look at these\n\n@/tmp/pt/a1/notes.txt @\"/tmp/pt/a1/my notes.txt\"",
            PromptFiles.WithMentions("look at these", ["/tmp/pt/a1/notes.txt", "/tmp/pt/a1/my notes.txt"]));
        Assert.Equal("@/tmp/pt/a1/x.pdf", PromptFiles.WithMentions("  ", ["/tmp/pt/a1/x.pdf"]));
        Assert.Equal("just words", PromptFiles.WithMentions("just words", []));
        // A trailing dot or comma would be taken for punctuation; Windows paths have : and \.
        Assert.Equal("@\"/tmp/pt/a1/v1.\"", PromptFiles.FileMention("/tmp/pt/a1/v1."));
        Assert.Equal(
            @"@""C:\Users\me\AppData\Local\Temp\pocketterm-files\a1\x.pdf""",
            PromptFiles.FileMention(@"C:\Users\me\AppData\Local\Temp\pocketterm-files\a1\x.pdf"));
        Assert.Equal("@\"/tmp/pt/a1/it's.txt\"", PromptFiles.FileMention("/tmp/pt/a1/it's.txt"));
    }

    [Fact]
    public async Task Folders_older_than_a_day_go_newer_ones_stay()
    {
        var old = Path.GetDirectoryName((await _files.SaveAsync([F("old.txt", "x")])).Single())!;
        var fresh = Path.GetDirectoryName((await _files.SaveAsync([F("new.txt", "y")])).Single())!;
        Directory.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-2));

        await _files.PruneAsync();
        Assert.False(Directory.Exists(old));
        Assert.True(Directory.Exists(fresh));
    }
}
