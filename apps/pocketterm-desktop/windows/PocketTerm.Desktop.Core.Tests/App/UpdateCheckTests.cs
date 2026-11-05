using System.Net;
using System.Text.Json.Nodes;
using PocketTerm.Desktop;

namespace PocketTerm.Desktop.Tests;

public class UpdateCheckTests
{
    [Fact]
    public void CompareVersionsOrdersMajorMinorAndPatchAsNumbersNotText()
    {
        Assert.True(UpdateCheck.CompareVersions("0.10.0", "0.9.9") > 0);
        Assert.True(UpdateCheck.CompareVersions("1.0.0", "0.99.99") > 0);
        Assert.True(UpdateCheck.CompareVersions("0.5.2", "0.5.10") < 0);
        Assert.Equal(0, UpdateCheck.CompareVersions("0.5.0", "0.5.0"));
    }

    [Fact]
    public void CompareVersionsIgnoresBuildMetadataAndAPreReleaseComesBeforeItsRelease()
    {
        Assert.Equal(0, UpdateCheck.CompareVersions("0.5.0+9", "0.5.0+5"));
        Assert.True(UpdateCheck.CompareVersions("0.6.0-beta.1", "0.6.0") < 0);
        Assert.True(UpdateCheck.CompareVersions("0.6.0-beta.2", "0.6.0-beta.10") < 0);
        Assert.True(UpdateCheck.CompareVersions("0.6.0-beta", "0.6.0-alpha") > 0);
        Assert.True(UpdateCheck.CompareVersions("0.6.0-rc.1", "0.5.0") > 0);
    }

    [Fact]
    public void CompareVersionsIsNullForAnythingThatIsNotAVersion()
    {
        Assert.Null(UpdateCheck.CompareVersions("latest", "0.5.0"));
        Assert.Null(UpdateCheck.CompareVersions("0.6", "0.5.0"));
        Assert.Null(UpdateCheck.CompareVersions("0.6.0", ""));
    }

    private const string Page = "https://github.com/danyzmaj-apps/pocketterm/releases/tag/v0.6.0";

    private static JsonArray Assets() =>
        [new JsonObject { ["name"] = "PocketTerm-0.6.0.dmg" }, new JsonObject { ["name"] = "PocketTerm-0.6.0-setup.exe" }];

    private static JsonObject Release(string tag, string? url = Page, JsonArray? assets = null, bool noAssets = false)
    {
        var o = new JsonObject { ["tag_name"] = tag };
        if (url != null) o["html_url"] = url;
        if (!noAssets) o["assets"] = assets ?? Assets();
        return o;
    }

    [Fact]
    public void NewerAHigherTagWithOrWithoutItsVIsTheUpdate()
    {
        Assert.Equal(new UpdateInfo("0.6.0", new Uri(Page)), UpdateCheck.Newer(Release("v0.6.0"), "0.5.0"));
        Assert.Equal("0.6.0", UpdateCheck.Newer(Release("0.6.0"), "0.5.0")?.Version);
    }

    [Fact]
    public void NewerTheSameAnOlderOrAnUnreadableReleaseIsNone()
    {
        Assert.Null(UpdateCheck.Newer(Release("v0.5.0"), "0.5.0"));
        Assert.Null(UpdateCheck.Newer(Release("v0.4.9"), "0.5.0"));
        Assert.Null(UpdateCheck.Newer(Release("nightly"), "0.5.0"));
        Assert.Null(UpdateCheck.Newer(Release("v0.6.0", url: null), "0.5.0"));
        Assert.Null(UpdateCheck.Newer(Release("v0.6.0", url: "http://example.com/x"), "0.5.0"));
        Assert.Null(UpdateCheck.Newer(new JsonArray("v0.6.0"), "0.5.0"));
    }

    [Fact]
    public void NewerAReleaseWithoutItsWindowsInstallerYetIsNoneUntilTheInstallerIsAttached()
    {
        Assert.Null(UpdateCheck.Newer(
            Release("v0.6.0", assets: [new JsonObject { ["name"] = "PocketTerm-0.6.0.dmg" }, new JsonObject { ["name"] = "appcast.xml" }]),
            "0.5.0"));
        Assert.Null(UpdateCheck.Newer(Release("v0.6.0", assets: []), "0.5.0"));
        Assert.Null(UpdateCheck.Newer(Release("v0.6.0", noAssets: true), "0.5.0"));
        Assert.NotNull(UpdateCheck.Newer(Release("v0.6.0"), "0.5.0"));
    }

    private sealed class Answer(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(answer(request));
    }

    private static UpdateCheck Checker(Func<HttpRequestMessage, HttpResponseMessage> answer) =>
        new(new HttpClient(new Answer(answer)), () => Task.FromResult("0.5.0"));

    private static HttpResponseMessage Json(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(body) };

    [Fact]
    public async Task CheckAsksGitHubsLatestReleaseAndTellsListenersAboutANewerOne()
    {
        Uri? asked = null;
        string? agent = null;
        using var check = Checker(req =>
        {
            asked = req.RequestUri;
            agent = req.Headers.UserAgent.ToString();
            return Json("""{"tag_name":"v0.6.0","html_url":"https://github.com/danyzmaj-apps/pocketterm/releases/tag/v0.6.0","assets":[{"name":"PocketTerm-0.6.0-setup.exe"}]}""");
        });
        var told = 0;
        check.PropertyChanged += (_, _) => told++;
        await check.CheckAsync();
        Assert.Equal(new Uri("https://api.github.com/repos/danyzmaj-apps/pocketterm/releases/latest"), asked);
        Assert.False(string.IsNullOrEmpty(agent));
        Assert.Equal("0.6.0", check.Update?.Version);
        Assert.Equal(1, told);
        // The same answer again changes nothing.
        await check.CheckAsync();
        Assert.Equal(1, told);
    }

    [Fact]
    public async Task AFailedCheckShowsNothingAlsoAfterOneThatFoundAnUpdate()
    {
        var fail = false;
        using var check = Checker(_ =>
        {
            if (fail) throw new HttpRequestException("offline");
            return Json("""{"tag_name":"v0.6.0","html_url":"https://github.com/x","assets":[{"name":"PocketTerm-0.6.0-setup.exe"}]}""");
        });
        await check.CheckAsync();
        Assert.NotNull(check.Update);
        fail = true;
        await check.CheckAsync();
        Assert.Null(check.Update);
    }

    [Fact]
    public async Task AnErrorStatusOrABodyThatIsNotJsonShowsNothing()
    {
        foreach (var (body, status) in new[] { ("""{"message":"API rate limit exceeded"}""", HttpStatusCode.Forbidden), ("<html>", HttpStatusCode.OK) })
        {
            using var check = Checker(_ => Json(body, status));
            await check.CheckAsync();
            Assert.Null(check.Update);
        }
    }
}
