<#
.SYNOPSIS
    Evaluates rolling 1-hour VM idleness and dispatches a silent-action mobile push notification via ntfy.
.DESCRIPTION
    Checks four idle conditions over the configured rolling window (default: 60 minutes):
    1. Mouse movement & keyboard input (Win32 GetLastInputInfo from active session)
    2. Interactive RDP / Console session state (quser)
    3. Rolling average CPU percentage (default <= 5.0%)
    4. Rolling average network throughput (default <= 100.0 KB/s)
#>
param(
    [string]$StateDir = "C:\ProgramData\AzureIdleMonitor",
    [string]$ConfigPath = "C:\ProgramData\AzureIdleMonitor\config.json",
    [switch]$SendTestNotification
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found at '$ConfigPath'. Run scripts\Deploy-AzureIdleGuardian.ps1 first."
}

$cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$VmName                      = if ($cfg.vmName) { $cfg.vmName } else { $env:COMPUTERNAME }
$IdleThresholdMinutes        = if ($cfg.idleThresholdMinutes) { [int]$cfg.idleThresholdMinutes } else { 60 }
$MaxAvgCpuPercent            = if ($cfg.maxAvgCpuPercent) { [double]$cfg.maxAvgCpuPercent } else { 5.0 }
$MaxAvgNetKbps               = if ($cfg.maxAvgNetKbps) { [double]$cfg.maxAvgNetKbps } else { 100.0 }
$NotificationCooldownMinutes = if ($cfg.notificationCooldownMinutes) { [int]$cfg.notificationCooldownMinutes } else { 60 }
$NtfyServerUrl               = if ($cfg.ntfyServerUrl) { $cfg.ntfyServerUrl.TrimEnd('/') } else { "https://ntfy.sh" }
$NtfyTopic                   = $cfg.ntfyTopic
$ShutdownCallbackUrl         = $cfg.shutdownCallbackUrl

$ApproveUrl = "$ShutdownCallbackUrl&decision=approve"
$SkipUrl    = "$ShutdownCallbackUrl&decision=skip"

$HistoryFile   = Join-Path $StateDir "metrics_history.json"
$LastInputFile = Join-Path $StateDir "last_input.json"
$StateFile     = Join-Path $StateDir "monitor_state.json"
$LogFile       = Join-Path $StateDir "monitor.log"

