# 本机环境与证据

采集日期：2026-09-21，时区 Asia/Shanghai。所有结论都对应本次会话，不能直接推广为其他机器或旧沙箱中的结论。

## 证据来源

- 用户提供的原始 Markdown 已在修复前提交到 Git；原样归档至 [archive/2026-09-21-original-notes.md](archive/2026-09-21-original-notes.md)。
- 原始文件 SHA-256：`fb186aa9f1970e54755aed309d70558531f3eaa67e3314f49d96ac027b761435`。
- [Windows 诊断脚本](../scripts/diagnose-windows.ps1) 读取系统版本、WinRT 能力、显示驱动和常见运行库。
- [结构化环境摘要](evidence/2026-09-21-environment.json) 保存本次采集结果，完整原始 JSON 位于被 Git 忽略的 `artifacts/diagnostics/windows.json`。
- 通过官方 `@oai/sky` 枚举并选择项目资源管理器窗口，分别测试截图与可访问性文本。未把窗口 ID 当成 HWND 使用。

## 系统和运行时

| 项目 | 观测值 | 解释 |
| --- | --- | --- |
| Windows | Enterprise LTSC 2021 / 21H2 / 19044.1620 / AMD64 | 注册表、CIM 与实际内核文件均已检查 |
| 内核文件 | 10.0.19041.1620 | 与 LTSC 的 19044 产品版本分别记录 |
| Codex 应用 | 26.915.4065.0 | 已安装应用包版本 |
| computer-use 插件 | 26.915.31945 | 当前技能与插件元数据版本 |
| `@oai/sky` | 0.7.1 | 当前安装包元数据 |
| CUA Node runtime | 0.0.16/20260915001755-492f19756c31 | 运行时 manifest 中的版本 |
| Windows PowerShell | 5.1.19041.1620 | 使用明确的系统路径可执行诊断 |
| Codex 捆绑 PowerShell | 启动失败，退出码 -2146233082 | `pwsh.runtimeconfig.json` 声明 .NET 10.0.11；没有把框架版本当成 PowerShell 版本 |
| Git | 2.53.0.windows.3 | 本地初始化与提交成功 |
| Python / Pillow | 3.12.7 / 12.2.0 | 已完成真实截图验证 |
| VC++ x64 Runtime | Installed=1，v14.38.33135.00 | 未发现需要重装它的证据 |
| .NET Framework | 注册表 Release=533325 | 存在；此记录不代表捆绑的 .NET 10 已兼容 |
| 交互桌面 | UserInteractive=True，SessionId=1 | 当前允许读到真实桌面像素 |

系统列出了 2026 年安装的 HotFix；同时内核版本仍为上述值，CBS 与 Windows Update 的待重启标志均为 False。仅凭这些信息不能断言“完全没有更新”“重启一定解决”或“某个特定 KB 缺失”。需另行核对系统维护历史与具体更新适用性。

## 哪些能力确实缺失

| 检查 | 实测 | 影响 / 动作 |
| --- | --- | --- |
| `GraphicsCaptureSession` 类型 | True | 基础 WGC 存在 |
| `GraphicsCaptureSession.IsSupported()` | True | 系统报告支持捕获；不代表每个新增属性都支持 |
| `IsBorderRequired` 属性 | **False** | 与官方截图错误直接吻合 |
| `IsCursorCaptureEnabled` 属性 | True | 无需把所有 WGC API 一并判为不可用 |
| `UniversalApiContract` v12 | **False** | 支持新边框属性的 API 合约不存在 |
| 项目内可执行截图工具 | 原先没有 | 原始文档提及的旧工具没有随文档提供；本次新增通用工具 |
| `mss` Python 模块 | 未安装 | 本方案不依赖它，没有为凑依赖而安装 |
| 官方 API 的可选截图后端 / 边框开关 | 所检查的 Windows 类型声明中未提供 | 不能编造 `border=false` 或 `backend=gdi` 参数 |

Windows SDK、WinRT 开发包与 Python 包不能凭安装就证明操作系统获得新的系统接口。应重新运行能力探测，用实际返回值验收。

## 显示设备与桌面布局

发现 AMD Radeon(TM) Graphics，以及 Oray、ToDesk、GameViewer 的虚拟显示适配器。CIM 状态均为 OK。没有证据表明它们导致了本次缺少接口错误，因此没有卸载或改动驱动。

当前活动显示器由 Win32 枚举确认：

| 显示器 | 主屏 | 物理像素尺寸 | Windows 屏幕矩形 L,T,R,B | 整屏 PNG 中的矩形 |
| --- | --- | --- | --- | --- |
| DISPLAY1 | 否 | 1440×2560 | -1440,-178,0,2382 | 0,0,1440,2560 |
| DISPLAY2 | 是 | 3840×2160 | 0,0,3840,2160 | 1440,178,5280,2338 |

虚拟桌面原点为 **(-1440,-178)**，尺寸为 **5280×2560**。显示器上下错位造成的空白区域可以在整屏截图中出现，不能把它们误认成全屏截图失败。

## 复现结果

1. 官方 `sky.list_windows()`：成功。
2. 项目资源管理器窗口，`include_screenshot: true, include_text: false`：报 `SetIsBorderRequired failed: 不支持此接口 (0x80004002)`。
3. 重新枚举、重新选择同一窗口后重试一次：同样报错。
4. 同窗口，`include_screenshot: false, include_text: true`：成功，文本树非空。
5. Pillow 全桌面截图：成功，RGB 各通道有变化，并已目视检查图像结构。

原始文档中的微信、小程序和旧沙箱失败属于历史记录。本次没有打开拼多多订单页面，因此不声称已经验证订单窗格的内容完整性。
