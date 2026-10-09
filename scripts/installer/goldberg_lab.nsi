; -*- coding: utf-8 -*-
; Build-only NSIS 3.13 source. All game/mod copies are made from the user's PC.
Unicode true
RequestExecutionLevel user
ManifestSupportedOS Win10
SetCompressor /SOLID lzma
SetDateSave off
ShowInstDetails show
ShowUninstDetails show
CRCCheck on

!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"

!ifndef PAYLOAD
  !error "PAYLOAD must be the exact-source verified package directory"
!endif
!ifndef OUTPUT
  !error "OUTPUT must be the new installer path"
!endif
!ifndef SOURCE_SHA
  !error "SOURCE_SHA is required"
!endif

!define MK1212_SETUP_VERSION "0.2.2"

Name "MK1212 — dwie Attile ${MK1212_SETUP_VERSION}"
OutFile "${OUTPUT}"
InstallDir "D:\MK1212\Launcher"
BrandingText "MK1212 · HOST + CLIENT · ${MK1212_SETUP_VERSION}"
VIProductVersion "${MK1212_SETUP_VERSION}.0"
VIAddVersionKey /LANG=1045 "ProductName" "MK1212 — dwie Attile"
VIAddVersionKey /LANG=1045 "FileDescription" "Instalator dwóch klientów Attili i wybranych modów"
VIAddVersionKey /LANG=1045 "FileVersion" "${MK1212_SETUP_VERSION}"
VIAddVersionKey /LANG=1045 "LegalCopyright" "MK1212Scripts contributors; upstream notices included"
VIAddVersionKey /LANG=1045 "Comments" "Source ${SOURCE_SHA}; actual ATTILA multiplayer NOT_RUN"

Var GameRoot
Var ModsRoot
Var HostGameRoot
Var ClientGameRoot
Var SandboxieRoot
Var PowerShell
Var InputFile
Var CliInput
Var Dialog
Var GameField
Var ModsField
Var HostField
Var ClientField
Var SandboxieField
Var Control
Var InstallResult

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Dwie Attile na jednym komputerze"
!define MUI_WELCOMEPAGE_TEXT "Wskaż własną instalację Steam oraz folder z modami. Instalator przygotuje dwa osobne katalogi gry i zachowa kolejność wybranych modów.$\r$\n$\r$\nDomyślnie: HOST na C:, CLIENT na D:.$\r$\n$\r$\nPrzed kopiowaniem zamknij Attilę i poczekaj na zakończenie aktualizacji Steam. Pierwsze przygotowanie może potrwać."
!insertmacro MUI_PAGE_WELCOME
!define MUI_DIRECTORYPAGE_TEXT_TOP "Wybierz folder małego programu uruchamiającego. Tutaj powstaną też osobne profile gry i raporty. Foldery obu kopii Attili wskażesz w następnym kroku."
!insertmacro MUI_PAGE_DIRECTORY
Page custom SourcesPage SourcesLeave
Page custom CopiesPage CopiesLeave
Page custom SandboxiePage SandboxieLeave
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "Obie kopie zostały przygotowane"
!define MUI_FINISHPAGE_TEXT "Grę uruchomisz skrótem „MK1212 — uruchom obie Attile” na pulpicie.$\r$\n$\r$\nW obu oknach sprawdź menu MK1212, potem utwórz lobby LAN w HOST i dołącz z CLIENT. Działanie kampanii wymaga sprawdzenia w grze."
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Uruchom obie Attile"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchBoth
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Polish"

!macro FolderRow Y LABEL VALUE FIELD CALLBACK
  ${NSD_CreateLabel} 0 ${Y}u 100% 12u "${LABEL}"
  Pop $Control
  IntOp $0 ${Y} + 14
  ${NSD_CreateDirRequest} 0 $0u 80% 13u "$${VALUE}"
  Pop $${FIELD}
  ${NSD_SetTextLimit} $${FIELD} 240
  ${NSD_CreateBrowseButton} 82% $0u 18% 14u "Przeglądaj…"
  Pop $Control
  ${NSD_OnClick} $Control ${CALLBACK}
