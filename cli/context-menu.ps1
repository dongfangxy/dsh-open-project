# ============================================================
#  context-menu.ps1 — add or remove the Explorer folder context-menu entry
#  "Open in DeepSeek Harness" (用 DeepSeek Harness 打开).
#
#  Writes to HKCU only: no administrator rights, and fully reversible.
#
#  Usage (either interpreter; Windows PowerShell 5.1 ships with Windows,
#  PowerShell 7 starts faster when installed):
#    powershell -NoProfile -ExecutionPolicy Bypass -File context-menu.ps1 -Action enable
#    powershell -NoProfile -ExecutionPolicy Bypass -File context-menu.ps1 -Action disable
#    powershell -NoProfile -ExecutionPolicy Bypass -File context-menu.ps1 -Action status
#    powershell -NoProfile -ExecutionPolicy Bypass -File context-menu.ps1 -Action status -Json
# ============================================================

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable', 'status')][string]$Action,
  # Menu label. Defaults to Chinese; pass "Open in DeepSeek Harness" for English.
  [string]$Title = '用 DeepSeek Harness 打开',
  # status as one JSON line, for the Host plugin (avoids cross-process text encoding).
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

# --- Locations -------------------------------------------------------------
$pluginRoot = Split-Path -Parent $PSScriptRoot
$vbs        = Join-Path $pluginRoot 'cli\open-project-in-dsh.vbs'
$ps1        = Join-Path $pluginRoot 'cli\open-project-in-dsh.ps1'

# Shared executable discovery (override → running instance → default install dirs).
. (Join-Path $PSScriptRoot 'app-path.ps1')

# Registry locations for the folder context menu (the folder itself, and the
# blank area inside a folder).
$keys = @(
  'HKCU:\Software\Classes\Directory\shell\OpenInDeepSeekHarness',
  'HKCU:\Software\Classes\Directory\Background\shell\OpenInDeepSeekHarness'
)

# Command: wscript runs the VBS hidden; %V is the clicked folder (quoted, so
# paths with spaces are safe). Calling PowerShell directly would flash a console.
$commandValue = 'wscript.exe //nologo "{0}" "%V"' -f $vbs

function Get-Status {
  $present = @()
  foreach ($k in $keys) { if (Test-Path $k) { $present += $k } }
  $appExe = Find-DshAppExecutable
  [pscustomobject]@{
    Enabled = ($present.Count -eq $keys.Count)
    Present = $present
    Vbs     = $vbs
    VbsOk   = (Test-Path -LiteralPath $vbs)
    Ps1     = $ps1
    Ps1Ok   = (Test-Path -LiteralPath $ps1)
    Exe     = $appExe
    ExeOk   = ($null -ne $appExe)
  }
}

switch ($Action) {
  'status' {
    $s = Get-Status
    if ($Json) {
      [pscustomobject]@{
        ok       = $true
        enabled  = [bool]$s.Enabled
        keys     = $s.Present
        appFound = [bool]$s.ExeOk
      } | ConvertTo-Json -Compress
      break
    }
    "Enabled       : $($s.Enabled)"
    "Registry keys : $($s.Present -join '; ')"
    "Hidden entry  : $($s.Vbs)  exists=$($s.VbsOk)"
    "Launcher      : $($s.Ps1)  exists=$($s.Ps1Ok)"
    "App executable: $(if ($s.ExeOk) { $s.Exe } else { 'not found (icon omitted; the app can still launch via DSH_DESKTOP_APP_EXE)' })"
    break
  }

  'enable' {
    if (-not (Test-Path -LiteralPath $vbs)) { throw "missing VBS entry: $vbs" }
    if (-not (Test-Path -LiteralPath $ps1)) { throw "missing launcher script: $ps1" }
    $appExe = Find-DshAppExecutable
    foreach ($k in $keys) {
      New-Item -Path $k -Force | Out-Null
      New-ItemProperty -Path $k -Name '(Default)' -Value $Title -PropertyType String -Force | Out-Null
      if ($null -ne $appExe) {
        New-ItemProperty -Path $k -Name 'Icon' -Value $appExe -PropertyType String -Force | Out-Null
      } else {
        Remove-ItemProperty -Path $k -Name 'Icon' -ErrorAction SilentlyContinue
      }
      New-Item -Path "$k\command" -Force | Out-Null
      New-ItemProperty -Path "$k\command" -Name '(Default)' -Value $commandValue -PropertyType String -Force | Out-Null
    }
    "Added context-menu entry: $Title"
    "  Locations: the folder itself, and the blank area inside a folder"
    "  Command  : $commandValue"
    break
  }

  'disable' {
    foreach ($k in $keys) {
      if (Test-Path $k) {
        Remove-Item -Path $k -Recurse -Force
        "Removed: $k"
      }
    }
    'Context-menu entry removed.'
    break
  }
}
