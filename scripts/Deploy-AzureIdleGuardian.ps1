<#
.SYNOPSIS
    Deploys the Azure VM Idle Guardian infrastructure (Bicep Logic App + RBAC) and installs the Windows Scheduled Tasks.
.EXAMPLE
    .\scripts\Deploy-AzureIdleGuardian.ps1 -VmName "malotian-vm-win-11" -ResourceGroup "malotian-resource-group-canada-central" -NtfyTopic "my-secret-topic"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$NtfyTopic = ("$VmName-idle-" + [guid]::NewGuid().ToString("N").Substring(0, 6)),

    [Parameter(Mandatory = $false)]
    [int]$IdleThresholdMinutes = 60,

    [Parameter(Mandatory = $false)]
    [double]$MaxAvgCpuPercent = 5.0,

    [Parameter(Mandatory = $false)]
    [double]$MaxAvgNetKbps = 100.0,

    [Parameter(Mandatory = $false)]
    [string]$InstallDir = "C:\ProgramData\AzureIdleMonitor"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
} else {
    $SubscriptionId = (az account show --query "id" -o tsv).Trim()
}

Write-Host "==> Deploying Azure Logic App & Managed Identity RBAC via Bicep..." -ForegroundColor Cyan
$deploymentJson = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $RepoRoot "infra\main.bicep") `
    --parameters vmName=$VmName ntfyTopic=$NtfyTopic `
    --query "properties.outputs" -o json | ConvertFrom-Json

$CallbackUrl = $deploymentJson.callbackUrl.value
Write-Host "    Logic App deployed: $($deploymentJson.logicAppName.value)" -ForegroundColor Green

Write-Host "==> Staging local monitor scripts to $InstallDir..." -ForegroundColor Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Copy-Item -Path (Join-Path $RepoRoot "src\Update-UserInput.ps1") -Destination $InstallDir -Force
Copy-Item -Path (Join-Path $RepoRoot "src\Monitor-VmIdle.ps1") -Destination $InstallDir -Force
Copy-Item -Path (Join-Path $RepoRoot "src\RunHidden.vbs") -Destination $InstallDir -Force

$configPayload = @{
    vmName                      = $VmName
    resourceGroup               = $ResourceGroup
    subscriptionId              = $SubscriptionId
    idleThresholdMinutes        = $IdleThresholdMinutes
    maxAvgCpuPercent            = $MaxAvgCpuPercent
    maxAvgNetKbps               = $MaxAvgNetKbps
    notificationCooldownMinutes = $IdleThresholdMinutes
    ntfyServerUrl               = "https://ntfy.sh"
    ntfyTopic                   = $NtfyTopic
    shutdownCallbackUrl         = $CallbackUrl
}
$configPayload | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $InstallDir "config.json") -Encoding UTF8 -Force

Write-Host "==> Registering Windows Scheduled Tasks..." -ForegroundColor Cyan
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$registerScript = @"
`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew

`$actionInput = New-ScheduledTaskAction -Execute "wscript.exe" -Argument '"$InstallDir\RunHidden.vbs" "$InstallDir\Update-UserInput.ps1"'
`$triggerInput = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
`$principalInput = New-ScheduledTaskPrincipal -UserId "$currentUser" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "AzureVmUserInputTracker" -Action `$actionInput -Trigger `$triggerInput -Principal `$principalInput -Settings `$settings -Force | Out-Null

`$actionMonitor = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "$InstallDir\Monitor-VmIdle.ps1"'
`$triggerMonitor = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
`$principalMonitor = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "AzureVmIdleMonitor" -Action `$actionMonitor -Trigger `$triggerMonitor -Principal `$principalMonitor -Settings `$settings -Force | Out-Null
"@

$registerScriptPath = Join-Path $InstallDir "Register-Tasks.ps1"
$registerScript | Set-Content -Path $registerScriptPath -Encoding UTF8 -Force

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    & $registerScriptPath
} else {
    az vm run-command invoke --resource-group $ResourceGroup --name $VmName --command-id RunPowerShellScript --scripts "@$registerScriptPath" | Out-Null
}

Write-Host ""
Write-Host "Deployment Complete!" -ForegroundColor Green
Write-Host "Subscribe in the ntfy mobile app to topic: $NtfyTopic" -ForegroundColor Yellow