!macroend

!macro BrowseFunction NAME FIELD
Function ${NAME}
  Pop $0
  ${NSD_GetText} $${FIELD} $1
  nsDialogs::SelectFolderDialog "Wybierz folder" "$1"
  Pop $1
  ${If} $1 != error
    ${NSD_SetText} $${FIELD} "$1"
  ${EndIf}
FunctionEnd
!macroend

!insertmacro BrowseFunction BrowseGame GameField
!insertmacro BrowseFunction BrowseMods ModsField
!insertmacro BrowseFunction BrowseHost HostField
!insertmacro BrowseFunction BrowseClient ClientField
!insertmacro BrowseFunction BrowseSandboxie SandboxieField

Function .onInit
  SetShellVarContext current
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Ten instalator wymaga 64-bitowego Windowsa."
    SetErrorLevel 2
    Abort
  ${EndIf}
  StrCpy $PowerShell "$WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe"
  StrCpy $GameRoot "D:\SteamLibrary\steamapps\common\Total War Attila"
  StrCpy $ModsRoot ""
  StrCpy $HostGameRoot "C:\MK1212\HOST"
  StrCpy $ClientGameRoot "D:\MK1212\CLIENT"
  StrCpy $SandboxieRoot ""
  IfFileExists "$PROGRAMFILES64\Sandboxie-Plus\Start.exe" 0 +2
    StrCpy $SandboxieRoot "$PROGRAMFILES64\Sandboxie-Plus"
  ${If} $SandboxieRoot == ""
    IfFileExists "D:\Sandboxie-Plus\Start.exe" 0 +2
      StrCpy $SandboxieRoot "D:\Sandboxie-Plus"
  ${EndIf}
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\payload"
  !include "${PAYLOAD_INCLUDE}"
  StrCpy $InputFile "$PLUGINSDIR\setup-input.ini"
  StrCpy $CliInput ""
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/SETTINGS=" $CliInput
  ${If} ${Silent}
    ${If} $CliInput == ""
      ; A missing/ignored automation input cannot silently use GUI defaults.
      SetErrorLevel 3
      Abort
    ${EndIf}
  ${EndIf}
  ${If} $CliInput != ""
    IfFileExists "$CliInput" settings_present 0
      SetErrorLevel 3
      Abort
    settings_present:
    StrCpy $InputFile "$CliInput"
    ReadINIStr $INSTDIR "$InputFile" "MK1212" "ToolkitRoot"
    ReadINIStr $GameRoot "$InputFile" "MK1212" "GameRoot"
    ReadINIStr $ModsRoot "$InputFile" "MK1212" "ModsRoot"
    ReadINIStr $HostGameRoot "$InputFile" "MK1212" "HostGameRoot"
    ReadINIStr $ClientGameRoot "$InputFile" "MK1212" "ClientGameRoot"
    ReadINIStr $SandboxieRoot "$InputFile" "MK1212" "SandboxieRoot"
  ${EndIf}
FunctionEnd

Function SourcesPage
  !insertmacro MUI_HEADER_TEXT "Gra Steam i mody" "Wskaż istniejące pliki, które mają trafić do obu kopii."
  nsDialogs::Create 1018
  Pop $Dialog
  !insertmacro FolderRow 0 "Folder Attili — zawierający Attila.exe:" GameRoot GameField BrowseGame
  ${If} $ModsRoot == ""
    ${GetParent} "$GameRoot" $0
    ${GetParent} "$0" $1
    StrCpy $ModsRoot "$1\workshop\content\325610"
  ${EndIf}
  !insertmacro FolderRow 48 "Folder z modami — Workshop albo własny katalog paczek:" ModsRoot ModsField BrowseMods
  ${NSD_CreateLabel} 0 100u 100% 40u "Kolejność zostanie odczytana z konfiguracji Attili. Jeśli zmieniałeś wybór w launcherze Steam, uruchom raz zwykłą grę z MK1212 i zamknij ją przed instalacją."
  Pop $Control
  nsDialogs::Show
