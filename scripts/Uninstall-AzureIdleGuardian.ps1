<#
.SYNOPSIS
    Removes local Scheduled Tasks, state files, and optionally deletes the Azure Logic App workflow.
#>
param(
    [string]$VmName,
    [string]$ResourceGroup,
    [string]$InstallDir = "C:\ProgramData\AzureIdleMonitor",
    [switch]$RemoveAzureResources
)

$ErrorActionPreference = "Continue"

Write-Host "==> Removing Windows Scheduled Tasks..." -ForegroundColor Cyan
Unregister-ScheduledTask -TaskName "AzureVmUserInputTracker" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "AzureVmIdleMonitor" -Confirm:$false -ErrorAction SilentlyContinue

if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "    Removed $InstallDir" -ForegroundColor Green
}

if ($RemoveAzureResources -and $VmName -and $ResourceGroup) {
    $logicAppName = "la-$VmName-shutdown-action"
    Write-Host "==> Deleting Azure Logic App '$logicAppName' in '$ResourceGroup'..." -ForegroundColor Cyan
    az resource delete --resource-group $ResourceGroup --name $logicAppName --resource-type "Microsoft.Logic/workflows"
    Write-Host "    Deleted $logicAppName" -ForegroundColor Green
}
