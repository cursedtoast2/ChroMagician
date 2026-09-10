#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef ReleaseVersion
  #error ReleaseVersion is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif

[Setup]
AppId=ChroMagician
AppName=ChroMagician
AppVersion={#ReleaseVersion}
AppPublisher=CursedToast
AppPublisherURL=https://chromagic.org
AppSupportURL=https://chromagic.org
DefaultDirName={localappdata}\Programs\ChroMagician
DefaultGroupName=ChroMagician
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=ChroMagician-{#ReleaseVersion}-windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallFilesDir={app}\uninstall
UninstallDisplayIcon={app}\app\chromatic_pc_backup.exe
CloseApplications=no
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ChroMagician"; Filename: "{app}\app\chromatic_pc_backup.exe"; WorkingDir: "{app}\app"
Name: "{autodesktop}\ChroMagician"; Filename: "{app}\app\chromatic_pc_backup.exe"; WorkingDir: "{app}\app"; Tasks: desktopicon

[Run]
Filename: "{app}\app\chromatic_pc_backup.exe"; Description: "Open ChroMagician"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\app"
Type: files; Name: "{app}\.app.update.lock"
