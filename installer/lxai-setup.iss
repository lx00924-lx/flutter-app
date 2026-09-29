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
;  4) 外观：纯白底 + 产品图标（assets\wizard-*.png）；安装过程中在进度条上方
;     轮播 4 张功能截图（assets\slides\，见 [Code] 段）。轮播图用 dontcopy 打进
;     安装包但不落到目标目录，运行时用 ExtractTemporaryFile 提取。
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

; 向导外观：纯白底 + 产品图标（尺寸为 Inno 标准的 2 倍，高 DPI 下更清晰）
WizardImageFile=assets\wizard-large.png
WizardSmallImageFile=assets\wizard-small.png

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
; 安装过程中的轮播图：只打进安装包，**不安装到目标目录**，
; 运行时由 [Code] 里的 ExtractTemporaryFile 提取到 {tmp} 使用。
Source: "assets\slides\*.png"; Flags: dontcopy

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

[Code]
{ ==========================================================================
  安装过程中的轮播：在 wpInstalling 页上方展示 4 张功能截图与一句文案。

  为什么不用定时器轮播：Inno 的 Pascal Script **没有 TTimer 支持类**
  （编译会直接报 Unknown type 'TTimer'），而脚本层也没有自己的消息循环，
  SetTimer 那套 Win32 回调同样用不了。
  改用一个更贴合安装流程的触发源：Inno 在安装期间会持续调用
  CurInstallProgressChanged，于是按进度把 4 张图均匀铺开 ——
  进度 0~25% 第 1 张、25~50% 第 2 张……装到哪就看到哪，比盲切更自然。
  ========================================================================== }
const
  SlideCount = 4;

var
  SlideFiles: array[0..SlideCount - 1] of String;
  SlideTitles: array[0..SlideCount - 1] of String;
  SlideDescs: array[0..SlideCount - 1] of String;
  SlideIndex: Integer;
  SlideImage: TBitmapImage;
  SlideTitle: TNewStaticText;
  SlideDesc: TNewStaticText;

procedure InitSlideData();
begin
  SlideFiles[0] := '1-chat.png';
  SlideTitles[0] := '随时随地，向你的电脑发问';
  SlideDescs[0] := '手机、平板、另一台电脑都能远程遥控 —— 无需公网 IP';

  SlideFiles[1] := '2-agent.png';
  SlideTitles[1] := '一键启动本地桥接';
  SlideDescs[1] := '后台静默运行不弹黑窗，启动、停止、重置都在一个面板里';

  SlideFiles[2] := '3-api.png';
  SlideTitles[2] := '接入你自己的模型';
  SlideDescs[2] := '兼容 DeepSeek、OpenAI、Claude、Gemini、Ollama 等主流端点';

  SlideFiles[3] := '4-splash.png';
  SlideTitles[3] := '界面完全按你的喜好';
  SlideDescs[3] := '自定义启动页、头像、聊天背景与系统提示词，并云端同步';
end;

procedure ShowSlide(Idx: Integer);
var
  TmpPath: String;
