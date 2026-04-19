Set oFso   = CreateObject("Scripting.FileSystemObject")
Set oShell = CreateObject("WScript.Shell")
sRoot = oFso.GetParentFolderName(WScript.ScriptFullName)
sPs1  = sRoot & "\scripts\switch-to-mac-now.ps1"
oShell.CurrentDirectory = sRoot
oShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & sPs1 & """", 0, False
