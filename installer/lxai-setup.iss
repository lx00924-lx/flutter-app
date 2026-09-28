; ============================================================================
;  LxAI Windows 安装器（Inno Setup 6）
;
;  构建前先备料（生成私有 Python 运行时）：
;      pwsh -File prepare-runtime.ps1
;  然后编译：
;      & "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" lxai-setup.iss
;  或直接用 build-installer.ps1 一步做完。
;
;  产物：output\LxAI-Setup-<版本>.exe
;
;  设计要点（改之前先读）：
;  1) 捆绑【私有 Python 运行时】到 {app}\python —— 用户无需自己装 Python，
;     也不会因为各人系统的 Python 版本/缺库而行为不一致。依赖（websockets）
;     只装在这个私有目录里，不污染用户的全局 Python 环境。
;     App 侧 BridgeProcessManager._resolvePythonExecutable() 会优先用它。
;  2) 安装目录【让用户自己选】：默认 {autopf}\LxAI（所有用户→Program Files，
;     仅当前用户→LocalAppData，由 Inno 自动解析），向导里可改。
;     PrivilegesRequiredOverridesAllowed=dialog 让用户能选"为所有用户"或"仅为我"。
;  3) 卸载【保留用户数据】：聊天记录/登录态在 %USERPROFILE%\Documents（Hive），
;     不在安装目录，卸载不会碰它。这里只清安装目录里运行时生成的文件。
; ============================================================================

#ifndef MyAppVersion
  #define MyAppVersion "1.0.1"
#endif

#define MyAppName "LxAI"
#define MyAppPublisher "lx00924-lx"
#define MyAppExeName "LxAI.exe"
#define MyAppURL "https://github.com/lx00924-lx/flutter-app"
; 固定 GUID：卸载程序靠它识别同一个应用，**永远不要改**
#define MyAppId "{{8CC1E567-9691-46FF-914C-B7A24B230C39}"

#define ReleaseDir "..\flutter_app\build\windows\x64\runner\Release"
#define RuntimeDir "runtime\python"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases

DefaultDirName={autopf}\{#MyAppName}
DisableDirPage=no
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
AllowNoIcons=yes

; 许可协议（Apache-2.0：随分发提供许可副本是许可条款要求）
LicenseFile=..\LICENSE

OutputDir=output
OutputBaseFilename=LxAI-Setup-{#MyAppVersion}
SetupIconFile=..\flutter_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName} {#MyAppVersion}

Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 默认不需要管理员；用户可在向导里切换成"为所有用户安装"（届时才请求提权）
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
Name: "chinese"; MessagesFile: "languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Flutter Release 产物（约 32 个文件 / 35 MB）
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; 私有 Python 运行时（Python 3.13 embeddable + websockets）
Source: "{#RuntimeDir}\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs createallsubdirs
; 许可与协议文本（随分发提供）
Source: "..\NOTICE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\TERMS.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\PRIVACY.md"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 运行时生成的文件不在安装清单里，卸载时需显式清理。
; 注意：用户数据（聊天记录 / 登录态）在 %USERPROFILE%\Documents，**刻意不在这里删**。
Type: files; Name: "{app}\lxai_bridge.py"
Type: files; Name: "{app}\bridge-run.log"
Type: files; Name: "{app}\app-debug.log"
Type: filesandordirs; Name: "{app}\__pycache__"
Type: filesandordirs; Name: "{app}\python"
