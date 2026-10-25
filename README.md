# win-mac-desk-switcher

这个项目用来在 Windows 和 Mac 之间自动切换鼠标、键盘和显示器。

当前已实现：

- Windows 切到 Mac。
- Mac 切回 Windows，默认把 Logitech 键鼠切到 1 号信道，并把显示器切到 DP1。

Windows 切到 Mac 时会执行：

1. 把 Logitech 鼠标和键盘切到 Easy-Switch 2 号信道。
2. 把显示器输入切到 Mac 的 Type-C 口。

Mac 端接力适配请先阅读 [设备信息与操作步骤](docs/mac-handoff-2026-10-25.md)。

## 本机适配（2026-10-25）

已通过 Windows 接收器查询和演练验证：键盘使用 slot 3，新鼠标 MX Master 4 使用 slot 5；旧鼠标 MX Master 3S 仍在 slot 4，本配置不再切换它。两台当前设备均位于物理 1 号信道，切到 Mac 时沿用物理 2 号信道。MX Master 4 的 CHANGE_HOST feature index 实测为 0x0E，由脚本动态查询，无须固定写入。

显示器识别为 LG ULTRAGEAR+，保留原有 Type-C 切换参数。自动监控启动后先等待全部配置设备同时在线，避免设备休眠或编号错误导致启动时误切屏。未启用登录自启动，也未执行真实切屏。

Mac 端也已完成只读实测和适配：通过 Bolt `046D:C548` 连接，HID++ 接口为 UsagePage `0xFF00` / Usage `0x0001`；键盘 Alto Keys K98M 在 **slot 2**，MX Master 4 在 **slot 3**，当前均为物理 2 号信道。键盘 CHANGE_HOST / HOSTS_INFO 为 `0x0A` / `0x0B`，鼠标为 `0x0E` / `0x0F`，每次运行动态查询。Mac 和 Windows 的配对表不同，不可互相覆盖。

Mac 默认只使用已验证的 Bolt 配置，先读取两台设备名称并校验，再切到物理 1 号信道。设备不符、查询失败或明确的 HID 写入/协议错误会停止后续切换；默认顺序下不继续切屏。CHANGE_HOST 成功写入后可能因设备离开 Mac 而收不到回复，此时会注明实际切换待确认。已完成演练、协议/脚本回归测试和 App 构建；真实键盘、鼠标、显示器切换仍待用户准备好后验收。

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

1. 把 Logitech slot `3`、`5` 切到物理 2 号信道。
2. 运行 `bin\writeValueToDisplay.exe 0 0xD1 0xF4 0x50`。
3. 把显示器切到 Mac Type-C 输入。

日志位置：

```text
logs\switch-to-mac-now.log
```

## Mac 上一键切到 Windows

Windows 连接在显示器的 DP1 口。Mac 端脚本默认使用 `m1ddc` 的 LG alternate DDC 命令切到 DP1：`input-alt 208`，也就是 `0xD0`。脚本会先把 Logitech 键盘和鼠标切到 Easy-Switch 1 号信道，再切显示器。显示器需要开启 DDC/CI：

```text
一键切到Windows.command
```

使用源码时需要 Apple Command Line Tools 和 `m1ddc`（原生 IOKit 工具无需 `hidapi`）；打包好的 App 已包含所需工具：

```zsh
brew install m1ddc
cc tools/hid-send-macos.c -framework IOKit -framework CoreFoundation -o bin/hid-send-macos
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
./scripts/switch-to-windows-now.sh --backend m1ddc --method lg-alt --lg-alt-input 0xD0
./scripts/switch-to-windows-now.sh --backend betterdisplay --method lg-alt --lg-alt-input 0xD0
./scripts/switch-to-windows-now.sh --backend ddcctl --display 1 --input 15
```

`m1ddc` 的命令等价于：

```zsh
m1ddc display 1 set input-alt 208
```

BetterDisplay 的旧命令等价于：

```zsh
/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay set --ddcAlt=0xD0 --vcp=inputSelectAlt
```

日志位置：

```text
logs/switch-to-windows-now.log
```

### 打包成独立 Mac App

生成自包含 bundle：

```zsh
./scripts/build-macos-app.sh
```

输出位置：

```text
dist/切到Windows.app
```

bundle 会包含 app 专用的 IOKit 版 `hid-send`、`m1ddc` 和 Mac 侧切换脚本，不再依赖 Homebrew 的 `libhidapi` 动态库。打包脚本会对 app 做 ad-hoc 签名，方便 macOS 隐私设置识别它。第一次双击时如果系统没有弹出授权提示，可以到 `System Settings → Privacy & Security → Input Monitoring` 手动加入 `/Applications/切到Windows.app`。

### Logitech 键鼠反向切换

Mac 端默认通过 Logitech Bolt 接收器 `046D:C548` 发送 receiver HID++ `CHANGE_HOST`。先检查键盘和鼠标名称，再动态查询切换功能；不再自动使用旧鼠标蓝牙参数。当前默认配置：

```text
Bolt receiver：VID/PID 046D:C548
HID++ 接口：UsagePage 0xFF00 / Usage 0x0001
键盘：macOS receiver device 2，Alto Keys K98M
鼠标：macOS receiver device 3，MX Master 4
蓝牙回退键盘：Alto Keys K98M，VID/PID 046D:B38E，feature index 0x0A
蓝牙鼠标：MX Master 4 的 VID/PID 和 feature index 未在蓝牙上验证，默认不配置
目标：物理 1 号信道，即 Windows
```

只切 Logitech，不切屏幕：

```zsh
./scripts/switch-logitech-to-windows-macos.sh
```

只读检查已配置的两台设备，或扫描接收器配对槽位：

```zsh
./scripts/switch-logitech-to-windows-macos.sh --check
./scripts/switch-logitech-to-windows-macos.sh --probe-receiver
```

`--transport receiver` 是默认模式。保留的 `bluetooth` 和 `auto` 模式必须先明确设置并验证 `MOUSE_VIDPID`、`MOUSE_FEATURE_INDEX`，否则拒绝蓝牙发送；`auto` 只允许在接收器预检失败、尚未切走任何设备时尝试已配置的蓝牙模式。当前 Mac 没有连接蓝牙直连 MX Master 4，因此该路径未实测。

查看 macOS HID 设备：

```zsh
./bin/hid-send-macos --list
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

1. 监控 Logitech Bolt 接收器上的 HID++ slot `3` 和 `5`。
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
3, 5
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\logi-hidpp-probe.ps1 -Ping -Devices @(3, 5)
```

查看当前物理信道：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\logi-hidpp-probe.ps1 -HostsInfo -Devices @(3, 5)
```

手动切到别的 Logitech 信道，例如 3 号信道：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\switch-to-mac-now.ps1 -TargetChannel 3
```

## Mac 回归验证（不操作真实硬件）

```zsh
python3 tests/test_macos_switch.py
cc tests/hid-send-macos-tests.c -Wall -Wextra -Werror \
  -framework IOKit -framework CoreFoundation -o /tmp/hid-send-macos-tests
/tmp/hid-send-macos-tests
```

脚本测试替换 HID/DDC 工具，覆盖演练无发送、名称预检失败、键鼠切换失败时停止切屏、空格路径和旧蓝牙配置禁用。原生协议测试使用模拟 IOKit，覆盖功能索引 0、设备名不符、写入失败、HID++ 1/2 错误和切换后的无回复。