FunctionEnd

Function SourcesLeave
  ${NSD_GetText} $GameField $GameRoot
  ${NSD_GetText} $ModsField $ModsRoot
  IfFileExists "$GameRoot\Attila.exe" +3 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "W tym folderze nie ma Attila.exe. Wskaż katalog zainstalowanej gry."
    Abort
  IfFileExists "$ModsRoot\*.*" +3 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "Wskaż istniejący folder z modami."
    Abort
FunctionEnd

Function CopiesPage
  !insertmacro MUI_HEADER_TEXT "Dwie osobne kopie" "Miejsce zostanie sprawdzone osobno na każdym dysku."
  nsDialogs::Create 1018
  Pop $Dialog
  !insertmacro FolderRow 0 "Pierwsza kopia — HOST:" HostGameRoot HostField BrowseHost
  !insertmacro FolderRow 48 "Druga kopia — CLIENT:" ClientGameRoot ClientField BrowseClient
  ${NSD_CreateLabel} 0 100u 100% 38u "Wybierz nowe, puste foldery. Każda kopia potrzebuje miejsca na całą grę i importowane paczki. Przy ponownym uruchomieniu instalatora zachowaj te same ścieżki."
  Pop $Control
  nsDialogs::Show
FunctionEnd

Function CopiesLeave
  ${NSD_GetText} $HostField $HostGameRoot
  ${NSD_GetText} $ClientField $ClientGameRoot
FunctionEnd

Function OpenSandboxieWebsite
  Pop $0
  ExecShell "open" "https://sandboxie-plus.com/downloads/"
FunctionEnd

Function SandboxiePage
  !insertmacro MUI_HEADER_TEXT "Osobne profile graczy" "Do uruchomienia obu gier potrzebne jest Sandboxie-Plus."
  nsDialogs::Create 1018
  Pop $Dialog
  !insertmacro FolderRow 0 "Folder zainstalowanego Sandboxie-Plus:" SandboxieRoot SandboxieField BrowseSandboxie
  ${NSD_CreateLink} 0 48u 100% 14u "Pobierz Sandboxie-Plus z oficjalnej strony"
  Pop $Control
  ${NSD_OnClick} $Control OpenSandboxieWebsite
  ${NSD_CreateLabel} 0 76u 100% 64u "Jeśli program jest już zainstalowany, sprawdź wykryty folder i kliknij „Instaluj”. Jeśli go brakuje, zainstaluj stabilną wersję x64, a potem wskaż jej folder. Gdy Sandboxie poprosi o restart Windowsa, zrób go przed przygotowaniem kopii."
  Pop $Control
  nsDialogs::Show
FunctionEnd

Function SandboxieLeave
  ${NSD_GetText} $SandboxieField $SandboxieRoot
  IfFileExists "$SandboxieRoot\Start.exe" 0 missing_sandboxie
  IfFileExists "$SandboxieRoot\SbieIni.exe" sandboxie_ready 0
  missing_sandboxie:
    MessageBox MB_OK|MB_ICONEXCLAMATION "Wskaż folder zainstalowanego Sandboxie-Plus zawierający Start.exe i SbieIni.exe."
    Abort
  sandboxie_ready:
    Return
FunctionEnd

