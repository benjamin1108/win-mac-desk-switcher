# win-mac-desk-switcher

这个项目用来在 Windows 和 Mac 之间自动切换鼠标、键盘和显示器。

当前已实现：

- Windows 切到 Mac。
- Mac 切回 Windows，默认把 Logitech 键鼠切到 1 号信道，并把显示器切到 DP1。

Windows 切到 Mac 时会执行：

1. 把 Logitech 鼠标和键盘切到 Easy-Switch 2 号信道。
2. 把显示器输入切到 Mac 的 Type-C 口。

## 目录结构

```text
win-mac-desk-switcher
├─ 一键切到Mac.bat        双击后立即切到 Mac
├─ 一键切到Windows.command 双击后立即切到 Windows
├─ 开始自动监控.bat       启动自动监控模式
├─ README.md              说明文档
├─ bin
│  └─ writeValueToDisplay.exe
├─ scripts
│  ├─ switch-to-mac-now.ps1
│  ├─ switch-to-windows-now.sh
│  ├─ switch-logitech-to-windows-macos.sh
│  ├─ monitor-switch-to-mac.ps1
│  ├─ logi-hidpp-probe.ps1
│  └─ install-at-logon.ps1
├─ tools
│  └─ hid-send.c
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

## Mac 上一键切到 Windows

Windows 连接在显示器的 DP1 口。BetterDisplay GUI 里可用的输入项是 `DisplayPort 1 (LG alt)`，所以 Mac 端脚本默认使用 LG alternate DDC 命令切到 DP1：`ddcAlt=0xD0`，`vcp=inputSelectAlt`。脚本会先把 Logitech 键盘和鼠标切到 Easy-Switch 1 号信道，再切显示器。使用 BetterDisplay 后端时，需要 BetterDisplay 正在运行，并且显示器已开启 DDC/CI：

```text
一键切到Windows.command
```

第一次使用前需要安装 `hidapi`。如果没有安装 BetterDisplay，还需要安装 `ddcctl`：

```zsh
brew install hidapi
brew install ddcctl
```

macOS 打开键盘 HID 设备时可能需要 Input Monitoring 权限。双击 `.command` 会由 Terminal 运行，所以需要到：

```text
System Settings → Privacy & Security → Input Monitoring
```

把 Terminal 打开。使用 Ghostty 或其他终端运行时，也需要给对应终端授权。

也可以先演练，不真正执行：

```zsh
./scripts/switch-to-windows-now.sh --dry-run
```

如果你的显示器 DP1 的 LG alt 值不是 `0xD0`，可以改用别的输入值：

```zsh
./scripts/switch-to-windows-now.sh --lg-alt-input 0xD0
```

也可以指定后端：

```zsh
./scripts/switch-to-windows-now.sh --backend betterdisplay --method lg-alt --lg-alt-input 0xD0
./scripts/switch-to-windows-now.sh --backend ddcctl --display 1 --input 15
```

BetterDisplay 的命令等价于：

```zsh
/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay set --ddcAlt=0xD0 --vcp=inputSelectAlt
```

日志位置：

```text
logs/switch-to-windows-now.log
```

### Logitech 键鼠反向切换

Mac 端通过 `hidapi` 发送 Bluetooth HID++ report。当前设备配置：

```text
键盘：Alto Keys K98M，VID/PID 046D:B38E，feature index 0x09
鼠标：MX Master 3S，VID/PID 046D:B034，feature index 0x0A
目标：物理 1 号信道，即 Windows
```

只切 Logitech，不切屏幕：

```zsh
./scripts/switch-logitech-to-windows-macos.sh
```

查看 macOS HID 设备：

```zsh
./bin/hid-send --list
```

如果 Windows 不是 1 号信道，可以改目标信道：

```zsh
./scripts/switch-to-windows-now.sh --logi-channel 2
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
