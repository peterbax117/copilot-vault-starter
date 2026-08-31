' Invoke-VaultSyncHidden.vbs -- truly hidden launcher for the vault sync task.
'
' powershell.exe -WindowStyle Hidden still creates a console window for a moment
' before the style is applied, so the sync task flashes a black window on screen
' every time it runs. WScript.Shell.Run with windowStyle 0 creates the process
' with no window at all, so there is no flash.
'
' Vault-agnostic on purpose: the vault root is passed as the first argument, so
' this file stays byte-identical across every vault (core/ contract).
'
' Usage:
'   wscript.exe "<root>\core\scripts\Invoke-VaultSyncHidden.vbs" "<root>"

Option Explicit

Dim objShell, root, cmd

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

root = WScript.Arguments(0)

Set objShell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
      root & "\core\scripts\Sync-Vault.ps1"" -VaultRoot """ & root & """ -Quiet"

' 0 = no window, True = wait so the task reports real completion.
objShell.Run cmd, 0, True
