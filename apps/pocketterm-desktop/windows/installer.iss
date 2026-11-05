; PocketTerm's Windows installer (Inno Setup 6), built by .github/workflows/release-windows.yml (and CI) from the
; app's publish folder:
;
;   pwsh tool/server-sidecar.ps1
;   dotnet publish apps/pocketterm-desktop/windows/PocketTerm.App -c Release -p:Platform=x64 -p:Version=<x.y.z>
;       -p:PocketTermRelease=true -o apps/pocketterm-desktop/build/windows/publish
;   ISCC.exe /DMyAppVersion=<x.y.z> apps/pocketterm-desktop/windows/installer.iss
;
; Per-user (no admin prompt): the app goes to %LOCALAPPDATA%\Programs\PocketTerm, and the pocketterm:// link
; and Launch at login live under HKCU. Same AppId and folder as the Flutter app's installer, so it updates a
; Flutter install in place (its leftover files go, its data in %APPDATA% stays).

#ifndef MyAppVersion
  #error Pass the version: ISCC.exe /DMyAppVersion=x.y.z windows\installer.iss
#endif

[Setup]
AppId={{17D718A3-DC81-4B51-A7AE-69230ADE08D8}
AppName=PocketTerm
AppVersion={#MyAppVersion}
AppPublisher=Danijel Lovric
AppPublisherURL=https://github.com/danyzmaj-apps/pocketterm
AppSupportURL=https://github.com/danyzmaj-apps/pocketterm/issues
AppUpdatesURL=https://github.com/danyzmaj-apps/pocketterm/releases
PrivilegesRequired=lowest
DefaultDirName={autopf}\PocketTerm
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; The Windows App SDK's floor.
MinVersion=10.0.17763
OutputDir=..\build\windows\installer
OutputBaseFilename=PocketTerm-{#MyAppVersion}-setup
SetupIconFile=PocketTerm.App\Assets\app.ico
UninstallDisplayIcon={app}\PocketTerm.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; A running PocketTerm stays in the tray when asked to close its window, so a polite
; close leaves its files in use: force it (an update or uninstall while it runs); after
; an update [Run] opens the new one.
CloseApplications=force

[InstallDelete]
; What the Flutter build (0.1.x) installed and the native app doesn't have: its engine, its assets and its plugins.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\flutter_windows.dll"
Type: files; Name: "{app}\*_plugin.dll"

[Files]
Source: "..\build\windows\publish\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\PocketTerm"; Filename: "{app}\PocketTerm.exe"

[Registry]
; pocketterm:// (setup links, session links); the app rewrites it on start if the install moved.
Root: HKCU; Subkey: "Software\Classes\pocketterm"; ValueType: string; ValueName: ""; ValueData: "URL:PocketTerm"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\pocketterm"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\pocketterm\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\PocketTerm.exe"" ""%1"""
; Launch at login is the app's to switch (Settings → Account); uninstalling removes it and Task Manager's record of it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "PocketTerm"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "PocketTerm"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\PocketTerm.exe"; Description: "Open PocketTerm"; Flags: nowait postinstall skipifsilent