function Write-MonitorLog([string]$Message) {
    $line = "[{0}] {1}" -f ([DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Send-NtfyIdleAlert {
    param(
        [string]$Title,
        [string]$MessageBody
    )
    $ntfyPayload = @{
        topic    = $NtfyTopic
        title    = $Title
        message  = $MessageBody
        priority = 4
        tags     = @("computer")
        actions  = @(
            @{
                action = "http"
                label  = "Shut Down"
                method = "GET"
                url    = $ApproveUrl
                clear  = $true
            },
            @{
                action = "http"
                label  = "Skip (1h)"
                method = "GET"
                url    = $SkipUrl
                clear  = $true
            }
        )
    }
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes(($ntfyPayload | ConvertTo-Json -Depth 5))
    Invoke-RestMethod -Method POST -Uri $NtfyServerUrl -ContentType "application/json; charset=utf-8" -Body $jsonBytes
}

$nowUtc = [DateTime]::UtcNow

# Refresh Win32 GetLastInputInfo if running interactively
$UpdateInputScript = Join-Path $StateDir "Update-UserInput.ps1"
if (Test-Path $UpdateInputScript) {
    try { & $UpdateInputScript -StateDir $StateDir } catch {}
}

# 1. Sample CPU (%) and Network (KB/s)
try {
    $cpuSample = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 2 -MaxSamples 1).CounterSamples[0].CookedValue
    $cpuPercent = [math]::Round([double]$cpuSample, 1)
} catch {
    $cpuPercent = 0.0
}

try {
    $netSamples = (Get-Counter '\Network Interface(*)\Bytes Total/sec' -SampleInterval 2 -MaxSamples 1).CounterSamples
    $totalBytesPerSec = ($netSamples | Measure-Object -Property CookedValue -Sum).Sum
    $netKbps = [math]::Round(($totalBytesPerSec / 1024.0), 1)
} catch {
    $netKbps = 0.0
}

# 2. Update rolling metrics window
$history = @()
if (Test-Path $HistoryFile) {
    try {
        $raw = Get-Content -Path $HistoryFile -Raw | ConvertFrom-Json
        if ($raw) { $history = @($raw) }
    } catch {
        $history = @()
    }
}

$cutoffUtc = $nowUtc.AddMinutes(-1 * $IdleThresholdMinutes)
$history = @($history | Where-Object { ([DateTime]::Parse($_.timestampUtc).ToUniversalTime()) -ge $cutoffUtc })
$history += [PSCustomObject]@{
    timestampUtc = $nowUtc.ToString("o")
    cpuPercent   = $cpuPercent
    netKbps      = $netKbps
}
$history | ConvertTo-Json -Depth 4 | Set-Content -Path $HistoryFile -Encoding UTF8 -Force

$avgCpu = [math]::Round((($history | Measure-Object -Property cpuPercent -Average).Average), 1)
$avgNet = [math]::Round((($history | Measure-Object -Property netKbps -Average).Average), 1)

# 3. Evaluate user input idle minutes
$os = Get-CimInstance Win32_OperatingSystem
$uptimeMinutes = [math]::Round(($nowUtc - $os.LastBootUpTime.ToUniversalTime()).TotalMinutes, 1)

$inputIdleMinutes = $uptimeMinutes
if (Test-Path $LastInputFile) {
    try {
        $inputData = Get-Content -Path $LastInputFile -Raw | ConvertFrom-Json
        $lastInputUtc = [DateTime]::Parse($inputData.lastInputAtUtc).ToUniversalTime()
        $inputIdleMinutes = [math]::Round(($nowUtc - $lastInputUtc).TotalMinutes, 1)
    } catch {}
}

# 4. Dispatch test notification or evaluate 1-hour idle threshold
if ($SendTestNotification) {
    $title = "$VmName (Idle Check)"
    $msg   = "Idle ${inputIdleMinutes}m | CPU ${avgCpu}% | Net ${avgNet} KB/s"
    $resp  = Send-NtfyIdleAlert -Title $title -MessageBody $msg
    Write-MonitorLog "Sent TEST push notification to ntfy topic '$NtfyTopic' (id: $($resp.id))"
    Write-Output $resp
    exit 0
}

$oldestSampleMinutes = [math]::Round(($nowUtc - ([DateTime]::Parse($history[0].timestampUtc).ToUniversalTime())).TotalMinutes, 1)
$isInputIdle   = ($inputIdleMinutes -ge $IdleThresholdMinutes)
$isUptimeReady = ($uptimeMinutes -ge $IdleThresholdMinutes) -and ($oldestSampleMinutes -ge ($IdleThresholdMinutes - 6))
$isCpuIdle     = ($avgCpu -le $MaxAvgCpuPercent)
$isNetIdle     = ($avgNet -le $MaxAvgNetKbps)

Write-MonitorLog "Check: InputIdle=${inputIdleMinutes}m (Req>=${IdleThresholdMinutes}m), Uptime=${uptimeMinutes}m, HistorySpan=${oldestSampleMinutes}m, AvgCPU=${avgCpu}% (Max=${MaxAvgCpuPercent}%), AvgNet=${avgNet}KB/s (Max=${MaxAvgNetKbps}KB/s)"

if ($isInputIdle -and $isUptimeReady -and $isCpuIdle -and $isNetIdle) {
    $canNotify = $true
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
            if ($state.lastNotifiedAtUtc) {
                $lastNotified = [DateTime]::Parse($state.lastNotifiedAtUtc).ToUniversalTime()
                if (($nowUtc - $lastNotified).TotalMinutes -lt $NotificationCooldownMinutes) {
                    $canNotify = $false
                    Write-MonitorLog "VM is idle, but notification is within ${NotificationCooldownMinutes}m cooldown/snooze window."
                }
            }
        } catch {}
    }

    if ($canNotify) {
        $idleFloor = [math]::Floor($inputIdleMinutes)
        $title = "$VmName (Idle ${idleFloor}m)"
        $msg   = "No input | CPU ${avgCpu}% | Net ${avgNet} KB/s"
        $resp  = Send-NtfyIdleAlert -Title $title -MessageBody $msg
        @{
            lastNotifiedAtUtc = $nowUtc.ToString("o")
            idleMinutes       = $inputIdleMinutes
            avgCpuPercent     = $avgCpu
            avgNetKbps        = $avgNet
            ntfyMessageId     = $resp.id
        } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 -Force
        Write-MonitorLog "IDLE THRESHOLD MET! Sent mobile push notification to ntfy topic '$NtfyTopic' (id: $($resp.id))."
    }
}