begin
  if (Idx < 0) or (Idx >= SlideCount) then Exit;

  { 图片已在 CurPageChanged(wpInstalling) 里一次性提取好了 ——
    这里**绝不能再调 ExtractTemporaryFile**：本过程由 CurInstallProgressChanged 驱动，
    而那发生在 Inno 正在安装文件的过程中，此时调用提取器会直接抛
    「内部错误：Cannot call file extractor recursively」，轮播就废了。 }
  TmpPath := ExpandConstant('{tmp}\') + SlideFiles[Idx];

  if FileExists(TmpPath) then
    { TBitmapImage 的属性是 Bitmap / PngImage —— **没有 Picture**，
      写成 Picture 会直接报 Unknown identifier。素材是 PNG，所以走 PngImage。 }
    SlideImage.PngImage.LoadFromFile(TmpPath);

  SlideTitle.Caption := SlideTitles[Idx];
  SlideDesc.Caption := SlideDescs[Idx];
end;

{ 按安装页的实际尺寸摆放控件：图片保持 16:9 居中，文案在图片下方。
  用 ScaleX/ScaleY 做 DPI 适配，避免高 DPI 下错位。 }
procedure LayoutSlide();
var
  PageW, PageH, ImgW, ImgH: Integer;
begin
  PageW := WizardForm.InstallingPage.Width;
  PageH := WizardForm.InstallingPage.Height;

  { 图片占上方约一半；16:9 放不下就先压宽度 }
  ImgH := (PageH * 50) div 100;
  ImgW := (ImgH * 16) div 9;
  if ImgW > PageW - ScaleX(30) then
  begin
    ImgW := PageW - ScaleX(30);
    ImgH := (ImgW * 9) div 16;
  end;

  SlideImage.Left := (PageW - ImgW) div 2;
  SlideImage.Top := ScaleY(4);
  SlideImage.Width := ImgW;
  SlideImage.Height := ImgH;

  SlideTitle.Left := ScaleX(18);
  SlideTitle.Top := SlideImage.Top + ImgH + ScaleY(10);
  SlideTitle.Width := PageW - ScaleX(36);

  SlideDesc.Left := ScaleX(18);
  SlideDesc.Top := SlideTitle.Top + SlideTitle.Height + ScaleY(3);
  SlideDesc.Width := PageW - ScaleX(36);
end;

procedure InitializeWizard();
begin
  InitSlideData();
  SlideIndex := -1;

  SlideImage := TBitmapImage.Create(WizardForm.InstallingPage);
  SlideImage.Parent := WizardForm.InstallingPage;
  SlideImage.Stretch := True;
  SlideImage.Center := True;
  SlideImage.Visible := False;

  SlideTitle := TNewStaticText.Create(WizardForm.InstallingPage);
  SlideTitle.Parent := WizardForm.InstallingPage;
  SlideTitle.AutoSize := False;
  SlideTitle.Height := ScaleY(20);
  SlideTitle.Font.Size := 11;
  SlideTitle.Font.Style := [fsBold];
  SlideTitle.Visible := False;

  SlideDesc := TNewStaticText.Create(WizardForm.InstallingPage);
  SlideDesc.Parent := WizardForm.InstallingPage;
  SlideDesc.AutoSize := False;
  SlideDesc.Height := ScaleY(18);
  SlideDesc.Visible := False;
end;

{ 安装进度变化 = 轮播的驱动源（见文件头说明）}
procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
var
  NewIdx: Integer;
begin
  if MaxProgress <= 0 then Exit;

  NewIdx := (CurProgress * SlideCount) div MaxProgress;
  if NewIdx >= SlideCount then
    NewIdx := SlideCount - 1;
  if NewIdx < 0 then
    NewIdx := 0;

  if NewIdx <> SlideIndex then
  begin
    SlideIndex := NewIdx;
    ShowSlide(SlideIndex);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpInstalling then
  begin
    { 趁安装还没开始，把 4 张轮播图一次性提取到临时目录。
      必须在进入本页时做：安装期间的进度回调里不能再调提取器（见 ShowSlide 的说明）。
      注意 Pascal 的花括号本身就是注释定界符，注释正文里不要再写花括号，否则会提前闭合。 }
    ExtractTemporaryFiles('*.png');
    LayoutSlide();
    SlideIndex := 0;
    ShowSlide(0);
    SlideImage.Visible := True;
    SlideTitle.Visible := True;
    SlideDesc.Visible := True;
  end
  else if SlideImage <> nil then
  begin
    { 离开安装页要藏起来，否则控件会残留在其它页面上 }
    SlideImage.Visible := False;
    SlideTitle.Visible := False;
    SlideDesc.Visible := False;
  end;
end;

{ ==========================================================================
  安装开始前：停掉占用目标目录的桥接进程。

  为什么必须做：桥接跑的是 App 自带的私有 Python（位于应用目录的 python 子目录）。
  旧版本里它是 detached 启动、App 退出不带走，很容易变成孤儿进程；一旦它还在跑，
  就占着安装目录里的 python.exe，Inno 的 RestartManager 无法自动关闭它，安装会以
  「安装程序无法自动关闭所有应用程序」直接中止（实测踩过，退出码 5，日志里
  RestartManager found an application using one of our files: Python）。
  在这里先把它停掉，用户就不必自己去任务管理器结束 python。

  安全性：只杀「可执行文件路径位于应用目录下」的 python，
  绝不动用户自己环境里的 Python。
  ========================================================================== }
procedure StopBridgeInAppDir();
var
  ScriptPath: String;
  Script: TArrayOfString;
  ResultCode: Integer;
  AppDir: String;
begin
  AppDir := ExpandConstant('{app}');
  ScriptPath := ExpandConstant('{tmp}\stop-lxai-bridge.ps1');
  Log('StopBridgeInAppDir: 开始清理（AppDir=' + AppDir + '）');

  SetArrayLength(Script, 2);
  Script[0] := '$app = ''' + AppDir + '''';
  { 结束应用目录下的**所有**进程，不只是桥接用的 python。
    实测（2026-09-30）真正挡住安装的是 App 本体 —— 它最小化在托盘里，不响应
    RestartManager 的关闭请求，日志表现为「found an application using one of our
    files: LxAI - 私有 Agent 控制中心」，卡 30 秒后以退出码 5 中止安装。
    这里只按 ExecutablePath 过滤，碰不到用户自己环境里的任何程序。 }
  Script[1] :=
    'Get-CimInstance Win32_Process | ' +
    'Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -like ($app + ''\*'')) } | ' +
    'ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }';

  { 脚本内容纯 ASCII，用 ANSI 保存即可（保存函数不写 UTF-8）}
  if SaveStringsToFile(ScriptPath, Script, False) then
  begin
    Exec('powershell.exe',
         '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '"',
         '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Log('StopBridgeInAppDir: 清理脚本已执行，exit=' + IntToStr(ResultCode));
  end
  else
    Log('StopBridgeInAppDir: 写清理脚本失败，跳过');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { 加日志是为了定位"清理到底跑没跑、跑在 RestartManager 检查之前还是之后" ——
    实测遇到过"占用被清掉了但安装仍以退出码 5 中止"，需要日志来区分时序问题。 }
  Log('PrepareToInstall: 进入（准备安装阶段）');
  StopBridgeInAppDir();
  Result := '';
end;
