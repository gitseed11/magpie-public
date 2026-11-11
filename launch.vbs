' Magpie public API - hidden launcher
'
' Runs run.ps1 with no visible window. Called by start.cmd.
' Kept separate so start.cmd has no long quoted command line.

Option Explicit

Dim shell, fso, here, script, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\run.ps1"

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """"

' 0 = hidden window, False = do not wait for it to finish
shell.Run cmd, 0, False
