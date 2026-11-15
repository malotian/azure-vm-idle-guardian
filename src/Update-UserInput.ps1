<#
.SYNOPSIS
    Captures the exact Win32 mouse movement and keyboard input idle duration in the active user session.
.DESCRIPTION
    Calls user32.dll!GetLastInputInfo() and writes the last user input UTC timestamp to last_input.json.
    Designed to run every 1 minute via Task Scheduler under the interactive user's session.
#>
param(
    [string]$StateDir = "C:\ProgramData\AzureIdleMonitor"
)

$ErrorActionPreference = "SilentlyContinue"
if ($env:USERNAME -eq "SYSTEM" -or $env:USERNAME -like "*$" -or [Environment]::UserInteractive -eq $false) {
    exit 0
}

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Win32Input {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();

    public static uint GetIdleMilliseconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) {
            return 0;
        }
        return unchecked(GetTickCount() - lii.dwTime);
    }
}
"@

$idleMs = [Win32Input]::GetIdleMilliseconds()
$nowUtc = [DateTime]::UtcNow
$lastInputUtc = $nowUtc.AddMilliseconds(-1 * [double]$idleMs)

$payload = @{
    userName       = $env:USERNAME
    updatedAtUtc   = $nowUtc.ToString("o")
    lastInputAtUtc = $lastInputUtc.ToString("o")
    idleSeconds    = [math]::Round($idleMs / 1000.0, 1)
}

$payload | ConvertTo-Json | Set-Content -Path (Join-Path $StateDir "last_input.json") -Encoding UTF8 -Force
