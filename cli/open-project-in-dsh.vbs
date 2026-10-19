' ============================================================
'  open-project-in-dsh.vbs - launch the right-click action with
'  NO visible console window.
'
'  Calling PowerShell straight from the registry flashes a console
'  window (and a hung script would keep it on screen). This wrapper
'  runs it hidden through wscript instead.
'
'  Called by the registry entry:
'    wscript.exe //nologo open-project-in-dsh.vbs "D:\some\folder"
'
'  Interpreter: PowerShell 7 when installed, otherwise the Windows
'  PowerShell 5.1 that ships with Windows 10/11. Both run the .ps1,
'  so neither is a prerequisite.
'
'  NOTE: keep this file pure ASCII - the VBScript engine reads it as
'  ANSI, so a UTF-8 BOM or non-ASCII comment breaks parsing.
' ============================================================

Option Explicit

Dim shell, fso, target, scriptPath, quote, command, psExe, candidate

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count < 1 Then
  WScript.Quit 2
End If

target = WScript.Arguments(0)
scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "open-project-in-dsh.ps1")

If Not fso.FileExists(scriptPath) Then
  WScript.Quit 2
End If

quote = Chr(34)

' Prefer PowerShell 7 (faster startup); fall back to the bundled 5.1.
psExe = "pwsh.exe"
candidate = shell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe")
If fso.FileExists(candidate) Then
  psExe = quote & candidate & quote
Else
  candidate = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
  If fso.FileExists(candidate) Then
    psExe = quote & candidate & quote
  End If
End If

' 0 = hidden window, False = do not wait; PowerShell finishes on its own.
command = psExe & " -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & quote & scriptPath & quote & " -Path " & quote & target & quote

shell.Run command, 0, False
WScript.Quit 0
