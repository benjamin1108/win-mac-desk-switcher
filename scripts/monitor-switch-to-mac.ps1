param(
    [ValidateSet('Hidpp', 'Pnp')]
    [string]$DetectionMode = 'Hidpp',
    [string]$KeyboardPattern = 'HID\VID_046D&PID_C548&MI_00',
    [string]$MousePattern = 'HID\VID_046D&PID_C548&MI_01&Col01',
    [int[]]$HidppDevices = @(3, 4),
    [string]$HidppPath = '',
    [int]$HidppTimeoutMs = 1500,
    [int]$PollSeconds = 1,
    [int]$DisconnectSeconds = 2,
    [int]$CooldownSeconds = 60,
    [string]$SwitchCommand = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\writeValueToDisplay.exe'),
    [string[]]$SwitchArguments = @('0', '0xD1', '0xF4', '0x50'),
    [string]$LogPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\monitor-switch-to-mac.log'),
    [switch]$Once,
    [switch]$DryRun,
    [switch]$VerboseHidpp
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

function Format-Elapsed {
    param([double]$Seconds)

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    return ('{0:0.0}s' -f $Seconds)
}

function Get-HidppSummary {
    param(
        [object[]]$Presence,
        [hashtable]$LastOnlineAt,
        [datetime]$Now
    )

    $parts = @()
    foreach ($item in $Presence) {
        if ($item.Online) {
            $parts += "slot $($item.Device): 在线"
        }
        else {
            $offlineFor = ($Now - $LastOnlineAt[[int]$item.Device]).TotalSeconds
            $parts += "slot $($item.Device): 离线 $(Format-Elapsed $offlineFor)"
        }
    }

    return $parts -join '; '
}

function Get-ConnectedPnpText {
    $output = & pnputil /enum-devices /connected 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "pnputil 失败，退出码 $LASTEXITCODE。输出: $output"
    }

    return ($output -join "`n")
}

