param(
    [string]$TaskName = 'SwitchScreenToMacMonitor'
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'monitor-switch-to-mac.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "找不到自动监控脚本: $scriptPath"
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description '监控 Logitech 键盘和鼠标离线状态，然后把显示器切换到 Mac Type-C。' `
    -Force | Out-Null

Write-Host "已安装开机/登录自动监控任务: $TaskName"
Write-Host "如需删除: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
