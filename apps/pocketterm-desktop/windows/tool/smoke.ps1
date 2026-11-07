# Smoke test of a published Windows app built with the test hooks (-p:PocketTermE2E=true), run by CI:
#
#   pwsh apps/pocketterm-desktop/windows/tool/smoke.ps1 -App <publish dir> -Phone <PhoneStandIn.dll> [-Artifacts <dir>]
#
# In a throwaway support folder and cli.json, with secrets in memory (POCKETTERM_PROFILE), it:
#   1. starts PocketTerm --hidden (as at login) and waits for its local API: cli.json, then /v1/ping with the
#      nonce proof and with the token;
#   2. sees its window open anyway (nothing is set up, so there's nothing to do but that) and closes it: the window
#      hides, PocketTerm keeps running;
#   3. starts PocketTerm again: the second start hands over to the first and exits, and the first shows its window
#      (the first-run setup), checked through UI Automation by AutomationId and walked one step in;
#   4. starts the bundled server (pocketterm-server.exe serve on 127.0.0.1) and sets PocketTerm up with it: Join
#      another computer's PocketTerm, its setup link pasted (a test build takes any URL), signed in, the setup checklist, then Settings, each section in turn;
#   5. Phone → Add a phone… shows the pairing code, and the phone stand-in (tool/PhoneStandIn, PocketTerm.Core)
#      scans it: it signs in, joins this computer's channel and gets the terminal bridge's sealed state;
#   6. Account: signs that phone out (its confirm dialog), signs this computer out (sign-in page), Use a different
#      server (the first-run setup again);
#   7. quits it (`PocketTerm.exe --quit`, the tray's Quit) and checks it took cli.json back out.
# Screenshots and the app's log go to -Artifacts.
param(
  [Parameter(Mandatory)] [string]$App,
  [Parameter(Mandatory)] [string]$Phone,
  [string]$Artifacts = (Join-Path ([IO.Path]::GetTempPath()) 'pocketterm-smoke-artifacts')
)
$ErrorActionPreference = 'Stop'
$appDir = (Resolve-Path $App).Path
$exe = Join-Path $appDir 'PocketTerm.exe'
if (-not (Test-Path $exe)) { throw "no PocketTerm.exe in $App" }
$serverExe = Join-Path $appDir 'pocketterm-server.exe'
if (-not (Test-Path $serverExe)) { throw "no pocketterm-server.exe in $App" }
$Phone = (Resolve-Path $Phone).Path
New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null
$Artifacts = (Resolve-Path $Artifacts).Path
$started = Get-Date
$root = Join-Path ([IO.Path]::GetTempPath()) ("pocketterm-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$cli = Join-Path $root 'cli.json'
$log = Join-Path $Artifacts 'pocketterm.log'
$env:POCKETTERM_DATA = Join-Path $root 'support'
$env:POCKETTERM_CLI_JSON = $cli
$env:POCKETTERM_PROFILE = 'smoke'
$env:POCKETTERM_LOG = $log
# No Tailscale here: a stand-in that isn't there keeps the real one (if any) out of it.
$env:POCKETTERM_TAILSCALE = Join-Path $root 'no-tailscale.exe'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
$UIA = [System.Windows.Automation.AutomationElement]

function Step($text) { Write-Host "== $text" }

$shots = 0
function Shot($name) {
  $script:shots++
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save((Join-Path $Artifacts ('{0:D2}-{1}.png' -f $script:shots, $name)), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

function Until($what, [scriptblock]$test, [int]$seconds = 60) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    $value = & $test
    if ($value) { return $value }
    Start-Sleep -Milliseconds 250
  }
  throw "timed out after $seconds s waiting for $what"
}

function Window($processId) {
  $cond = New-Object System.Windows.Automation.PropertyCondition ($UIA::ProcessIdProperty), $processId
  $UIA::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) |
    Where-Object { $_.Current.Name -eq 'PocketTerm' } | Select-Object -First 1
}

# The element with AutomationId $id in PocketTerm's window (dialogs included), or none.
function Find($id) {
  $cond = New-Object System.Windows.Automation.PropertyCondition ($UIA::AutomationIdProperty), $id
  $w = Window $pt.Id
  if ($w) { $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond) }
}

# Every element whose AutomationId starts with $prefix.
function FindPrefixed($prefix) {
  $w = Window $pt.Id
  if (-not $w) { return @() }
  @($w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.AutomationId.StartsWith($prefix) })
}

function Wait($id, [int]$seconds = 60) { Until $id { Find $id } $seconds }

# Presses a button or link, selects a navigation item.
function Press($element) {
  $p = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return }
  if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return }
  if ($element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle(); return }
  throw "$($element.Current.AutomationId) can't be pressed"
}

