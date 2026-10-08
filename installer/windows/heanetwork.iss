; Windows installer. Built by CI:
;   iscc /DAppVersion=1.2.3 installer\windows\heanetwork.iss
;
; Installs per user (no administrator prompt), which is also what lets the
; app update itself silently.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "HeaNetwork"
#define AppExe "heanetwork.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Identifies the app across versions. Never change it.
AppId={{6F1E7C52-0B8A-4E1D-9C57-2A6B9D1F3E84}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=HeaNetwork
AppPublisherURL=https://github.com/zarkon4631/HeaNetwork
AppSupportURL=https://github.com/zarkon4631/HeaNetwork/issues
AppUpdatesURL=https://github.com/zarkon4631/HeaNetwork/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\..\dist
OutputBaseFilename={#AppName}-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
LicenseFile=..\..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; A running copy (possibly hidden in the tray) is closed through the Restart
; Manager. AppMutex is deliberately not used: during a self-update the old
; copy is still exiting when Setup starts, and the mutex check would abort.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Interactive install: the usual "launch now" checkbox.
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; Self-update (/SILENT /RELAUNCH=1): start the new version again.
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: RelaunchRequested

[UninstallRun]
; A leftover autostart entry would point at a file that no longer exists.
Filename: "{cmd}"; Parameters: "/C reg delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v HeaNetwork /f"; Flags: runhidden; RunOnceId: "RemoveAutostart"

[Code]
function RelaunchRequested: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;
