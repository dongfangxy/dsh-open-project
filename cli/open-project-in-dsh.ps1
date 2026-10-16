# ============================================================
#  open-project-in-dsh.ps1 — the action behind the Explorer context-menu entry.
#
#  It does four things:
#    1. confirms the target folder exists;
#    2. finds the DSH web port, and starts the app when it is not running;
#    3. asks the Host plugin (dsh-open-project) to register the folder as a DSH
#       project, through POST /.dsh-open-project;
#    4. reports the outcome (toast on success, dialog on failure).
#
#  Normally invoked hidden by cli\open-project-in-dsh.vbs:
#    wscript.exe //nologo open-project-in-dsh.vbs "D:\some\folder"
# ============================================================

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Path,
  # Show a dialog on failure. Turn off for scripted use.
  [bool]$ShowErrors = $true
)

$ErrorActionPreference = 'Stop'

# Shared executable discovery (override → running instance → default install dirs).
. (Join-Path $PSScriptRoot 'app-path.ps1')

$DefaultBase = 'http://127.0.0.1:19387'
# With the app already running the plugin is ready in seconds; a cold start gets
# much longer.
$WaitRunningSeconds   = 30
$WaitColdStartSeconds = 180

# --- helpers ---------------------------------------------------------------

function Show-Balloon {
  param([string]$Message, [string]$Icon = 'Info')
  try { [void][System.Windows.MessageBox]::Show($Message, 'DeepSeek Harness', 'OK', $Icon) } catch { }
}

function Show-Toast {
  param([string]$Line1, [string]$Line2)
  try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $nodes = $template.GetElementsByTagName('text')
    $nodes.Item(0).AppendChild($template.CreateTextNode($Line1)) > $null
    $nodes.Item(1).AppendChild($template.CreateTextNode($Line2)) > $null
    $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('DeepSeek Harness').Show($toast)
  } catch { }
}

function Test-DshRunning {
  return [bool](Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
}

# DSH_WEB_URL is injected into DSH sessions; a process started from the registry
# does not have it, so fall back to the host process's listening port, then to
# the desktop default. Loopback only.
function Get-DshBaseUrl {
  if ($env:DSH_WEB_URL -match '^http://127\.0\.0\.1:\d+$') { return $env:DSH_WEB_URL }
  $candidates = @()
  foreach ($proc in (Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
    foreach ($conn in (Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue)) {
      if ($conn.LocalAddress -eq '127.0.0.1' -and $conn.LocalPort -gt 1024) {
        $candidates += "http://127.0.0.1:$($conn.LocalPort)"
      }
    }
  }
  if ($candidates.Count -gt 0) { return ($candidates | Select-Object -First 1) }
  return $DefaultBase
}

# --- 1) the target folder must really exist --------------------------------
try {
  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
} catch {
  if ($ShowErrors) { Show-Balloon "Folder does not exist:`n$Path" 'Warning' }
  exit 2
}
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
  if ($ShowErrors) { Show-Balloon "Not a folder:`n$resolved" 'Warning' }
  exit 2
}

# --- 2) start the app when it is not running -------------------------------
$coldStart = -not (Test-DshRunning)
if ($coldStart) {
  $appExe = Find-DshAppExecutable
  if ($null -eq $appExe) {
    if ($ShowErrors) {
      Show-Balloon ("DeepSeek Harness is not running and its executable was not found.`n`n" +
        "Set DSH_DESKTOP_APP_EXE to the full path of 'DeepSeek Harness.exe', then retry.") 'Warning'
    }
    exit 3
  }
  Start-Process -FilePath $appExe | Out-Null
  Show-Toast 'Starting DeepSeek Harness' "Will open: $([System.IO.Path]::GetFileName($resolved))"
}

# --- 3) ask the Host to register the project (wait, but not forever) -------
$waitSeconds = if ($coldStart) { $WaitColdStartSeconds } else { $WaitRunningSeconds }
$deadline = (Get-Date).AddSeconds($waitSeconds)
$body = @{ path = $resolved } | ConvertTo-Json -Compress
$response = $null
$lastDetail = ''
$base = Get-DshBaseUrl

while ((Get-Date) -lt $deadline) {
  $base = Get-DshBaseUrl
  try {
    $response = Invoke-RestMethod -Method Post -Uri "$base/.dsh-open-project" `
      -Headers @{ 'x-dsh-open-project' = '1' } `
      -ContentType 'application/json; charset=utf-8' `
      -Body $body -TimeoutSec 12
    break
  } catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    $lastDetail = $_.Exception.Message
    # 4xx other than 403 is terminal (bad path and so on); retrying is pointless.
    if ($null -ne $status -and $status -ge 400 -and $status -lt 500 -and $status -ne 403) { break }
    Start-Sleep -Milliseconds 1200
  }
}

if ($null -eq $response) {
  if ($ShowErrors) {
    Show-Balloon (
      "Could not open this project.`n`nFolder: $resolved`nEndpoint: $base`nReason: $lastDetail`n`n" +
      'If the app just started, wait for its window and try again.') 'Warning'
  }
  exit 1
}

if ($response.ok -ne $true) {
  if ($ShowErrors) { Show-Balloon "DSH refused the registration:`n$($response.error)" 'Warning' }
  exit 1
}

# --- 4) success feedback ---------------------------------------------------
Show-Toast $(if ($response.created) { 'Opened as a DSH project' } else { 'Already a DSH project' }) ([string]$response.title)

exit 0
