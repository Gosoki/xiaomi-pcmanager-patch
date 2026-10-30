# 小米电脑管家 6.0 补丁

适用于**小米电脑管家 6.0**，已在 6.0.0.39 实测。包含两个互相独立的补丁：

| 补丁 | 什么情况需要 | 修什么 | 改动的文件 |
|---|---|---|---|
| 一、机型白名单（默认） | 在**非小米笔记本**上装了管家 | 控制中心点「字幕转录」提示打开失败，「AI 降噪」等按钮不显示 | `XiaomiPCManager.dll` |
| 二、互联地区（`-Region`，可选） | Windows 的**国家或地区**和**手机的地区**不一样，比如人在日本、Windows 设成日本，用的是国行手机 | 手机复制、电脑粘贴正常，但**电脑复制、手机粘贴不行** | `MiSmartShare\micont_rtm.dll` |

两个补丁都会备份原版，可以一键还原。补丁二和机型无关，小米笔记本遇到同样的地区问题也能用。

## 补丁一：机型白名单

**症状**：非小米笔记本上，控制中心点「字幕转录」提示**打开失败**；「AI 降噪」「智能跟踪拾音」等入口不显示。

**原因**：6.0 控制中心（.NET）先从注册表 `HKLM\HARDWARE\DESCRIPTION\System\BIOS` 的 `BaseBoardProduct` / `SystemSKU` / `SystemProductName` 中，用正则 `TM\d{4}` 提取小米机型代号，再拿它去查 `DeviceModelConfig` 里的白名单。非小米机型提取不到代号，于是 `Is*Supported` 全部返回 false。

**做法**：
- 把 `DeviceModelConfig` 中所有 `static bool Is*Supported(string)` 方法的 IL 改成 `return true`。
- **不伪造机型**，性能模式等功能仍按真实机型处理。
- 按类名和方法签名定位，不写死偏移。方法实现如果变了（例如加了异常处理），会跳过该方法并提示，不会强行修改。

5.x 时代常用的 `wtsapi32.dll` 劫持补丁对 6.0 无效，因为 .NET 主程序从 System32 加载 wtsapi32。

## 补丁二：互联地区（剪贴板电脑→手机）

**症状**：跨设备剪贴板只能单向用。手机复制、电脑粘贴正常；电脑复制后，手机上粘贴没有反应，只有在手机的剪贴板列表里手动点才能取到。

**原因**：
- 6.0 的小米互联服务（`micont_service`，核心是 `micont_rtm.dll`）把注册表 `HKCU\Control Panel\International\Geo` 的 `Name` 当作电脑的设备地区，同步给手机。这个值就是 Windows 设置里的「国家或地区」。
- 手机的跨设备剪贴板（`com.milink.service`）收到电脑的剪贴板通知后，会比较两边的地区，不一致就直接丢弃。手机日志：
  ```
  isSameRegionWithLocal, localRegion = cn, targetRegion = jp
  peer device is not same region with this device, ignore this msg
  ```
- 5.x 的互联服务没有这项检查，所以升级到 6.0 后才出现。手机→电脑方向不检查地区，不受影响。

**做法**：
- 把 `micont_rtm.dll` 里唯一的路径字符串 `Control Panel\International\Geo` 改成 `Software\MI\micont\GeoOverride`。只改这一个字符串，不动代码。
- 在 `HKCU\Software\MI\micont\GeoOverride` 写入 `Name = <-Region 的值>`。同时在 `HKEY_USERS\S-1-5-18` 下写一份，这是服务拿不到登录用户令牌时的回退路径。
- 停止 `micont_service`，替换文件后再启动。只有这个服务加载 `micont_rtm.dll`。
- Windows 的「国家或地区」**保持不变**，只有小米互联会读到覆盖值。

**`-Region` 填什么**：填手机的地区，两位代码。国行手机填 `CN`，也可以直接双击 `unlock-region-cn.bat`。

**不想改文件的话**：把 Windows「设置 → 时间和语言 → 语言和区域 → 国家或地区」改成和手机一致，效果相同。但会影响 Microsoft Store、资讯等跟随地区的功能。

## 适用版本

| 版本 | 情况 |
|---|---|
| 6.0 | 可用，已在 6.0.0.39 实测 |
| 5.x 及更早 | 不适用。5.x 的控制中心在单独的 `PcControlCenter.dll` 里，结构和 6.0 不同；5.x 也没有地区检查 |
| 6.0 之后 | 未测试。类名、方法签名、路径字符串不变的话一般可以直接用；结构变了，工具会提示跳过或无法识别，不会强行修改 |

运行 `unlock.ps1 -Action Status` 可以先看工具能不能识别你装的版本。

## 使用

只需要 Windows 10/11 自带的 PowerShell 5.1，没有其他依赖。bat 会请求管理员权限，并按需自动关闭、重启管家（补丁一）和互联服务（补丁二）。

| 文件 | 作用 |
|---|---|
| `unlock.bat` | 只打补丁一 |
| `unlock-region-cn.bat` | 补丁一 + 补丁二（地区 CN） |
| `restore.bat` | 两个补丁全部还原，并删除覆盖用的注册表键 |

命令行用法：

```powershell
powershell -ExecutionPolicy Bypass -File unlock.ps1 -Action Status    # 查看状态
powershell -ExecutionPolicy Bypass -File unlock.ps1                   # 补丁一
powershell -ExecutionPolicy Bypass -File unlock.ps1 -Region CN        # 补丁一 + 补丁二；已打过补丁二时只更新地区值
powershell -ExecutionPolicy Bypass -File unlock.ps1 -Action Restore   # 全部还原
```

安装目录会自动探测，也可以用 `-Path` 直接指定 `XiaomiPCManager.dll`。原版备份分别是同目录的 `XiaomiPCManager.dll.bak` 和 `MiSmartShare\micont_rtm.dll.bak`，还原后会删除。

## 实测（6.0.0.39，非小米笔记本 + 国行 HyperOS 3 手机）

| 功能 | 结果 |
|---|---|
| 字幕转录 | 补丁一后可用 |
| AI 降噪、智能跟踪拾音 | 补丁一后入口出现，实际效果未充分验证 |
| 剪贴板 电脑→手机 | 补丁二后可用（Windows 地区为日本） |
| 人像居中 | **不可用**，见下文 |
| 手机摄像头协同 | 本身不受机型和地区限制，不需要补丁 |

**人像居中为什么是灰的**：这是摄像头驱动层的特效。实现在小米设备服务 MiDeviceService 里（`CameraSetting::SetAutoFrame`、`CameraMipiManager`），要配合小米笔记本的 MIPI 摄像头和小米定制的摄像头驱动才能自动取景。普通 USB 摄像头没有这套驱动，状态查询一直超时，按钮也就是灰的。补丁一只能让按钮出现，补不出硬件和驱动。

只想用字幕转录的话，也可以不打补丁，直接运行 `<安装目录>\modules\svrc\subtitle\SubtitleTranscription.exe`。

## 注意

- 修改后，被改的文件的小米数字签名会失效。目前没有发现管家或互联服务会校验这两个文件的签名。
- 管家升级会安装到新的版本目录，补丁随之失效，升级后重新运行对应的 bat 即可。
- 本工具只修改本机已安装的文件，不包含也不分发任何小米的二进制文件。
- 仅供学习研究，使用风险自负。本项目与小米公司无关。

## 许可证

[MIT](LICENSE)。许可证只覆盖本项目的代码，不涉及小米电脑管家本身。
