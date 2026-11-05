using System.Text.Json.Nodes;
using PocketTerm.Core;

// A phone for tool/smoke.ps1, on PocketTerm.Core (what the phone apps speak):
//
//   PhoneStandIn <pairing link> [seconds]
//
// It does what scanning the computer's code does: signs in with the link's one-time code, finds the computer in the
// account's list, joins the computer's channel with the link's key and says hello. It succeeds once the computer's
// terminal bridge answers with its sealed state, which it prints. Exit codes: 0 state received, 1 anything else.

if (args.Length < 1)
{
    Console.Error.WriteLine("usage: PhoneStandIn <pairing link> [seconds]");
    return 1;
}
var wait = TimeSpan.FromSeconds(args.Length > 1 ? int.Parse(args[1], System.Globalization.CultureInfo.InvariantCulture) : 60);
Log.Sink = line => Console.Error.WriteLine(line);
var link = DartUri.Parse(args[0]);
var backend = Backend.FromLink(link) ?? throw new ArgumentException("not a PocketTerm link");
var computer = Backend.ComputerKey(link) ?? throw new ArgumentException("the link carries no computer key");
var code = Backend.PairingCode(link) ?? throw new ArgumentException("the link carries no pairing code");

var phone = Server.Create(backend, new MemoryDeviceTokens());
var account = await phone.RedeemCode(code, "Smoke phone", "android");
Console.WriteLine($"signed in to {backend.Host} as {account.Device.Role} of account {account.Id}");

var listed = (await phone.Desktops()).Select(Desktop.FromJson).FirstOrDefault(d => d.Id == computer.Desktop);
if (listed == null)
{
    Console.Error.WriteLine($"the account lists no computer {computer.Desktop}");
    return 1;
}
Console.WriteLine($"the account lists {listed.Name} ({listed.Platform}), online: {listed.Online}");

var state = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
var joined = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var channel = new TerminalChannel(
    phone,
    computer.Desktop,
    new Dictionary<string, Action<JsonObject>> { ["state"] = s => state.TrySetResult(s) },
    computer.Key,
    "smoke-phone",
    onJoined: on =>
    {
        if (on) joined.TrySetResult();
    });
channel.Open();
try
{
    await joined.Task.WaitAsync(wait);
    // What a phone says when it opens the computer: the bridge answers with its whole state.
    await channel.Send("hello", new JsonObject { ["from"] = "smoke-phone" });
    var got = await state.Task.WaitAsync(wait);
    var windows = got["windows"] as JsonArray;
    Console.WriteLine($"state from {listed.Name}: {windows?.Count ?? 0} terminal window(s), keys: {string.Join(", ", got.Select(e => e.Key).Order())}");
    Console.WriteLine(DartJson.Encode(got));
    return 0;
}
catch (TimeoutException)
{
    Console.Error.WriteLine(joined.Task.IsCompleted ? "no state from the computer" : "never joined the computer's channel");
    return 1;
}
finally
{
    await channel.Close();
    phone.Close();
}
