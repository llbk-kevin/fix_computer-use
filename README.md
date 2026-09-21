# Windows 10 LTSC 上 Codex Computer Use 截图失败的修复方法

针对 Windows 10 LTSC 2021 上 Codex Computer Use 无法截图的修复案例，包含原因分析、本地兼容层源码、构建与回退说明，以及备用桌面截图工具。

**已在指定版本、本机资源管理器场景验证原生截图恢复；其他版本和业务场景未据此获得验证。** 本项目提供修复方法与已验证案例，补丁仅接受经过检查的原程序哈希。

English: A version-pinned workaround for Codex Computer Use screenshot failures on Windows 10 LTSC 2021. It addresses the missing `IsBorderRequired` API and a Windows Graphics Capture bitmap-conversion timeout. Explorer screenshots were verified on the documented configuration; this is a local compatibility patch, not an official vendor update.

## 是否遇到了同类问题

窗口枚举和文字读取正常，但请求截图时出现：

```text
SetIsBorderRequired failed: 不支持此接口 (0x80004002)
```

本案例中，绕过可选的边框设置后，还会出现：

```text
FrameArrived timed out: timed out waiting on channel
```

这涉及两个问题：系统缺少 `GraphicsCaptureSession.IsBorderRequired` 可选接口，以及捕获回调内等待图像转换超时。基础 **Windows Graphics Capture（WGC）** 仍然可用，并不是安装一个缺失的 Python 包或运行库就能修复。

先阅读 [故障背景与原因](docs/01-故障背景与原因.md)，再按 [使用与回退](docs/03-使用与回退.md) 检查系统能力和文件版本。仅错误文字相同，不足以证明某台电脑适用这个二进制补丁。

## 已验证环境与结果

| 项目 | 验证记录 |
| --- | --- |
| 系统 | Windows 10 Enterprise LTSC 2021，21H2，19044.1620，x64 |
| Codex | 应用 26.915.4065.0；Computer Use 插件 26.915.31945；`@oai/sky` 0.7.1 |
| 原生截图 | 官方 `sky.get_window_state` 在资源管理器中返回可辨认的真实图片 |
| 连续读取 | 同时获取截图和文字连续三次成功，完整回退并重新安装后再次通过 |
| 回退 | 原始程序哈希及有效厂商签名均已恢复验证 |
| 尚未验证 | 其他软件版本、微信小程序等业务页面、HDR、截图坐标点击、完整 Codex 更新或重启 |

完整版本、哈希和验收方法统一列于 [使用与回退](docs/03-使用与回退.md)；实际测试记录见 [修复日志](docs/Log/2026-09-21-修复记录.md)。

## 修复方法与阅读顺序

兼容层保留系统默认捕获边框，将会卡住的异步表面转换替换为 D3D11 纹理读取，再生成真实位图，继续由官方链路处理截图。备用 GDI 工具只截取可见桌面，适合临时使用，两者的用途和限制不同。

| 文档 | 解决的问题 |
| --- | --- |
| [01 故障背景与原因](docs/01-故障背景与原因.md) | 为什么能读文字却不能截图，如何判断两个故障点 |
| [02 修复方案](docs/02-修复方案.md) | 兼容层如何工作，备用工具适合什么情况 |
| [03 使用与回退](docs/03-使用与回退.md) | 检查版本、准备依赖、构建、安装、验收和恢复原程序 |
| [04 待提交的官方反馈](docs/04-待提交的官方反馈.md) | 面向维护者的最小复现和建议，尚未提交 |
| [修复记录](docs/Log/2026-09-21-修复记录.md) | 关键尝试的结果及最终验收摘要 |

## 项目内容

- `tools/`：原生兼容层源码及构建脚本，备用桌面截图工具。
- `scripts/`：Windows 能力诊断、原生兼容层安装与回退。
- `tests/`：多显示器负坐标和裁剪边界测试。
- `artifacts/`：本机生成的备份、构建产物和截图，由 Git 忽略。

原生构建使用 Python、pefile 和 LLVM-MinGW；备用截图使用 Python 与 Pillow。具体版本及命令见 [依赖和操作步骤](docs/03-使用与回退.md)，仓库不分发厂商二进制文件。

**本地修改后的辅助程序签名状态为 `NotSigned`，不是厂商正式更新。** 安装脚本校验原版、候选程序和 DLL 的哈希，并保留原文件用于回退。其他版本不能仅靠修改哈希或关闭校验来套用；应用更新后应重新判断适用性。
