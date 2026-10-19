# ============================================================
#  app-path.ps1 — locate the DeepSeek Harness desktop executable.
#
#  Dot-source this from the other scripts:
#      . "$PSScriptRoot\app-path.ps1"
#      $exe = Find-DshAppExecutable
#
#  Resolution order (first hit wins):
#    1. $env:DSH_DESKTOP_APP_EXE          — explicit override, for unusual installs
#    2. the image path of a running instance
#    3. the default per-user install location (electron-builder default)
#    4. the per-machine install locations
#  Returns $null when nothing is found; callers degrade instead of failing, so a
#  missing executable never blocks registering a project.
# ============================================================

function Find-DshAppExecutable {
  if ($env:DSH_DESKTOP_APP_EXE -and (Test-Path -LiteralPath $env:DSH_DESKTOP_APP_EXE)) {
    return $env:DSH_DESKTOP_APP_EXE
  }

  $running = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path } | Select-Object -First 1
  if ($running) { return $running.Path }

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
