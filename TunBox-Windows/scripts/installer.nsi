# Standard NSIS installer — same shape as every other Clash client's Setup.exe:
# welcome -> dir -> components -> install -> finish(run app). Per-user, no admin needed.
# The components page carries one optional tick box: "clear personal data". It is OFF by
# default, so installing a new version never touches %APPDATA%\TunBox.
# Pass defines: DSTAGE (staged publish dir), OUT (output exe), ICON (ico file).
# Encoding: UTF-8 WITH BOM. makensis only reads CJK literals as UTF-8 when the BOM is there.
Unicode true
!include "MUI2.nsh"

!define APPNAME "TunBox"
!define VERSION "0.4.8"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\TunBox"
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
Icon "${ICON}"
UninstallIcon "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\TunBox.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动 TunBox"
!define MUI_ABORTWARNING

Name "${APPNAME} ${VERSION}"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "${UNINSTKEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "0.4.8.0"
VIAddVersionKey "ProductName" "TunBox"
VIAddVersionKey "FileVersion" "0.4.8.0"
VIAddVersionKey "ProductVersion" "0.4.8"
VIAddVersionKey "FileDescription" "TunBox installer"
VIAddVersionKey "LegalCopyright" "xiaoli8571"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "TunBox 主程序" InstMain
  SectionIn RO
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

# Optional and OFF by default: only wipes the user's own data when they tick it.
Section /o "清理个人数据（订阅、节点、设置、分流库）" SecWipe
  SetDetailsPrint none
  RMDir /r "$APPDATA\TunBox"
  SetDetailsPrint both
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${InstMain} "TunBox 主程序与内置 mihomo 内核，安装到上面的目录。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecWipe} "勾选后会在安装时删除 AppData\Roaming\TunBox 里的订阅、节点、设置与分流库；不勾选则全部保留 —— 升级新版本时保持不勾选，数据不会丢。"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "un.Install"
  Delete "$DESKTOP\TunBox.lnk"
  RMDir /r "$SMPROGRAMS\TunBox"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTKEY}"
SectionEnd