# The button named $name that isn't one of ours (a dialog's own buttons have no id of ours; the page behind it may
# have a button of the same name).
function FindButton($name) {
  $w = Window $pt.Id
  if (-not $w) { return $null }
  $byName = New-Object System.Windows.Automation.PropertyCondition ($UIA::NameProperty), $name
  $isButton = New-Object System.Windows.Automation.PropertyCondition ($UIA::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Button)
  $cond = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]]@($byName, $isButton))
  $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond) |
    Where-Object { -not $_.Current.AutomationId.StartsWith('settings-') } | Select-Object -First 1
}

# (Not "Type": that's Get-Content's alias, and an alias beats a function.)
function SetText($element, $text) {
  $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
}

function Alive {
  if ($pt.HasExited) { throw "PocketTerm exited ($($pt.ExitCode))" }
}

# (Not $app: PowerShell's names ignore case, and -App is the publish folder.)
$pt = $null
$server = $null
try {
  Step 'start --hidden'
  $pt = Start-Process -FilePath $exe -ArgumentList '--hidden' -PassThru
  $info = Until 'cli.json' { if (Test-Path $cli) { try { Get-Content $cli -Raw | ConvertFrom-Json } catch { $null } } }
  if ($info.pid -ne $pt.Id) { throw "cli.json names pid $($info.pid), PocketTerm is $($pt.Id)" }
  Write-Host "local API on 127.0.0.1:$($info.port)"

  Step '/v1/ping'
  $nonce = [guid]::NewGuid().ToString('N')
  $ping = Invoke-RestMethod "http://127.0.0.1:$($info.port)/v1/ping?nonce=$nonce"
  $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, [Text.Encoding]::UTF8.GetBytes($info.token))
  $want = -join ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("pocketterm-ping`n$($info.port)`n$nonce")) | ForEach-Object { $_.ToString('x2') })
  if ($ping.app -ne 'pocketterm' -or $ping.proof -ne $want) { throw "bad ping answer: $($ping | ConvertTo-Json -Compress)" }
  $mine = Invoke-RestMethod "http://127.0.0.1:$($info.port)/v1/ping" -Headers @{ Authorization = "Bearer $($info.token)" }
  if ($mine.pid -ne $pt.Id) { throw "bad ping answer: $($mine | ConvertTo-Json -Compress)" }

  Step 'not set up: the window opens though started --hidden; closing it only hides it'
  $window = Until 'the window' { Window $pt.Id }
  Wait 'setup-join' | Out-Null
  $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
  Until 'the window to hide' { -not (Window $pt.Id) } | Out-Null
  Start-Sleep -Seconds 1
  if ($pt.HasExited) { throw "closing the window ended PocketTerm ($($pt.ExitCode))" }

  Step 'second start: hands over and exits, the first shows its window'
  $second = Start-Process -FilePath $exe -PassThru
  if (-not $second.WaitForExit(30000)) { throw 'the second PocketTerm kept running' }
  if ($second.ExitCode -ne 0) { throw "the second PocketTerm exited with $($second.ExitCode)" }
  Until 'the window' { Window $pt.Id } | Out-Null
  Step 'setup: the Tailscale checklist, Start, and Join another computer'
  Wait 'check-installed' | Out-Null
  foreach ($id in 'setup-start-server', 'setup-join') { if (-not (Find $id)) { throw "no $id on the first-run setup" } }
  Shot 'setup'
  Alive

  Step 'a server: the bundled pocketterm-server on 127.0.0.1'
  $start = [System.Diagnostics.ProcessStartInfo]::new($serverExe)
  foreach ($a in 'serve', '--data', (Join-Path $root 'server'), '--address', '127.0.0.1', '--port', '0', '--exit-with-stdin') { $start.ArgumentList.Add($a) }
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $server = [System.Diagnostics.Process]::Start($start)
  $listening = $null
  $deadline = (Get-Date).AddSeconds(60)
  while (-not $listening -and (Get-Date) -lt $deadline) {
    $read = $server.StandardOutput.ReadLineAsync()
    if (-not $read.Wait(30000) -or $null -eq $read.Result) { break }
    if ($read.Result -match '"event"\s*:\s*"listening"') { $listening = $read.Result | ConvertFrom-Json }
  }
  if (-not $listening) { throw "pocketterm-server didn't say it listens" }
  $serverUrl = "http://127.0.0.1:$($listening.port)"
  $setupLink = (& $serverExe setup-link --data (Join-Path $root 'server') --public-url $serverUrl | Select-Object -First 1).Trim()
  if ($LASTEXITCODE -or -not $setupLink.StartsWith('pocketterm://setup')) { throw "no setup link: $setupLink" }
  Write-Host "server at $serverUrl"

  Step 'Join another computer: paste the local server's setup link (test builds take any URL), connect'
  Press (Wait 'setup-join')
  SetText (Wait 'setup-link') $setupLink
  Wait 'setup-link-health' | Out-Null
  Shot 'setup-link'
  Press (Wait 'setup-connect')

  Step 'signed in: the setup checklist'
  $done = Wait 'get-ready-done'
  Start-Sleep -Seconds 2
  Shot 'get-ready'

  Step 'Settings, each section'
  Press $done
  foreach ($tab in 'phone', 'agents', 'terminals', 'account') {
    Press (Wait "settings-tab-$tab")
    Start-Sleep -Seconds 2
    Shot "settings-$tab"
  }
  Wait 'settings-sign-out' | Out-Null
  Alive

  Step 'Phone: Add a phone… shows the pairing code; the phone stand-in scans it'
  Press (Wait 'settings-tab-phone')
  Press (Wait 'settings-add-phone')
  $qr = Wait 'pairing-qr'
  $pairing = Until 'the pairing link' { $l = $qr.Current.HelpText; if ($l -and $l.StartsWith('pocketterm://')) { $l } }
  Start-Sleep -Seconds 1
  Shot 'pairing'
  # Its log goes to stderr: not an error here.
  $ErrorActionPreference = 'Continue'
  $phoneOut = @(& dotnet $Phone $pairing 60 2>&1 | ForEach-Object { "$_" })
  $phoneExit = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  $phoneOut | ForEach-Object { Write-Host "  phone: $_" }
  if ($phoneExit) { throw "the phone stand-in failed ($phoneExit)" }
  if (-not ($phoneOut | Where-Object { $_.StartsWith('state from ') })) { throw 'the phone got no state' }
  Press (Until 'the dialog''s Done' { FindButton 'Done' })
  Until 'the pairing dialog to close' { -not (Find 'pairing-qr') } | Out-Null
  Alive

  Step 'Account: sign the phone out (confirm), then this computer'
  Press (Wait 'settings-tab-account')
  $phoneRow = Until 'the phone on the account' { FindPrefixed 'settings-phone-sign-out-' | Select-Object -First 1 }
  Shot 'account-with-phone'
  Press $phoneRow
  $confirm = Until 'the confirm dialog' { FindButton 'Sign out' }
  Shot 'phone-sign-out-dialog'
  Press $confirm
  Until 'the phone to go' { -not (FindPrefixed 'settings-phone-sign-out-') } | Out-Null
  Press (Wait 'settings-sign-out')
  Wait 'sign-in-other-server' | Out-Null
  Start-Sleep -Seconds 1
  Shot 'signed-out'
  Press (Find 'sign-in-other-server')
  # The first-run setup opens where it was left (Paste your server's setup link), as the Flutter app's did; Back
  # goes up to its first screen.
  Wait 'setup-link' | Out-Null
  Shot 'setup-again'
  Until 'the first screen' {
    if (Find 'setup-this-computer') { return $true }
    if ($b = Find 'setup-back') { Press $b }
    $false
  } 30 | Out-Null
  Alive

  Step 'quit'
  $quit = Start-Process -FilePath $exe -ArgumentList '--quit' -PassThru
  $quit.WaitForExit(30000) | Out-Null
  if (-not $pt.WaitForExit(30000)) { throw "PocketTerm didn't quit" }
  if (Test-Path $cli) { throw 'cli.json is still there after quitting' }
  Write-Host 'SMOKE PASSED'
}
catch {
  Shot 'failed'
  if ($pt) { Write-Host "PocketTerm $($pt.Id): $(if ($pt.HasExited) { "exited with $($pt.ExitCode)" } else { 'running' })" }
  # A crash before the log is open shows in the Application event log (.NET Runtime, Application Error).
  Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $started } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -in '.NET Runtime', 'Application Error', 'Windows Error Reporting' } |
    ForEach-Object { Write-Host "--- $($_.ProviderName) $($_.TimeCreated)"; Write-Host $_.Message }
  throw
}
finally {
  if ($pt -and -not $pt.HasExited) { $pt.Kill($true) }
  if ($server -and -not $server.HasExited) {
    # Closing its stdin stops it (--exit-with-stdin).
    $server.StandardInput.Close()
    if (-not $server.WaitForExit(10000)) { $server.Kill($true) }
  }
  if (Test-Path $log) { Write-Host '--- PocketTerm log'; Get-Content $log | Write-Host }
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
