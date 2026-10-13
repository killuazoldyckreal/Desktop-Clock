Set WshShell = CreateObject("WScript.Shell")
Set FSO = CreateObject("Scripting.FileSystemObject")

scriptPath = FSO.BuildPath(FSO.GetParentFolderName(WScript.ScriptFullName), "Neon-Clock.ps1")

WshShell.Environment("Process")("NEON_HIDDEN") = "1"
WshShell.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False