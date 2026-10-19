# ============================================================
#  app-path.ps1 — locate the DeepSeek Harness desktop executable.
#
#  Dot-source this from the other scripts:
#      . "$PSScriptRoot\app-path.ps1"
#      $exe = Find-DshAppExecutable
#
#  Resolution order (first hit wins):
#    1. $env:DSH_DESKTOP_APP_EXE          — explicit override, for unusual setups
#    2. the image path of a running instance
#    3. the dsh:// protocol handler        — written by the installer, so it finds
#                                            non-standard install directories that
#                                            the default locations below miss
#    4. the default per-user install location (electron-builder default)
#    5. the per-machine install locations
#  Returns $null when nothing is found; callers degrade instead of failing, so a
#  missing executable never blocks registering a project.
# ============================================================

<#
Read the executable path out of the dsh:// protocol handler command line.

The installer registers it as `"<install dir>\DeepSeek Harness.exe" "%1"`, which
is the only machine-wide record of where the app actually lives; the default
install locations do not cover a custom directory such as D:\Programs\...

@returns The executable path, or $null when the protocol is not registered.
#>
function Get-DshAppFromProtocol {
  $keys = @(
    'HKCU:\Software\Classes\dsh\shell\open\command',
    'HKLM:\Software\Classes\dsh\shell\open\command'
  )
  foreach ($key in $keys) {
    $command = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'(default)'
    if ([string]::IsNullOrWhiteSpace($command)) { continue }
    # Quoted path first: handles spaces and any trailing arguments.
    if ($command -match '^\s*"([^"]+)"') {
      $candidate = $Matches[1]
    } else {
      $candidate = ($command -split '\s+')[0]
    }
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}

function Find-DshAppExecutable {
  if ($env:DSH_DESKTOP_APP_EXE -and (Test-Path -LiteralPath $env:DSH_DESKTOP_APP_EXE)) {
    return $env:DSH_DESKTOP_APP_EXE
  }

  $running = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path } | Select-Object -First 1
  if ($running) { return $running.Path }

  $fromProtocol = Get-DshAppFromProtocol
  if ($fromProtocol) { return $fromProtocol }

  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }

  return $null
}
