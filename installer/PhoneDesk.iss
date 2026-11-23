#ifndef BuildVersion
#define BuildVersion "1.0.0"
#endif

[Setup]
AppId=PhoneDesk.Windows
AppName=Точка связи
AppVersion={#BuildVersion}
AppPublisher=PhoneDesk
DefaultDirName={localappdata}\Programs\PhoneDesk
DefaultGroupName=Точка связи
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
OutputDir=..\dist
OutputBaseFilename=PhoneDesk-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Точка связи

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\stage\PhoneDesk\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Точка связи"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\PhoneDesk.ps1"""; WorkingDir: "{app}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\PhoneDesk.ps1"""; Description: "Открыть «Точку связи»"; Flags: postinstall skipifsilent nowait
