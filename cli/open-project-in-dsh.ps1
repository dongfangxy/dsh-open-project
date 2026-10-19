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
  # Suppress failure dialogs. Use for scripted or unattended runs; a switch rather
  # than a boolean so `-File` invocation does not have to parse "true"/"false".
  [switch]$Silent
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

# Win32 entry points for bringing the app forward. A background process is not
# allowed to take the foreground on its own (Windows' foreground lock), so the
# helper below attaches to the current foreground thread first.
if (-not ('DshWindowFocus' -as [type])) {
  Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshWindowFocus {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr e);
}
'@
}

function Show-Balloon {
  param([string]$Message, [string]$Icon = 'Info')

  # [System.Windows.MessageBox] is not resolvable until WPF is loaded, in both
  # Windows PowerShell 5.1 and PowerShell 7. Referencing it without the Add-Type
  # threw, and the empty catch turned every failure dialog into silence.
  try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    [void][System.Windows.MessageBox]::Show($Message, 'DeepSeek Harness', 'OK', $Icon)
    return
  } catch { }

  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'DeepSeek Harness', 'OK', [System.Windows.Forms.MessageBoxIcon]::Warning)
    return
  } catch { }
}

<#
Bring the DeepSeek Harness window to the front, restoring it when minimized.

Registering a project is invisible on its own: when the app is already running
behind other windows, or hidden in the tray, nothing on screen changes and the
click looks like it did nothing. This is what makes the action's result visible.

@returns nothing; failures are swallowed because focus is best-effort.
#>
function Show-DshWindow {
  try {
    $proc = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($null -eq $proc) { return }

    $handle = $proc.MainWindowHandle
    if ([DshWindowFocus]::IsIconic($handle)) {
      [void][DshWindowFocus]::ShowWindow($handle, 9)   # SW_RESTORE
      Start-Sleep -Milliseconds 200
    }
    if ([DshWindowFocus]::GetForegroundWindow() -eq $handle) { return }

    # Attaching to the foreground thread is what makes SetForegroundWindow
    # honoured from a background process.
    $foreground = [DshWindowFocus]::GetForegroundWindow()
    $foregroundThread = [DshWindowFocus]::GetWindowThreadProcessId($foreground, [ref]([uint32]$null))
    $ownThread = [DshWindowFocus]::GetCurrentThreadId()
    [void][DshWindowFocus]::AttachThreadInput($ownThread, $foregroundThread, $true)
    [void][DshWindowFocus]::SetForegroundWindow($handle)
    [void][DshWindowFocus]::AttachThreadInput($ownThread, $foregroundThread, $false)
    Start-Sleep -Milliseconds 250

    if ([DshWindowFocus]::GetForegroundWindow() -ne $handle) {
      # Fallback: an Alt keypress clears the foreground lock outright.
      [DshWindowFocus]::keybd_event(0x12, 0x38, 0, [UIntPtr]::Zero)
      [DshWindowFocus]::keybd_event(0x12, 0x38, 2, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 100
      [void][DshWindowFocus]::SetForegroundWindow($handle)
    }
  } catch { }
}

function Show-Toast {
  param([string]$Line1, [string]$Line2)
  # Windows PowerShell 5.1 can project WinRT, so it shows a real toast.
  # PowerShell 7 on .NET cannot project WinRT at all, so fall back to a tray
  # balloon rather than losing the feedback silently.
  try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $nodes = $template.GetElementsByTagName('text')
    $nodes.Item(0).AppendChild($template.CreateTextNode($Line1)) > $null
    $nodes.Item(1).AppendChild($template.CreateTextNode($Line2)) > $null
    $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('DeepSeek Harness').Show($toast)
    return
  } catch { }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $balloon = New-Object System.Windows.Forms.NotifyIcon
    $balloon.Icon = [System.Drawing.SystemIcons]::Information
    $balloon.Visible = $true
    $balloon.ShowBalloonTip(4000, $Line1, $Line2, [System.Windows.Forms.ToolTipIcon]::Info)
    # Keep the process alive while the balloon is up; this window is hidden.
    Start-Sleep -Milliseconds 4500
    $balloon.Visible = $false
    $balloon.Dispose()
  } catch { }
}