function Test-DevicePresent {
    param(
        [string]$ConnectedDevicesText,
        [string]$Pattern
    )

    return $ConnectedDevicesText -match [regex]::Escape($Pattern)
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

function Get-HidppPresence {
    $results = @()
    foreach ($device in $HidppDevices) {
        $result = [LogiHidppProbe]::Ping($HidppPath, $device, $HidppTimeoutMs)
        $online = $result -like 'online*'
        $results += [pscustomobject]@{
            Device = $device
            Online = $online
            Result = $result
        }
    }

    return $results
}

function Invoke-SwitchToMac {
    if (-not (Test-Path -LiteralPath $SwitchCommand)) {
        Write-Log "找不到显示器切换程序: $SwitchCommand" '错误'
        return $false
    }

    if ($DryRun) {
        Write-Log "演练模式: 将会运行 `"$SwitchCommand`" $($SwitchArguments -join ' ')" '动作'
        return $true
    }

    Write-Log "正在运行显示器切换程序: `"$SwitchCommand`" $($SwitchArguments -join ' ')" '动作'
    try {
        Push-Location -LiteralPath (Split-Path -Parent $SwitchCommand)
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

Write-Log "自动监控已启动"
Write-Log "模式=$DetectionMode; HID++ slots=$($HidppDevices -join ','); HID++超时=${HidppTimeoutMs}ms; 确认时间=${DisconnectSeconds}s; 冷却时间=${CooldownSeconds}s; 演练模式=$DryRun"
Write-Log "显示器命令: `"$SwitchCommand`" $($SwitchArguments -join ' ')"

if ($DetectionMode -eq 'Hidpp') {
    Initialize-Hidpp
}

$absentSince = $null
$lastSwitchAt = $null
$switchedForCurrentAbsence = $false
$lastStatus = $null
$lastOnlineAt = @{}
$slotOnlineState = @{}
$cooldownLogged = $false

foreach ($device in $HidppDevices) {
    $lastOnlineAt[[int]$device] = Get-Date
    $slotOnlineState[[int]$device] = $null
}

while ($true) {
    try {
        $checkStartedAt = Get-Date
        if ($DetectionMode -eq 'Hidpp') {
            $presence = @(Get-HidppPresence)
            foreach ($item in $presence) {
                $deviceId = [int]$item.Device
                $previousOnline = $slotOnlineState[$deviceId]

                if ($item.Online) {
                    $offlineForBeforeOnline = ($checkStartedAt - $lastOnlineAt[$deviceId]).TotalSeconds
                    $lastOnlineAt[$deviceId] = $checkStartedAt
                    if ($previousOnline -ne $true) {
                        if ($null -eq $previousOnline) {
                            Write-Log "slot $deviceId 在线"
                        }
                        else {
                            Write-Log "slot $deviceId 恢复在线，离线持续 $(Format-Elapsed $offlineForBeforeOnline)"
                        }
                    }
                }
                else {
                    if ($previousOnline -ne $false) {
                        Write-Log "slot $deviceId 离线 ($($item.Result))" '警告'
                    }
                    elseif ($VerboseHidpp) {
                        $offlineFor = ($checkStartedAt - $lastOnlineAt[$deviceId]).TotalSeconds
                        Write-Log "slot $deviceId 仍离线，已持续 $(Format-Elapsed $offlineFor) ($($item.Result))" '调试'
                    }
                }

                $slotOnlineState[$deviceId] = [bool]$item.Online
            }
            $offlineDevices = @(
                foreach ($device in $HidppDevices) {
                    if (($checkStartedAt - $lastOnlineAt[[int]$device]).TotalSeconds -ge $DisconnectSeconds) {
                        $device
                    }
                }
            )
            $bothMissing = $offlineDevices.Count -eq $HidppDevices.Count
            $status = ($presence | ForEach-Object { "slot$($_.Device)=$($_.Online)" }) -join ';'
            $summary = Get-HidppSummary -Presence $presence -LastOnlineAt $lastOnlineAt -Now $checkStartedAt

            if ($VerboseHidpp) {
                $raw = ($presence | ForEach-Object { "slot$($_.Device) result: $($_.Result)" }) -join '; '
                Write-Log $raw '调试'
            }
        }
        else {
            $connectedDevicesText = Get-ConnectedPnpText
            $keyboardPresent = Test-DevicePresent -ConnectedDevicesText $connectedDevicesText -Pattern $KeyboardPattern
            $mousePresent = Test-DevicePresent -ConnectedDevicesText $connectedDevicesText -Pattern $MousePattern
            $bothMissing = -not $keyboardPresent -and -not $mousePresent
            $status = "keyboardPresent=$keyboardPresent mousePresent=$mousePresent"
            $summary = "键盘在线=$keyboardPresent 鼠标在线=$mousePresent"
        }

        if ($status -ne $lastStatus) {
            Write-Log "状态: $summary" '状态'
            $lastStatus = $status
        }

        if ($bothMissing) {
            if ($null -eq $absentSince) {
                $absentSince = $checkStartedAt
                Write-Log "所有监控 slot 均离线，开始确认计时" '警告'
            }

            $missingForSeconds = ((Get-Date) - $absentSince).TotalSeconds
            $cooldownExpired = $true
            if ($null -ne $lastSwitchAt) {
                $cooldownExpired = ((Get-Date) - $lastSwitchAt).TotalSeconds -ge $CooldownSeconds
            }

            if (-not $switchedForCurrentAbsence -and $missingForSeconds -ge $DisconnectSeconds -and $cooldownExpired) {
                Write-Log "触发: 所有监控 slot 离线已持续 $(Format-Elapsed $missingForSeconds)" '动作'
                $switchSucceeded = Invoke-SwitchToMac
                $lastSwitchAt = Get-Date
                $switchedForCurrentAbsence = $true
                $cooldownLogged = $false
                if (-not $switchSucceeded) {
                    Write-Log "切换失败；等待至少一个 slot 恢复在线后才会再次尝试" '警告'
                }
            }
            elseif (-not $switchedForCurrentAbsence -and $missingForSeconds -ge $DisconnectSeconds -and -not $cooldownExpired -and -not $cooldownLogged) {
                $remaining = $CooldownSeconds - ((Get-Date) - $lastSwitchAt).TotalSeconds
                Write-Log "所有 slot 均离线，但冷却时间还剩 $(Format-Elapsed $remaining)" '警告'
                $cooldownLogged = $true
            }
        }
        else {
            if ($null -ne $absentSince) {
                Write-Log "至少一个监控 slot 在线，确认计时已重置"
            }

            $absentSince = $null
            $switchedForCurrentAbsence = $false
            $cooldownLogged = $false
        }
    }
    catch {
        Write-Log "错误: $($_.Exception.Message)" '错误'
    }

    if ($Once) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
}
