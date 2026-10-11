# Standard NSIS installer — same shape as every other Clash client's Setup.exe:
# welcome -> dir -> install -> finish(run app). Per-user, no admin needed.
# Pass defines: DSTAGE (staged publish dir), OUT (output exe), ICON (ico file).
# ASCII-only file: PS5.1 compatibility is not an issue for makensis, but keep it clean.
Unicode true
!include "MUI2.nsh"

!define APPNAME "TunBox"
!define VERSION "0.4.7"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\TunBox"
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
Icon "${ICON}"
UninstallIcon "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\TunBox.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Run TunBox (TunBox)"
!define MUI_ABORTWARNING

Name "${APPNAME} ${VERSION}"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "${UNINSTKEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "0.4.7.0"
VIAddVersionKey "ProductName" "TunBox"
VIAddVersionKey "FileVersion" "0.4.7.0"
VIAddVersionKey "ProductVersion" "0.4.7"
VIAddVersionKey "FileDescription" "TunBox installer"
VIAddVersionKey "LegalCopyright" "xiaoli8571"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${STAGE}\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  CreateShortcut "$DESKTOP\TunBox.lnk" "$INSTDIR\TunBox.exe"
  CreateDirectory "$SMPROGRAMS\TunBox"
  CreateShortcut "$SMPROGRAMS\TunBox\TunBox.lnk" "$INSTDIR\TunBox.exe"
  CreateShortcut "$SMPROGRAMS\TunBox\Uninstall TunBox.lnk" "$INSTDIR\uninstall.exe"

  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "xiaoli8571"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\TunBox.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "QuietUninstallString" "$INSTDIR\uninstall.exe /S"
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
SectionEnd

Section "un.Install"
  Delete "$DESKTOP\TunBox.lnk"
  RMDir /r "$SMPROGRAMS\TunBox"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTKEY}"
SectionEnd
