' RunHidden.vbs
' Launches a PowerShell script completely hidden (WindowStyle 0) so no console window flashes on the desktop.
Set objShell = CreateObject("WScript.Shell")
If WScript.Arguments.Count > 0 Then
    scriptPath = WScript.Arguments(0)
    cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"
    objShell.Run cmd, 0, False
End If
