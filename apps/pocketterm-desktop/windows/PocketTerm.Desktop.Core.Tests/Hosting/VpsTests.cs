using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

public class VpsTests
{
    [Fact]
    public void AnIpv4AddressBecomesItsSslipIoNameADomainStaysAsItIs()
    {
        Assert.Equal("203-0-113-7.sslip.io", ServerAddress.Parse(" 203.0.113.7 ").Domain);
        Assert.Equal("51-75-10-2.sslip.io", ServerAddress.Parse("https://51.75.10.2/").Domain);
        Assert.Equal("pocketterm.example.com", ServerAddress.Parse("PocketTerm.Example.com").Domain);
        Assert.Equal("pt.example.com", ServerAddress.Parse("https://pt.example.com/v1").Domain);
        // As an SSH line has it.
        Assert.Equal("203-0-113-7.sslip.io", ServerAddress.Parse("root@203.0.113.7").Domain);
        Assert.Equal("pt.example.com", ServerAddress.Parse("pt.example.com.").Domain);
    }

    [Fact]
    public void IpV6PrivateAddressesPortsAndOtherTextAreRefusedSayingWhy()
    {
        foreach (var (typed, why) in new[]
        {
            ("2001:db8::7", "IPv4"),
            ("[2001:db8::7]", "IPv4"),
            ("192.168.1.20", "private"),
            ("10.0.0.5", "private"),
            ("100.101.102.103", "private"),
            ("127.0.0.1", "private"),
            ("169.254.1.1", "private"),
            ("203.0.113.7:443", "port"),
            ("pt.example.com:8443", "port"),
            ("my server", "isn’t an IP address"),
            ("localhost", "isn’t an IP address"),
            // Not a dotted quad (.NET alone would take it as 203.0.0.113).
            ("203.0.113", "isn’t an IP address"),
            ("", "Enter"),
        })
        {
            var a = ServerAddress.Parse(typed);
            Assert.True(a.Domain == null, typed);
            Assert.True(a.Error!.Contains(why, StringComparison.Ordinal), $"{typed}: {a.Error}");
        }
    }

    [Fact]
    public void TheSshLineUsesTheTypedUserElseRoot()
    {
        Assert.Equal("ssh ubuntu@203.0.113.7", ServerAddress.Parse("ssh ubuntu@203.0.113.7").Ssh);
        Assert.Equal("ssh root@pt.example.com", ServerAddress.Parse("https://pt.example.com/").Ssh);
        Assert.Null(ServerAddress.Parse("10.0.0.5").Ssh);
    }

    [Fact]
    public void TheCommandsInstallDockerFetchTheComposeFileOfThisReleaseStartItPrintTheLink()
    {
        Assert.Equal(
            [
                "curl -fsSL https://get.docker.com | sudo sh",
                $"mkdir -p ~/pocketterm && cd ~/pocketterm && curl -fsSLO {Vps.ComposeUrl("0.3.0")}",
                "cd ~/pocketterm && echo \"DOMAIN=pt.example.com\" > .env && sudo docker compose up -d",
                "cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link",
            ],
            Vps.Commands("pt.example.com", "0.3.0").Select(c => c.Command));
        var compose = DartUri.Parse(Vps.ComposeUrl("0.3.0"));
        Assert.Equal("raw.githubusercontent.com", compose.Host);
        Assert.Equal("/danyzmaj-apps/pocketterm/v0.3.0/apps/pocketterm-server/docker-compose.yml", compose.Path);
    }
}
