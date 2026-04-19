param(
    [int[]]$HidppDevices = @(3, 4),
    [int]$TargetChannel = 2,
    [string]$HidppPath = '',
    [int]$HidppTimeoutMs = 1500,
    [int]$DelayAfterEachDeviceMs = 250,
    [string]$SwitchCommand = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\writeValueToDisplay.exe'),
    [string[]]$SwitchArguments = @('0', '0xD1', '0xF4', '0x50'),
    [string]$LogPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\switch-to-mac-now.log'),
    [switch]$DisplayFirst,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Initialize-Hidpp {
    $probePath = Join-Path $PSScriptRoot 'logi-hidpp-probe.ps1'
    if (-not (Test-Path -LiteralPath $probePath)) {
        throw "找不到 HID++ 探测脚本: $probePath"
    }

    . $probePath -Library

    if (-not $HidppPath) {
        $candidate = [LogiHidppProbe]::Enumerate() |
            Where-Object {
                $_.VendorID -eq 0x046D -and
                $_.ProductID -eq 0xC548 -and
                $_.UsagePage -eq 0xFF00 -and
                $_.OutputReportByteLength -ge 20
            } |
            Select-Object -First 1

        if (-not $candidate) {
            throw '没有找到 Logitech C548 的 HID++ 长报告接口。'
        }

        $script:HidppPath = $candidate.Path
    }

    Write-Log "HID++ 路径: $HidppPath"
}

function Invoke-DisplaySwitch {
    if (-not (Test-Path -LiteralPath $SwitchCommand)) {
        Write-Log "找不到显示器切换程序: $SwitchCommand" '错误'
        return $false
    }

    if ($DryRun) {
        Write-Log "演练模式: 将会运行 `"$SwitchCommand`" $($SwitchArguments -join ' ')" '动作'
        return $true
    }

    Write-Log "正在切换显示器: `"$SwitchCommand`" $($SwitchArguments -join ' ')" '动作'
    try {
        Push-Location (Split-Path -Parent $SwitchCommand)
        try {
            & $SwitchCommand @SwitchArguments
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        Write-Log "显示器切换程序退出码: $exitCode" '动作'
        return ($exitCode -eq 0)
    }
    catch {
        Write-Log "显示器切换失败: $($_.Exception.Message)" '错误'
        return $false
    }
}

function Invoke-LogiSwitch {
    $targetHostIndex = $TargetChannel - 1
    if ($targetHostIndex -lt 0) {
        throw "TargetChannel 必须大于等于 1。"
    }

    Write-Log "正在把 Logitech 设备 $($HidppDevices -join ',') 切到 $TargetChannel 号信道 (HID++ host index $targetHostIndex)"

    $allOk = $true
    foreach ($device in $HidppDevices) {
        if ($DryRun) {
            $info = [LogiHidppProbe]::HostsInfo($HidppPath, $device, $HidppTimeoutMs)
            Write-Log "演练模式: slot $device $info" '动作'
        }
        else {
            $result = [LogiHidppProbe]::ChangeHost($HidppPath, $device, $targetHostIndex, $HidppTimeoutMs)
            Write-Log "slot $device $result" '动作'
            if ($result -notlike '已发送 CHANGE_HOST*' -and $result -notlike 'sent CHANGE_HOST*') {
                $allOk = $false
            }
        }

        if ($DelayAfterEachDeviceMs -gt 0) {
            Start-Sleep -Milliseconds $DelayAfterEachDeviceMs
        }
    }

    return $allOk
}

Write-Log "手动切换开始"
Write-Log "目标信道=$TargetChannel; HID++ slots=$($HidppDevices -join ','); HID++超时=${HidppTimeoutMs}ms; 先切显示器=$DisplayFirst; 演练模式=$DryRun"
Write-Log "显示器命令: `"$SwitchCommand`" $($SwitchArguments -join ' ')"

Initialize-Hidpp

if ($DisplayFirst) {
    $displayOk = Invoke-DisplaySwitch
    $logiOk = Invoke-LogiSwitch
}
else {
    $logiOk = Invoke-LogiSwitch
    $displayOk = Invoke-DisplaySwitch
}

if ($logiOk -and $displayOk) {
    Write-Log "手动切换完成" '动作'
    exit 0
}

Write-Log "手动切换完成，但有错误: Logitech成功=$logiOk 显示器成功=$displayOk" '错误'
exit 1
