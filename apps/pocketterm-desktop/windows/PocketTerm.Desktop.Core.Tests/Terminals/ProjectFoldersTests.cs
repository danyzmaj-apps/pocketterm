namespace PocketTerm.Desktop.Tests;

public sealed class ProjectFoldersTests
{
    [Fact]
    public void OnWindowsGitHubDesktopsFolderIsFoundWhereOneDriveMovedDocumentsToo()
    {
        var there = new HashSet<string> { @"C:\Users\ana\source\repos", @"C:\Users\ana\OneDrive - Contoso\Documents\GitHub" };
        var found = ProjectFolders.WindowsProjectFolders(
            @"C:\Users\ana",
            new Dictionary<string, string>
            {
                ["OneDriveCommercial"] = @"C:\Users\ana\OneDrive - Contoso",
                ["OneDrive"] = @"C:\Users\ana\OneDrive - Contoso",
                ["OneDriveConsumer"] = "",
            },
            there.Contains);
        Assert.Equal(there.Order(StringComparer.Ordinal), found.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void SuggestionsAreTheUsualFoldersInHomeNotYetAddedSorted()
    {
        var home = Directory.CreateTempSubdirectory("pocketterm-home").FullName;
        try
        {
            foreach (var d in new[] { "src", "Dev", "Music", "repos" }) Directory.CreateDirectory(Path.Combine(home, d));
            File.WriteAllText(Path.Combine(home, "code"), ""); // a file, not a folder
            Assert.Equal(
                [Path.Combine(home, "Dev"), Path.Combine(home, "src")],
                ProjectFolders.Suggestions(home, [Path.Combine(home, "repos")], windows: false));
            Assert.Empty(ProjectFolders.Suggestions(Path.Combine(home, "gone"), [], windows: false));
        }
        finally
        {
            Directory.Delete(home, recursive: true);
        }
    }
}
