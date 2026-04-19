# win-mac-desk-switcher

这个项目用来在 Windows 和 Mac 之间自动切换鼠标、键盘和显示器。

当前已实现 Windows 切到 Mac；Mac 切回 Windows 还未实现。

Windows 切到 Mac 时会执行：

1. 把 Logitech 鼠标和键盘切到 Easy-Switch 2 号信道。
2. 把显示器输入切到 Mac 的 Type-C 口。

## 目录结构

```text
win-mac-desk-switcher
├─ 一键切到Mac.bat        双击后立即切到 Mac
├─ 开始自动监控.bat       启动自动监控模式
├─ README.md              说明文档
├─ bin
│  └─ writeValueToDisplay.exe
├─ scripts
│  ├─ switch-to-mac-now.ps1
│  ├─ monitor-switch-to-mac.ps1
│  ├─ logi-hidpp-probe.ps1
│  └─ install-at-logon.ps1
└─ logs                   运行后自动生成日志
```

## 最常用：一键切到 Mac

双击：

```text
一键切到Mac.bat
```

它会按这个顺序执行：

1. 把 Logitech slot `3`、`4` 切到物理 2 号信道。
2. 运行 `bin\writeValueToDisplay.exe 0 0xD1 0xF4 0x50`。
3. 把显示器切到 Mac Type-C 输入。

日志位置：

```text
logs\switch-to-mac-now.log
```

## 测试一键切换但不真正执行

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\switch-to-mac-now.ps1 -DryRun
```

## 自动监控模式

双击：

```text
开始自动监控.bat
```

自动监控逻辑：

1. 监控 Logitech Bolt 接收器上的 HID++ slot `3` 和 `4`。
2. 当两个 slot 都离线超过 2 秒，认为鼠标和键盘都已经切走。
3. 自动运行显示器切换命令，把显示器切到 Mac Type-C。

日志位置：

```text
logs\monitor-switch-to-mac.log
```

## 安装登录后自动监控

确认自动监控没问题后再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-at-logon.ps1
```

删除自动任务：

```powershell
Unregister-ScheduledTask -TaskName 'SwitchScreenToMacMonitor' -Confirm:$false
```

## 当前设备信息

Logitech Bolt 接收器：

```text
USB VID_046D PID_C548
```

当前监控和切换的 HID++ slot：

```text
3, 4
```

HID++ 使用从 0 开始的 host index，Logitech 按键上的物理信道是从 1 开始的。所以：

```text
物理 1 号信道 = host index 0
物理 2 号信道 = host index 1
物理 3 号信道 = host index 2
```

## 常用命令

查看 Logitech HID 设备：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\logi-hidpp-probe.ps1 -List
```

查看 slot 是否在线：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\logi-hidpp-probe.ps1 -Ping -Devices @(3, 4)
```

查看当前物理信道：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\logi-hidpp-probe.ps1 -HostsInfo -Devices @(3, 4)
```

手动切到别的 Logitech 信道，例如 3 号信道：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\switch-to-mac-now.ps1 -TargetChannel 3
```
