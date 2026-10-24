$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$shortcutPath = Join-Path $root 'entry\src\main\resources\base\profile\shortcuts_config.json'
$abilityPath = Join-Path $root 'entry\src\main\ets\quicktoggleability\QuickToggleAbility.ets'
$entryPath = Join-Path $root 'entry\src\main\ets\entryability\EntryAbility.ets'
$modulePath = Join-Path $root 'entry\src\main\module.json5'
$appPath = Join-Path $root 'AppScope\app.json5'

function Assert-Text([string]$Text, [string]$Pattern, [string]$Message) {
  if ($Text -notmatch $Pattern) { throw $Message }
}

$shortcut = [IO.File]::ReadAllText($shortcutPath)
$ability = [IO.File]::ReadAllText($abilityPath)
$entry = [IO.File]::ReadAllText($entryPath)
$module = [IO.File]::ReadAllText($modulePath)
$app = [IO.File]::ReadAllText($appPath)

Assert-Text $shortcut '"bundleName"\s*:\s*"com\.tunbox\.client"' 'Shortcut bundleName mismatch'
Assert-Text $shortcut '"abilityName"\s*:\s*"QuickToggleAbility"' 'Shortcut target mismatch'
Assert-Text $shortcut '"vpn_shortcut"\s*:\s*"start"' 'Shortcut parameter missing'
Assert-Text $module '"name"\s*:\s*"QuickToggleAbility"' 'QuickToggleAbility module declaration missing'
Assert-Text $module '"launchType"\s*:\s*"singleton"' 'QuickToggleAbility must use singleton launchType'
Assert-Text $ability 'onCreate\s*\(' 'Cold-start onCreate handler missing'
Assert-Text $ability 'onNewWant\s*\(' 'Existing-instance onNewWant handler missing'
Assert-Text $ability 'onForeground\s*\(' 'Foreground recovery handler missing'
Assert-Text $ability 'private\s+enqueue\s*\(' 'Shortcut enqueue gate missing'
Assert-Text $ability 'private\s+drain\s*\(' 'Single-flight drain missing'
Assert-Text $ability 'if\s*\(this\.running\s*\|\|' 'Single-flight running guard missing'
Assert-Text $ability 'if\s*\(this\.pendingMode\.length\s*>\s*0\)' 'Deferred click drain missing'
Assert-Text $entry 'onCreate\s*\(' 'EntryAbility onCreate missing'
Assert-Text $entry 'onNewWant\s*\(' 'EntryAbility onNewWant missing'
Assert-Text $app '"bundleName"\s*:\s*"com\.tunbox\.client"' 'App bundleName mismatch'
Assert-Text $app '"versionName"\s*:\s*"5\.2"' 'versionName is not 5.2'
Assert-Text $app '"versionCode"\s*:\s*50200' 'versionCode is not 50200'

function Invoke-Model([string]$State, [string[]]$Events) {
  $running = $false
  $pending = 0
  $executed = 0
  foreach ($event in $Events) {
    if ($event -eq 'click') {
      $pending = 1
      if (-not $running) {
        $running = $true
        $pending = 0
        $executed++
      }
    } elseif ($event -eq 'complete') {
      $running = $false
      if ($pending -gt 0) {
        $pending = 0
        $running = $true
        $executed++
      }
    } elseif ($event -eq 'foreground') {
      if (-not $running -and $pending -gt 0) {
        $pending = 0
        $running = $true
        $executed++
      }
    }
  }
  if ($executed -lt 1) { throw "$State did not execute shortcut action" }
  return $executed
}

$cold = Invoke-Model 'cold-onCreate' @('click')
$stack = Invoke-Model 'task-stack-onNewWant' @('click')
$foreground = Invoke-Model 'foreground-repeat' @('click', 'click', 'complete')
$background = Invoke-Model 'background-resume' @('click', 'foreground')
if ($foreground -ne 2) { throw 'Foreground repeat click was swallowed instead of deferred' }

Write-Output "PASS cold-onCreate executions=$cold"
Write-Output "PASS task-stack-onNewWant executions=$stack"
Write-Output "PASS foreground-repeat executions=$foreground"
Write-Output "PASS background-resume executions=$background"
Write-Output 'PASS shortcut wiring, singleton lifecycle, version and bundle assertions'
