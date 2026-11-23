' Magpie public API - hidden launcher
'
' Runs run.ps1 with no visible window. Started by control.ps1 (start/restart);
' a scheduled task may also launch it directly.
' Kept separate so control.ps1 has no long quoted command line.

Option Explicit

Dim shell, fso, here, script, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\run.ps1"

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """"

' 0 = hidden window, False = do not wait for it to finish
shell.Run cmd, 0, False
