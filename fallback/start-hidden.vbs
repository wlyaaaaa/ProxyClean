' start-hidden.vbs -- launch the 7899 fallback mihomo with NO window.
' Put this file next to mihomo.exe and config.yaml inside the fallback\ folder.
Dim ws, fso, sDir
Set fso = CreateObject("Scripting.FileSystemObject")
sDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set ws = CreateObject("WScript.Shell")
ws.CurrentDirectory = sDir
' -d <dir> tells mihomo to read config.yaml from this folder. 0=hidden, False=don't wait.
ws.Run """" & sDir & "\mihomo.exe"" -d """ & sDir & """", 0, False
