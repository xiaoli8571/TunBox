# Standard NSIS installer — same shape as every other Clash client's Setup.exe:
# welcome -> dir -> components -> install -> finish(run app). Per-user, no admin needed.
# The components page carries one optional tick box: "clear personal data". It is OFF by
# default, so installing a new version never touches %APPDATA%\TunBox.
# Installing over a running TunBox closes the app first (CloseRunningApp) instead of failing on
# the locked TunBox.exe.
# Pass defines: DSTAGE (staged publish dir), OUT (output exe), ICON (ico file).
# Encoding: UTF-8 WITH BOM. makensis only reads CJK literals as UTF-8 when the BOM is there.
Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"

!define APPNAME "TunBox"
!define VERSION "0.3.1"
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

VIProductVersion "0.3.1.0"
VIAddVersionKey "ProductName" "TunBox"
VIAddVersionKey "FileVersion" "0.3.1.0"
VIAddVersionKey "ProductVersion" "0.3.1"
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

# 装新版时主程序若在跑，File /r 覆盖 TunBox.exe 会直接报「无法写入文件」中止安装。
# 判据不用 taskkill 的返回码：最小化到托盘的 WPF 程序窗口是隐藏的，taskkill 会当成「没有可关的窗口」
# 报错返回，看起来像「进程没了」其实还锁着文件 —— 装到一半照样失败。这里只认「文件能不能被打开写」，
# 那正是唯一真正挡住安装的东西：先优雅关闭（taskkill 不带 /F = 发 WM_CLOSE），等 3 秒还锁着就强杀，
# 然后再等到解锁为止。数据侧早有兜底（落盘是临时文件 + 原子替换），强杀也不会写出半截 JSON。
# 内核 tunbox-core.exe 挂在主程序的 Job Object 上（KILL_ON_JOB_CLOSE），主程序一死它跟着死；
# 补一刀是防上次崩溃留下的孤儿内核占着 core\tunbox-core.exe 与 7890。
# 只认这两个我们自己的镜像名，不碰用户机器上的其他代理程序。
Var LockedNow
Var LockTries

Function WaitForUnlock
  StrCpy $LockedNow "0"
  StrCpy $R0 0
  ${Do}
    ClearErrors
    FileOpen $R3 "$INSTDIR\TunBox.exe" a
    ${IfNot} ${Errors}
      FileClose $R3
      ${ExitDo}
    ${EndIf}
    StrCpy $LockedNow "1"
    IntOp $R0 $R0 + 1
    ${If} $R0 >= $LockTries
      ${ExitDo}
    ${EndIf}
    Sleep 500
  ${Loop}
FunctionEnd

Function CloseRunningApp
  ${If} ${FileExists} "$INSTDIR\TunBox.exe"
    DetailPrint "正在检查 TunBox 是否在运行…"
    nsExec::ExecToStack 'taskkill /IM "TunBox.exe"'
    Pop $R1
    Pop $R2
    StrCpy $LockTries 6 # 优雅退出最多等 3 秒
    Call WaitForUnlock
    ${If} $LockedNow == "1"
      DetailPrint "TunBox 没有自己退出，强制结束。"
      nsExec::ExecToStack 'taskkill /F /IM "TunBox.exe"'
      Pop $R1
      Pop $R2
    ${EndIf}
  ${EndIf}
  nsExec::ExecToStack 'taskkill /F /IM "tunbox-core.exe"'
  Pop $R1
  Pop $R2
  ${If} ${FileExists} "$INSTDIR\TunBox.exe"
    StrCpy $LockTries 12 # 进程结束到文件解锁有窗口期，最多再等 6 秒
    Call WaitForUnlock
    ${If} $LockedNow == "1"
      DetailPrint "TunBox.exe 仍被占用，安装可能失败。"
    ${EndIf}
  ${EndIf}
FunctionEnd

Section "TunBox 主程序" InstMain
  SectionIn RO
  Call CloseRunningApp
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
