Option Explicit
Dim sh, fs, root, exe, command
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
exe = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fs.FileExists(exe) Then exe = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = """" & exe & """ -NoProfile -STA -WindowStyle Hidden -File """ & fs.BuildPath(root, "ControlCenter.ps1") & """"
sh.Run command, 0, False