function Test-DshRunning {
  return [bool](Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
}

# One line per run, appended, so a click that "did nothing" can be explained
# afterwards instead of guessed at. The directory is per-user and needs no rights.
$script:DshLogPath = Join-Path $env:LOCALAPPDATA 'dsh-open-project\last-run.log'

function Write-DshLog {
  param([string]$Message)
  try {
    $dir = Split-Path -Parent $script:DshLogPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $script:DshLogPath -Value $line -Encoding UTF8
  } catch { }
}

# DSH_WEB_URL is injected into DSH sessions; a process started from the registry
# does not have it, so fall back to the host process's listening ports. Several
# DeepSeek processes can listen on loopback, so return every candidate and let
# the caller try each one: the route itself is the reliable test.
function Get-DshBaseUrls {
  $urls = @()
  if ($env:DSH_WEB_URL -match '^http://127\.0\.0\.1:\d+$') { $urls += $env:DSH_WEB_URL }
  foreach ($proc in (Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
    foreach ($conn in (Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue)) {
      if ($conn.LocalAddress -eq '127.0.0.1' -and $conn.LocalPort -gt 1024) {
        $urls += "http://127.0.0.1:$($conn.LocalPort)"
      }
    }
  }
  $urls = @($urls | Select-Object -Unique)
  if ($urls.Count -eq 0) { $urls = @($DefaultBase) }
  return $urls
}

# --- 1) the target folder must really exist --------------------------------
try {
  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
} catch {
  if (-not $Silent) { Show-Balloon "Folder does not exist:`n$Path" 'Warning' }
  exit 2
}
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
  if (-not $Silent) { Show-Balloon "Not a folder:`n$resolved" 'Warning' }
  exit 2
}

# --- 2) start the app when it is not running -------------------------------
$coldStart = -not (Test-DshRunning)
$appExe = $null
if ($coldStart) {
  $appExe = Find-DshAppExecutable
  if ($null -eq $appExe) {
    Write-DshLog "no executable found; folder=$resolved"
    if (-not $Silent) {
      Show-Balloon ("DeepSeek Harness is not running and its executable was not found.`n`n" +
        "Set DSH_DESKTOP_APP_EXE to the full path of 'DeepSeek Harness.exe', then retry.") 'Warning'
    }
    exit 3
  }
  Start-Process -FilePath $appExe | Out-Null
  Show-Toast 'Starting DeepSeek Harness' "Will open: $([System.IO.Path]::GetFileName($resolved))"

  # Wait for the window itself first, so the app is visible while the host
  # finishes starting, and its window is not left behind other windows.
  $windowDeadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $windowDeadline) {
    Start-Sleep -Milliseconds 700
    $shown = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($shown) { Show-DshWindow; break }
  }
}

# --- 3) ask the Host to register the project (wait, but not forever) -------
$waitSeconds = if ($coldStart) { $WaitColdStartSeconds } else { $WaitRunningSeconds }
$deadline = (Get-Date).AddSeconds($waitSeconds)
$body = @{ path = $resolved } | ConvertTo-Json -Compress
$response = $null
$lastDetail = ''
$base = ''
$basesTried = @()

while ((Get-Date) -lt $deadline) {
  # Several DeepSeek processes may listen on loopback; try every candidate
  # rather than trusting the first one, and let the route itself decide.
  foreach ($candidate in (Get-DshBaseUrls)) {
    $basesTried += $candidate
    try {
      $response = Invoke-RestMethod -Method Post -Uri "$candidate/.dsh-open-project" `
        -Headers @{ 'x-dsh-open-project' = '1' } `
        -ContentType 'application/json; charset=utf-8' `
        -Body $body -TimeoutSec 12
      $base = $candidate
      break
    } catch {
      $status = $null
      try { $status = [int]$_.Exception.Response.StatusCode } catch { }
      $lastDetail = $_.Exception.Message
      $base = $candidate
      # Only the route's own validation errors are terminal: 400/422 mean the
      # request itself is wrong. Everything else (connection refused while the
      # app boots, 404 from a listener that is not the host) is worth retrying.
      if ($null -ne $status -and ($status -eq 400 -or $status -eq 422)) { break }
    }
  }
  if ($null -ne $response) { break }
  if ($lastDetail -and ($lastDetail -match 'Bad Request|Unprocessable')) { break }
  Start-Sleep -Milliseconds 1200
}

if ($null -eq $response) {
  Write-DshLog "failed; folder=$resolved; coldStart=$coldStart; lastEndpoint=$base; detail=$lastDetail"
  if (-not $Silent) {
    Show-Balloon (
      "Could not open this project.`n`nFolder: $resolved`nEndpoint: $base`nReason: $lastDetail`n`n" +
      "If the app was just starting, give it a moment and try again.`n" +
      "Log: $script:DshLogPath") 'Warning'
  }
  exit 1
}

if ($response.ok -ne $true) {
  Write-DshLog "refused; folder=$resolved; error=$($response.error)"
  if (-not $Silent) { Show-Balloon "DSH refused the registration:`n$($response.error)" 'Warning' }
  exit 1
}

# --- 4) success: make it visible --------------------------------------------
# Focus first: the notification is easy to miss, and a registered project alone
# leaves the screen unchanged, which reads as "the click did nothing".
Show-DshWindow
Write-DshLog "ok; folder=$resolved; coldStart=$coldStart; exe=$appExe; endpoint=$base; created=$($response.created); title=$($response.title)"
Show-Toast $(if ($response.created) { 'Opened as a DSH project' } else { 'Already a DSH project' }) ([string]$response.title)

exit 0
