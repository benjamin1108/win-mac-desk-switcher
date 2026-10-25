# Mac 端适配交接：MX Master 4

记录日期：2026-10-25（香港时间）。目标是保留原有桌面切换方式，将旧鼠标替换为 MX Master 4，并重新打包带图标的 Mac App。

## Windows 已实测的设备信息

| 项目 | 检测结果 |
| --- | --- |
| 显示器 | LG ULTRAGEAR+，硬件标识 GSM7846；未确认完整零售型号 |
| 接收器 | Logitech Bolt，USB VID:PID = 046D:C548 |
| Windows HID++ 接口 | UsagePage 0xFF00，Usage 0x0002，输入/输出报告均为 20 字节 |
| 键盘 | slot 3；唤醒后在线，HOSTS_INFO feature index 0x0B；型号沿用原项目 Alto Keys K98M，未重新读取型号 |
| 旧鼠标 | slot 4，实测名称 MX Master 3S，CHANGE_HOST feature index 0x0A；仍配对，但已从 Windows 切换/监控配置排除 |
| 新鼠标 | slot 5，实测名称 MX Master 4，HID++ 4.5，HOSTS_INFO index 0x0F，CHANGE_HOST index 0x0E |
| 当前键盘和新鼠标通道 | HOSTS_INFO 返回 3 个主机，当前 hostIndex 0，即物理 1 号通道（Windows） |
| Mac 目标通道 | 沿用原配置物理 2 号通道，即 hostIndex 1；未在 Mac 上验证 |
| Windows → Mac 显示器命令 | 沿用 `bin/writeValueToDisplay.exe 0 0xD1 0xF4 0x50`（原配置为 Type-C） |
| Mac → Windows 显示器命令 | 沿用 `m1ddc display 1 set input-alt 208`，即 LG alternate 0xD0 / DP1；未重新验证接线 |

以上 slot 编号属于 **Windows 这只接收器的配对表**。不能直接把 Mac 端 slot 改成 3、5。046D:C548 是接收器标识，不是新鼠标蓝牙 VID/PID；MX Master 4 的蓝牙 VID/PID 尚未知。

## Windows 已完成的修改与验证

- 手动切换和自动监控默认使用 slot 3、5，目标通道仍为 2。
- 自动监控启动后必须先观察到所有配置设备同时在线，才开始判断离线切屏。
- HID++ 功能查找返回 0 时按不支持处理，避免误用 root feature。
- EXE 构建入口保留图标及隐藏窗口，新增 `--dry-run`，等待脚本结束并返回退出码；实际执行失败会显示错误提示。
- PowerShell 语法检查通过；实际 EXE 演练返回 0；键盘和新鼠标查询均成功。**没有执行真实键鼠切换或显示器切换，也未启用登录自启动。**
- Windows 更换 Bolt USB 插口后，一键 EXE 下次启动会重新枚举设备；正在运行的自动监控缓存了旧路径，需要关闭后重启。不要硬编码机器生成的完整 HID 路径。

## Mac 端下一步

1. 同步 `master`，先检查本地改动；有未提交修改时先保存，避免覆盖。

   ```zsh
   git status --short
   git pull --ff-only origin master
   ```

2. 让键盘和 **MX Master 4** 都连接 Mac。确认实际走 Bolt 接收器还是蓝牙；在“系统设置 → 隐私与安全性 → 输入监控”允许所用终端。

3. 使用源码重新编译原生 IOKit 工具，避免仓库已有二进制过旧，再只读枚举：

   ```zsh
   cc tools/hid-send-macos.c -framework IOKit -framework CoreFoundation -o bin/hid-send-macos
   ./bin/hid-send-macos --list
   ```

   若没有 `cc`，先安装 Apple Command Line Tools。记录新鼠标的产品名、VID/PID、UsagePage/Usage；只提交必要硬件信息，不提交序列号或机器专属设备路径。

4. **若使用 Bolt：** 执行 `zsh scripts/switch-logitech-to-windows-macos.sh --probe-receiver`。该选项只 ping，不切换。它会遍历 usage 0x0001/0x0002 和 slot 1–6。根据响应识别 Mac 接收器的键盘和新鼠标 slot，必要时分别唤醒或关闭其中一台来区分。更新脚本的 `KEYBOARD_SLOT`、`MOUSE_SLOT`、`RECEIVER_USAGE`（以及实际需要修改的产品名过滤）。现有默认 slot 是 1、2；帮助文字仍写 3、4，应一并修正。接收器模式已动态查找 CHANGE_HOST，优先使用它。

5. **若使用蓝牙：** 原脚本仍固定为旧鼠标 `MOUSE_VIDPID=046D:B034`、`MOUSE_PRODUCT=MX Master 3S`、`MOUSE_FEATURE_INDEX=0x0A`，这些不能继续用于新鼠标。根据 Mac 枚举结果修改 VID/PID、产品名和接口过滤，并通过 HID++ 查询确认新鼠标 CHANGE_HOST feature index。Windows 实测的 0x0E 可作为线索，但不能代替 Mac 端验证；建议扩展原生工具支持蓝牙功能查询，避免盲发硬编码报告。不要通过试发 CHANGE_HOST 来识别设备。键盘配置保持原样，除非查询结果要求修改。

