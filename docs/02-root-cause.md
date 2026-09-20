# 根因分析

## 直接原因

官方窗口截图在设置 `GraphicsCaptureSession.IsBorderRequired` 时失败。本机 WinRT 能力探测返回该属性不存在，错误为 `0x80004002`。资源管理器窗口也可复现，说明当前问题不需要微信小程序参与。

Microsoft 将 `IsBorderRequired` 的引入版本标为 **10.0.20348.0**、`UniversalApiContract` v12；本机为 19044.1620，且属性和合约实测均缺失。[Microsoft API 说明](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.isborderrequired?view=winrt-26100)

可以确认的是：**当前原生截图路径没有成功处理这个缺失的可选接口，导致整次窗口截图失败。** 未取得原生源码，因此“具体哪一行无条件调用”“是否存在但失效的版本判断”仍属于推断，不写成已完成源码定位。

## 为什么能读文字，不能拿到图片

两条链路使用不同能力：

```text
sky.get_window_state
  ├─ include_text=true       → UI Automation → 成功取得文本树
  └─ include_screenshot=true → Windows Graphics Capture
                                └─ 设置 IsBorderRequired → 接口不存在 → 失败

tools/capture_screen.py      → Pillow / Windows GDI → 可见桌面像素 → 成功
```

文本树成功不能作为像素截图成功的证据；备用桌面截图成功也不能作为官方窗口 API 已修复的证据。

## 当前不能通过配置解决的部分

安装包 `@oai/sky` 0.7.1 的 `WindowsOptions` 仅声明 `target: "windows"`；`GetWindowState.Input` 提供窗口对象以及截图、文本开关。本次检查的公开类型声明与插件文档未提供 GDI 后端切换或边框设置参数。

原生捕获实现不在本项目内。当前仓库没有可编译并替换该实现的官方源码。因此本次交付不包含原生二进制补丁，也没有用修改 JavaScript 返回值的方式伪造成功。

Microsoft 建议先在运行时检查 WinRT API 是否存在，再使用新增功能。这是后端兼容修复的合适方向：在旧系统保留默认边框、继续基本捕获，并为真正的捕获故障保留明确错误。[版本适配代码指南](https://learn.microsoft.com/en-us/windows/apps/develop/testing/version-adaptive-code)

## 同时发现但应分开处理的问题

### 捆绑 PowerShell 的 CET 启动失败

直接运行 Codex 捆绑的 `pwsh.exe --version` 会在执行项目命令前退出：

```text
Fatal error.
Your Windows doesn't fully support CET. Please install all available Windows updates.
```

退出码为 `-2146233082`；该运行时声明 .NET 10.0.11。通过 `cmd.exe` 明确调用系统 Windows PowerShell 5.1，可成功完成 WinRT 诊断。它是本次采用的命令入口适配措施。

这个错误与 WGC 属性缺失分别得到复现，不能认为修好 PowerShell 就会自动修好截图。具体适用的 Windows 更新、系统补丁状态或兼容运行时版本还需单独核对，当前没有确认某个 KB 为唯一修复项。

### 原始记录中的沙箱失败

历史文档记录了 `PIL.ImageGrab` 在当时沙箱中失败及一次申请被拒绝。本次环境是 unrestricted，真实截图成功，因此历史失败不能被用来证明当前桌面不可访问；本次成功也不保证重新开启沙箱后继续可用。

### 多屏负坐标和 DPI

Windows 屏幕原点与合成 PNG 原点不同。当前图片坐标为 `screen_x + 1440, screen_y + 178`，并且必须使用物理像素。Pillow 文档明确说明，在 Windows 上使用 `all_screens=True` 时桌面左上角可以为负坐标。[Pillow ImageGrab 文档](https://pillow.readthedocs.io/en/stable/reference/ImageGrab.html)

本次工具显式启用每显示器 DPI 感知，枚举当前布局，检查截图尺寸和布局一致性，再转换裁剪矩形。旧笔记的固定裁剪数字仅保留作历史示例。

## 当前排障不优先做的事项

- 重装微信、Notion、VC++ 或所有 .NET：没有证据可使缺失的 WGC 系统接口出现。
- 更改截图隐私权限、关闭安全功能或解除全局 PowerShell 执行策略：本次诊断与截图无需这些持久改动。
- 下载零散系统 DLL、伪造系统版本、对官方二进制做未验证的补丁：无法提供可靠的接口实现与验收保障。
- 仅靠 Win10 累积更新的版本号增加，就假定具备 20348 引入的能力：仍须实测 `IsPropertyPresent`。
