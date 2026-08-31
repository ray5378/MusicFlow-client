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
