' ============================================================
'  open-project-in-dsh.vbs - launch the right-click action with
'  NO visible console window.
'
'  Calling pwsh.exe straight from the registry flashes a console
'  window (and a hung script would keep it on screen). This wrapper
'  runs PowerShell hidden through wscript instead.
'
'  Called by the registry entry:
'    wscript.exe //nologo open-project-in-dsh.vbs "D:\some\folder"
'
'  NOTE: keep this file pure ASCII - the VBScript engine reads it as
'  ANSI, so a UTF-8 BOM or non-ASCII comment breaks parsing.
' ============================================================

Option Explicit

Dim shell, fso, target, scriptPath, quote, command

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

' 0 = hidden window, False = do not wait; PowerShell finishes on its own.
command = "pwsh.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & quote & scriptPath & quote & " -Path " & quote & target & quote

shell.Run command, 0, False
WScript.Quit 0