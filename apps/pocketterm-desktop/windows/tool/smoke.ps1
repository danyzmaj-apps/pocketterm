# Smoke test of a published Windows app built with the test hooks (-p:PocketTermE2E=true), run by CI:
#
#   pwsh apps/pocketterm-desktop/windows/tool/smoke.ps1 -App <publish dir> [-Artifacts <dir>]
#
# In a throwaway support folder and cli.json, with secrets in memory (POCKETTERM_PROFILE), it:
#   1. starts PocketTerm --hidden (as at login) and waits for its local API: cli.json, then /v1/ping with the
#      nonce proof and with the token;
#   2. starts PocketTerm again: the second start hands over to the first and exits, and the first shows its window
#      (the first-run setup), checked through UI Automation by AutomationId and walked one step in;
#   3. quits it (`PocketTerm.exe --quit`, the tray's Quit) and checks it took cli.json back out.
# Screenshots and the app's log go to -Artifacts.
param(
  [Parameter(Mandatory)] [string]$App,
  [string]$Artifacts = (Join-Path ([IO.Path]::GetTempPath()) 'pocketterm-smoke-artifacts')
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path (Resolve-Path $App) 'PocketTerm.exe'
if (-not (Test-Path $exe)) { throw "no PocketTerm.exe in $App" }
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

function Step($text) { Write-Host "== $text" }

function Shot($name) {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save((Join-Path $Artifacts "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
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
  $cond = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $processId
  [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) |
    Where-Object { $_.Current.Name -eq 'PocketTerm' } | Select-Object -First 1
}

function Find($window, $id) {
  $cond = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::AutomationIdProperty), $id
  $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Press($element) {
  $pattern = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); return }
  throw "$($element.Current.AutomationId) can't be pressed"
}

# (Not $app: PowerShell's names ignore case, and -App is the publish folder.)
$pt = $null
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
  if (Window $pt.Id) { throw 'the window shows, though PocketTerm started --hidden' }

  Step 'second start: hands over and exits, the first shows its window'
  $second = Start-Process -FilePath $exe -PassThru
  if (-not $second.WaitForExit(30000)) { throw 'the second PocketTerm kept running' }
  if ($second.ExitCode -ne 0) { throw "the second PocketTerm exited with $($second.ExitCode)" }
  $window = Until 'the window' { Window $pt.Id }
  $choose = Until 'setup-this-computer' { Find $window 'setup-this-computer' }
  foreach ($id in 'setup-own-server', 'setup-supabase') { if (-not (Find $window $id)) { throw "no $id on the first-run setup" } }
  Shot '1-setup'

  Step 'On this computer'
  Press $choose
  Until 'check-installed' { Find $window 'check-installed' } | Out-Null
  if (-not (Find $window 'setup-start-server')) { throw 'no setup-start-server' }
  Shot '2-this-computer'
  Press (Until 'setup-back' { Find $window 'setup-back' })
  Until 'the choose screen again' { Find $window 'setup-own-server' } | Out-Null
  if ($pt.HasExited) { throw "PocketTerm exited ($($pt.ExitCode))" }

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
  if (Test-Path $log) { Write-Host '--- PocketTerm log'; Get-Content $log | Write-Host }
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
