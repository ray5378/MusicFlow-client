; MusicFlow Client Windows 安装包(单文件,Inno Setup 6)
; CI 编译:ISCC.exe windows\installer.iss /DAppVersion=x.y.z /DArtifactTag=vtxyz /O<outputDir>
; 安装向导支持勾选「开始菜单快捷方式 / 桌面快捷方式」(Tasks)。
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef ArtifactTag
  #define ArtifactTag "v000"
#endif
#define MyAppName "MusicFlow"
#define MyAppExeName "MusicFlow.exe"
#define MyAppPublisher "MusicFlow"

[Setup]
AppId={{8F1B6C2E-9D4A-4E2B-9C1D-2A5B7E8F0A3C}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppVerName={#MyAppName} {#AppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; 安装/卸载前自动关闭运行中的客户端:Restart Manager 兜底 + [Code] 里的
; taskkill 双保险(RM 对部分 Flutter 应用探测不到,taskkill 是确定性手段)。
CloseApplications=force
RestartApplications=no
OutputDir=.
OutputBaseFilename=MusicFlow-{#ArtifactTag}-windows-setup
SetupIconFile=runner\resources\app_icon.ico

[Languages]
; 中文简体语言文件随仓库携带(Inno Setup 官方安装包不内置,CI 需用仓库内副本)
Name: "chinesesimplified"; MessagesFile: "lang\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

; Tasks 文案不是 Inno 标准消息,需按语言自定义(否则编译报 custom message not defined)。
[CustomMessages]
english.CreateStartMenuShortcut=Create a &start menu shortcut
chinesesimplified.CreateStartMenuShortcut=创建开始菜单快捷方式(&S)
english.CreateDesktopIcon=Create a &desktop icon
chinesesimplified.CreateDesktopIcon=创建桌面快捷方式(&D)

[Tasks]
; 开始菜单快捷方式:默认勾选,可取消;桌面快捷方式:默认不勾,可勾选。
Name: "startmenu"; Description: "{cm:CreateStartMenuShortcut}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenu
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// 安装前结束正在运行的客户端(含子进程)。
// 此前一直"不起作用"的根因:脚本里压根没有关闭机制 —— Inno 默认的
// CloseApplications 依赖 Restart Manager,对 Flutter 应用经常探测不到;
// taskkill 是确定性手段,探测不到进程时静默失败(返回非零,忽略)。
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/f /t /im {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  // 给系统一点时间释放被占用文件句柄,避免随后复制文件报"正在使用"。
  Sleep(500);
end;

// 卸载前同样先结束客户端,否则卸载会残留文件/报"文件正在使用"。
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    Exec(ExpandConstant('{sys}\taskkill.exe'),
      '/f /t /im {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(500);
  end;
end;
