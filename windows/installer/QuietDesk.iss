; QuietDesk Inno Setup 6 installer script (UTF-8 with BOM).
; Built via scripts/package-windows-installer.py for x64 and arm64.

#ifndef MyAppVersion
  #error MyAppVersion must be defined
#endif
#ifndef MyAppBuild
  #error MyAppBuild must be defined
#endif
#ifndef TargetArch
  #error TargetArch must be defined (x64 or arm64)
#endif
#ifndef BinaryPath
  #error BinaryPath must be defined
#endif
#ifndef OutputDir
  #error OutputDir must be defined
#endif
#ifndef RepoRoot
  #error RepoRoot must be defined
#endif

[Setup]
AppId={{8D6E4E92-7C2F-4B5A-9E3A-1F6D8B4C2A10}
AppName=QuietDesk
AppVersion={#MyAppVersion}
AppVerName=QuietDesk {#MyAppVersion} ({#TargetArch})
VersionInfoVersion={#MyAppVersion}.{#MyAppBuild}
VersionInfoProductName=QuietDesk
VersionInfoProductTextVersion={#MyAppVersion}
VersionInfoDescription=QuietDesk 远程桌面安装程序
AppPublisher=QuietDesk
AppSupportURL=https://github.com/nXiaoK/QuietDesk
AppUpdatesURL=https://github.com/nXiaoK/QuietDesk/releases
DefaultDirName={autopf}\QuietDesk
DefaultGroupName=QuietDesk
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
LicenseFile={#RepoRoot}\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=QuietDesk-{#MyAppVersion}-Windows-{#TargetArch}-Setup
SetupIconFile={#RepoRoot}\windows\app\resources\QuietDesk.ico
UninstallDisplayIcon={app}\QuietDesk.exe
UninstallDisplayName=QuietDesk
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
#if TargetArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#elif TargetArch == "x64"
  #if Ver >= 0x06030000
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
  #else
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
  #endif
#else
  #error Unsupported TargetArch (expected x64 or arm64)
#endif

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupAppTitle=安装 QuietDesk
SetupWindowTitle=安装 - %1
UninstallAppTitle=卸载 QuietDesk
UninstallAppFullTitle=卸载 %1
WelcomeLabel1=欢迎使用 [name] 安装向导
WelcomeLabel2=本向导将在你的电脑上安装 [name/ver]（{#TargetArch}）。%n%n默认安装到当前用户目录，无需管理员权限，并支持后续在软件内直接检查与安装更新。
ClickNext=点击“下一步”继续，或点击“取消”退出安装。
ButtonNext=下一步(&N) >
ButtonBack=< 上一步(&B)
ButtonInstall=安装(&I)
ButtonFinish=完成(&F)
ButtonCancel=取消
WizardLicense=许可协议
LicenseLabel=安装前请阅读以下 MIT 许可证说明。
LicenseLabel3=请阅读下列许可协议。必须接受协议条款后才能继续安装。
LicenseAccepted=我接受协议(&A)
LicenseNotAccepted=我不接受协议(&D)
WizardSelectDir=选择安装位置
SelectDirDesc=要将 [name] 安装到何处？
SelectDirLabel3=安装程序会将 [name] 安装到以下文件夹。
SelectDirBrowseLabel=若要继续，请点击“下一步”。若要选择其他文件夹，请点击“浏览”。
ButtonWizardBrowse=浏览(&R)...
WizardSelectTasks=选择附加任务
SelectTasksDesc=要执行哪些附加任务？
SelectTasksLabel2=请选择安装 [name] 时希望执行的附加任务，然后点击“下一步”。
WizardReady=准备安装
ReadyLabel1=安装程序已准备好在你的电脑上安装 [name]。
ReadyLabel2a=点击“安装”开始安装；如需查看或修改设置，请点击“上一步”。
WizardInstalling=正在安装
InstallingLabel=正在安装 [name]，请稍候...
FinishedHeadingLabel=[name] 安装向导已完成
FinishedLabelNoIcons=安装程序已在你的电脑上完成 [name] 的安装。
FinishedLabel=安装程序已在你的电脑上完成 [name] 的安装。可通过开始菜单或已选快捷方式启动应用。
ClickFinish=点击“完成”退出安装程序。
ConfirmUninstall=确定要卸载 %1 吗？（已保存的连接记录与本机配对设置会保留在用户目录中，不会被删除。）
UninstalledAll=%1 已成功从你的电脑移除。

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加选项："; Flags: unchecked
Name: "autostart"; Description: "登录 Windows 后自动启动 QuietDesk(&A)"; GroupDescription: "附加选项："; Flags: unchecked

[Files]
Source: "{#BinaryPath}"; DestDir: "{app}"; DestName: "QuietDesk.exe"; Flags: ignoreversion
Source: "{#ExtractFileDir(BinaryPath)}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\windows\licenses\THIRD-PARTY-OPUS.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\QuietDesk"; Filename: "{app}\QuietDesk.exe"
Name: "{autodesktop}\QuietDesk"; Filename: "{app}\QuietDesk.exe"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "QuietDesk"; ValueData: """{app}\QuietDesk.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[UninstallDelete]
Type: files; Name: "{app}\.QuietDesk-update-backup-*.exe"

[Run]
Filename: "{app}\QuietDesk.exe"; Description: "立即启动 QuietDesk"; Flags: nowait postinstall skipifsilent
