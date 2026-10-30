# 小米电脑管家 6.x 机型解锁

在非小米笔记本上装了小米电脑管家 6.x 后，可能会遇到这些问题：控制中心点「字幕转录」提示**打开失败**，「AI 降噪」等按钮也不显示。本工具用来解除控制中心的机型白名单。

## 原理

- 6.x 控制中心（`XiaomiPCManager.dll`，.NET）先从注册表 `HKLM\HARDWARE\DESCRIPTION\System\BIOS` 的 `BaseBoardProduct` / `SystemSKU` / `SystemProductName` 中，用正则 `TM\d{4}` 提取机型代号，再拿它去查 `DeviceModelConfig` 里的白名单。非小米机型提取不到代号，于是 `Is*Supported` 全部返回 false。
- 本工具把 `DeviceModelConfig` 中所有 `static bool Is*Supported(string)` 方法的 IL 改成 `return true`。它**不伪造机型**，性能模式等功能仍按真实机型处理。
- 工具按类名和方法签名定位，不写死偏移。管家小版本更新后，一般可以直接重新运行。方法实现如果变了（例如加了异常处理），工具会跳过该方法并提示，不会强行修改。
- 5.x 时代常用的 `wtsapi32.dll` 劫持补丁对 6.x 主程序无效，因为 .NET 主程序从 System32 加载 wtsapi32。

## 使用

只需要 Windows 10/11 自带的 PowerShell 5.1，没有其他依赖。

- 双击 `unlock.bat` 解锁。会请求管理员权限，并自动关闭、重启管家。
- 双击 `restore.bat` 还原原版。

命令行用法：

```powershell
powershell -ExecutionPolicy Bypass -File unlock.ps1 -Action Status    # 查看状态
powershell -ExecutionPolicy Bypass -File unlock.ps1                   # 解锁
powershell -ExecutionPolicy Bypass -File unlock.ps1 -Action Restore   # 还原
```

安装目录会自动探测；也可以用 `-Path` 直接指定 `XiaomiPCManager.dll`。原版备份保存在同目录的 `XiaomiPCManager.dll.bak`，还原后会删除。

## 实测（6.0.0.39，非小米笔记本）

| 功能 | 结果 |
|---|---|
| 字幕转录 | 可用 |
| AI 降噪、智能跟踪拾音 | 入口已解锁，实际效果未充分验证 |
| 人像居中 | 按钮出现但为灰色，可能依赖小米的摄像头 |
| 手机摄像头协同 | 本身不受机型限制，不需要本工具 |

只想用字幕转录的话，也可以不打补丁，直接运行 `<安装目录>\modules\svrc\subtitle\SubtitleTranscription.exe`。

## 注意

- 修改后，`XiaomiPCManager.dll` 的小米数字签名会失效。目前没有发现管家会校验这个文件的签名。
- 管家升级会安装到新的版本目录，补丁随之失效，升级后重新运行 `unlock.bat` 即可。
- 本工具只修改本机已安装的文件，不包含也不分发任何小米的二进制文件。
- 仅供学习研究，使用风险自负。本项目与小米公司无关。
