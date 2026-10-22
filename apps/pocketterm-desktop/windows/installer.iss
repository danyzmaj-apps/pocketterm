; PocketTerm's Windows installer (Inno Setup 6), built by
; .github/workflows/release-windows.yml after `flutter build windows --release`:
;
;   ISCC.exe /DMyAppVersion=<x.y.z> windows\installer.iss
;
; Per-user (no admin prompt): the app goes to %LOCALAPPDATA%\Programs\PocketTerm,
; and the pocketterm:// link and Launch at login live under HKCU.

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
OutputDir=..\build\windows\installer
OutputBaseFilename=PocketTerm-{#MyAppVersion}-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\PocketTerm.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; A running PocketTerm stays in the tray when asked to close its window, so a polite
; close leaves its files in use: force it (an update or uninstall while it runs); after
; an update [Run] opens the new one.
CloseApplications=force

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\PocketTerm"; Filename: "{app}\PocketTerm.exe"

[Registry]
; pocketterm:// (sign-in callback, session links); the app rewrites it on start if the install moved.
Root: HKCU; Subkey: "Software\Classes\pocketterm"; ValueType: string; ValueName: ""; ValueData: "URL:PocketTerm"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\pocketterm"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\pocketterm\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\PocketTerm.exe"" ""%1"""
; Launch at login is the app's to switch (Settings); uninstalling removes it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "PocketTerm"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\PocketTerm.exe"; Description: "Open PocketTerm"; Flags: nowait postinstall skipifsilent
