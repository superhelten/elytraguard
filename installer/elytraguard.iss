; Windows setup program for ElytraGuard, built with Inno Setup 6.
;
; Setup only unpacks the scripts and runs the same install.ps1 as the zip
; download, so both ways of installing end in the same state. Uninstalling
; runs uninstall.ps1. Build with installer\build.ps1, which passes AppVersion.

#ifndef AppVersion
  #error Build with installer\build.ps1, or pass /DAppVersion=x.y.z to ISCC
#endif

#define AppName "ElytraGuard"
#define AppUrl "https://github.com/superhelten/elytraguard"

[Setup]
AppId={{84B17321-A7F4-42CB-8275-C8EFE98D3C39}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=superhelten
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}
; install.ps1 always uses the 64-bit Program Files, so setup must run
; PowerShell as a 64-bit process too.
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
PrivilegesRequired=admin
MinVersion=10.0
DefaultDirName={autopf}\{#AppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
LicenseFile=..\LICENSE
UninstallDisplayName={#AppName}
UninstallDisplayIcon={sys}\WindowsPowerShell\v1.0\powershell.exe
OutputDir=..\dist
OutputBaseFilename=elytraguard-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes

[Files]
; Run from {tmp}: install.ps1 copies the guard into Program Files itself.
Source: "..\install.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "..\elytraguard.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "..\status.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
; Kept for the uninstaller.
Source: "..\uninstall.ps1"; DestDir: "{app}"
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1""{code:RemoveLogsArg}"; \
  Flags: runhidden waituntilterminated; RunOnceId: "RemoveElytraGuard"

[Code]
var
  RemoveLogs: Boolean;

function PowerShell: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

// [Run] ignores exit codes, so install.ps1 is started from here and a
// failure is shown with its output.
procedure CurStepChanged(CurStep: TSetupStep);
var
  LogFile, Params: String;
  ResultCode: Integer;
  Output: AnsiString;
begin
  if CurStep <> ssPostInstall then
    Exit;
  WizardForm.StatusLabel.Caption := 'Registering the scheduled task...';
  LogFile := ExpandConstant('{tmp}\install-output.txt');
  Params := '/c ""' + PowerShell + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\install.ps1') + '" > "' + LogFile + '" 2>&1"';
  if not Exec(ExpandConstant('{cmd}'), Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    ResultCode := -1;
  Log('install.ps1 exit code: ' + IntToStr(ResultCode));
  if LoadStringFromFile(LogFile, Output) then
    Log('install.ps1 output:' + #13#10 + String(Output));
  if ResultCode <> 0 then
    SuppressibleMsgBox('ElytraGuard could not register its scheduled task (exit code ' +
      IntToStr(ResultCode) + '):' + #13#10#13#10 + String(Output), mbError, MB_OK, IDOK);
end;

function InitializeUninstall: Boolean;
begin
  // A silent uninstall keeps the log and the record of Elytra's setup, like
  // uninstall.ps1 does without -RemoveLogs.
  RemoveLogs := False;
  if not UninstallSilent then
    RemoveLogs := MsgBox('Also delete the ElytraGuard log and its record of how Elytra is set up?' + #13#10#13#10 +
      'Choose No to keep them, for example if you plan to reinstall.',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
  Result := True;
end;

function RemoveLogsArg(Param: String): String;
begin
  if RemoveLogs then
    Result := ' -RemoveLogs'
  else
    Result := '';
end;