6. 调试接收器时先指定 `--transport receiver`，避免 auto 模式失败后回退到尚未更新的旧鼠标蓝牙配置。返回 Windows 的目标保持物理通道 1（hostIndex 0），先运行演练：

   ```zsh
   zsh -n scripts/switch-logitech-to-windows-macos.sh
   zsh -n scripts/switch-to-windows-now.sh
   zsh scripts/switch-logitech-to-windows-macos.sh --transport receiver --dry-run
   zsh scripts/switch-to-windows-now.sh --dry-run
   ```

   演练只检查计划命令，不能证明实际硬件切换成功。先确认输出针对新鼠标而非旧鼠标；随后在用户准备好切回 Windows 时执行一次真实切换，并确认键盘、鼠标、显示器三个结果。

7. 完成后运行 `zsh scripts/build-macos-app.sh` 重新生成 `dist/切到Windows.app`，保留现有图标。构建需要本机 `m1ddc`；沿用正常无 setuid 构建。将 App 放入 `/Applications`，按需要重新授予输入监控权限并放入 Dock。不要只修改仓库脚本却继续运行旧 App，App 内有脚本副本。

8. 将 Mac 实测的配对 slot 或蓝牙参数、权限设置、真实切换结果补充到本文并提交源码。Windows 的 slot 3、5 不应被 Mac 端 slot 覆盖。


## Mac 端实测与适配结果（2026-10-25）

已从 `f2d3880` 快进到 `5b2ab53` 后完成以下适配。Windows 的 slot 3、5 保持不变。

| 项目 | Mac 只读实测 |
| --- | --- |
| 连接方式 | USB Bolt 接收器，046D:C548，产品名 USB Receiver |
| HID++ 接口 | UsagePage 0xFF00，Usage 0x0001；无 Usage 0x0002 接口 |
| 键盘 | slot 2，查询名称 Alto Keys K98M，HID++ 4.5 |
| 键盘功能 | CHANGE_HOST 0x0A；HOSTS_INFO 0x0B |
| 新鼠标 | slot 3，查询名称 MX Master 4，HID++ 4.5 |
| 鼠标功能 | CHANGE_HOST 0x0E；HOSTS_INFO 0x0F |
| 当前信道 | 两台均报告 3 个主机、hostIndex 1，即物理 2 号信道 |
| Windows 目标 | 继续使用物理 1 号信道，即 hostIndex 0 |
| 显示器 | m1ddc 显示器 1 为 LG ULTRAGEAR+；保留 input-alt 208 / DP1，未执行切屏验证 |
| 蓝牙 | 未发现直连的新鼠标；未推测其 VID/PID，移除旧 3S 默认值 |

### 已完成的代码与构建

- Mac 默认使用 receiver，slot 改为键盘 2 / 鼠标 3，帮助说明同步更新。
- 新增 `--receiver-info` 读取设备名称、CHANGE_HOST 和 HOSTS_INFO；新增脚本 `--check` 只读核验两台设备。
- 切换前验证两台名称，发送前再次核对该 slot 的名称；鼠标必须为 MX Master 4。
- IOKit 枚举不再先打开全部系统 HID，只打开严格匹配的接口；指定 Usage 不存在时直接失败，不再选择其它接口。设备列表不输出序列号、指针或机器路径。
- 功能索引 0 视为不支持；区分 HID 写入/协议错误和发送后超时。后者保留设备切走时无回复的兼容行为，并明确标注物理切换未确认。
- 键鼠明确失败时返回错误，默认不继续切屏；不会在部分设备已切换后回退到蓝牙。
- 完整 `--dry-run` 展示两台设备的实际参数；App 启动器转发参数，并在真实执行失败时显示提示。
- 修复打包脚本自定义输出目录未同步到 bundle 子目录的问题；保留原图标，版本 1.1 / build 2，正常非 setuid 构建。

### 验证和权限

- `cc -Wall -Wextra -Werror` 编译通过；三个 zsh 脚本语法检查通过。
- 10 项脚本回归测试通过；原生协议模拟测试通过，测试均不操作真实硬件。
- 实机 `--check` 成功读取两台名称和功能编号；只读 probe 确认 slot 2、3 在线。
- 沙箱内设备打开被系统拒绝，允许本地硬件访问后查询成功；未修改系统隐私数据库或增加 setuid 权限。重装 App 后是否需要重新开启“输入监控”，以 App 实际运行和系统提示为准。
- App ad-hoc 签名、Info.plist、系统库依赖检查通过，图标与原始资源 SHA-256 一致。
- **未执行真实切换**。还需在用户准备好切回 Windows 时验收键盘、MX Master 4、LG 显示器三个结果；演练和查询不等于真实切换成功。

名称查询遵循 DEVICE_NAME (0x0005) 的长度与分片读取方式，可参照 [Solaar 的 HID++ 实现](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/hidpp20.py)。

### 本机安装

已将新版安装到 `/Applications/切到Windows.app`，仓库 `dist/切到Windows.app` 同步更新。安装后的 App 启动器 `--dry-run` 返回 0，App 内置 HID 工具的 `--check` 成功识别键盘和 MX Master 4。旧 App 已保存在本次工作目录 `work/backups/`，便于回退。仓库已有的旧 `bin/hid-send` 未改动，新脚本优先使用重新编译的 `bin/hid-send-macos`。