Section "Przygotuj obie kopie"
  SetShellVarContext current
  ${If} $CliInput == ""
    FileOpen $0 "$InputFile" w
    FileWriteWord $0 65279
    FileClose $0
    WriteINIStr "$InputFile" "MK1212" "ToolkitRoot" "$INSTDIR"
    WriteINIStr "$InputFile" "MK1212" "GameRoot" "$GameRoot"
    WriteINIStr "$InputFile" "MK1212" "ModsRoot" "$ModsRoot"
    WriteINIStr "$InputFile" "MK1212" "HostGameRoot" "$HostGameRoot"
    WriteINIStr "$InputFile" "MK1212" "ClientGameRoot" "$ClientGameRoot"
    WriteINIStr "$InputFile" "MK1212" "SandboxieRoot" "$SandboxieRoot"
    FlushINI "$InputFile"
  ${EndIf}
  DetailPrint "MK1212 — instalator ${MK1212_SETUP_VERSION}"
  DetailPrint "Program uruchamiający: $INSTDIR"
  DetailPrint "Gra Steam: $GameRoot"
  DetailPrint "Źródło modów: $ModsRoot"
  DetailPrint "Kopia HOST: $HostGameRoot"
  DetailPrint "Kopia CLIENT: $ClientGameRoot"
  DetailPrint "Sprawdzanie plików i miejsca. Następnie kopiowanie gry oraz wybranych modów."
  SetOutPath "$PLUGINSDIR\payload"
  nsExec::ExecToLog '"$PowerShell" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\payload\scripts\runtime\goldberg_setup.ps1" -Mode Install -SettingsPath "$InputFile"'
  Pop $InstallResult
  ${If} $InstallResult != "0"
    DetailPrint "Przygotowanie zatrzymane. Kod: $InstallResult. Szczegóły znajdują się powyżej."
    SetErrorLevel 2
    Abort
  ${EndIf}
  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\MK1212 — dwie Attile"
  CreateShortcut "$DESKTOP\MK1212 — uruchom obie Attile.lnk" "$INSTDIR\RUN-INSTALLED-GOLDBERG.cmd" "Run"
  CreateShortcut "$SMPROGRAMS\MK1212 — dwie Attile\Uruchom obie Attile.lnk" "$INSTDIR\RUN-INSTALLED-GOLDBERG.cmd" "Run"
  CreateShortcut "$SMPROGRAMS\MK1212 — dwie Attile\Zbierz raport.lnk" "$INSTDIR\RUN-INSTALLED-GOLDBERG.cmd" "Collect"
  CreateShortcut "$SMPROGRAMS\MK1212 — dwie Attile\Odinstaluj launcher.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MK1212GoldbergLab" "DisplayName" "MK1212 — dwie Attile"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MK1212GoldbergLab" "DisplayVersion" "${MK1212_SETUP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MK1212GoldbergLab" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MK1212GoldbergLab" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MK1212GoldbergLab" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MK1212GoldbergLab" "NoRepair" 1
  SetErrorLevel 0
SectionEnd

Function LaunchBoth
  SetOutPath "$INSTDIR"
  ExecShell "open" "$INSTDIR\RUN-INSTALLED-GOLDBERG.cmd" "Run"
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  StrCpy $PowerShell "$WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe"
  nsExec::ExecToLog '"$PowerShell" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\runtime\goldberg_setup.ps1" -Mode Uninstall -SettingsPath "$INSTDIR\installer-settings.json"'
  Pop $InstallResult
  ${If} $InstallResult != "0"
    DetailPrint "Nie usunięto launchera. Sprawdź komunikat powyżej."
    SetErrorLevel 2
    Abort
  ${EndIf}
  Delete "$DESKTOP\MK1212 — uruchom obie Attile.lnk"
  Delete "$SMPROGRAMS\MK1212 — dwie Attile\Uruchom obie Attile.lnk"
  Delete "$SMPROGRAMS\MK1212 — dwie Attile\Zbierz raport.lnk"
  Delete "$SMPROGRAMS\MK1212 — dwie Attile\Odinstaluj launcher.lnk"
  RMDir "$SMPROGRAMS\MK1212 — dwie Attile"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MK1212GoldbergLab"
  Delete "$INSTDIR\Uninstall.exe"
  DetailPrint "Launcher usunięty. Kopie gier, mody, profile, zapisy i raporty zostały zachowane."
  SetErrorLevel 0
SectionEnd
