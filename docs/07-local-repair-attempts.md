# 本地修复试验与完整回退

日期：2026-09-21。执行于用户进一步要求“尝试修复本地的功能”之后。

**结果：已实际尝试两条本地修复路线，均未恢复官方原生截图；全部试验性安装改动已回退。**

## 试验前状态

上一阶段仓库提交为 `880fdd2`，工作区干净。原始资料基线仍为 `2df52f4`。

当前运行时中存在两个不同的官方原生组件：

| 组件 | SHA-256 | 签名 |
| --- | --- | --- |
| 原 Rust 后端 `codex-computer-use.exe` | `d09a2f3f4c144be9c180509f5cd67d60f4b0b6fbb62e0f5a1ee131f4b653c512` | Valid，OpenAI OpCo |
| 同包 Swift 后端 `swift/x64/codex-computer-use-swift.exe` | `0b7cc4470027d04c37821c1fc61039853856d024343d04d37d66d9c0e0281d57` | Valid，OpenAI OpCo |

这两个组件不能仅凭名称或方法名相同就断言可以互换。本轮通过真实加载与官方 API 验证，而不是直接构造私有协议请求。

## 路线 A：使用已安装的签名有效的 Swift 后端

脚本：[switch-capture-backend.ps1](../scripts/switch-capture-backend.ps1)。

操作：校验原后端以及 Swift 程序和三个配套 DLL 的哈希、签名；备份原文件；停止匹配的辅助进程；将 Swift 程序原样复制到原入口并复制配套 DLL。由应用正常启动辅助程序，不手动伪造工具响应。

验证：

- `sky.list_windows()` 成功，返回资源管理器和微信等实际窗口。
- 对项目资源管理器调用 `get_window_state`，请求截图与文本时失败：`computer-use helper exited with exit code 3221226505`，即 `0xC0000409`。
- 该退出码本身不足以确认崩溃的具体原因；本轮未进行 Swift 崩溃转储分析。

处置：立即恢复原程序，验证原哈希和 Valid 签名；清理仅由此次试验添加的三个 DLL。Swift 目录内的原文件始终未改写。

备份和部署清单：`artifacts/backups/swift-backend-20260921/`，状态 `rolled-back`。

## 路线 B：跳过可选边框关闭，保留默认边框

脚本：[repair-wgc-compat.ps1](../scripts/repair-wgc-compat.ps1)。这是失败实验的可复现记录，**不是推荐安装的补丁**。

静态定位依据：原后端包含对应错误字符串；反汇编显示 `SetIsCursorCaptureEnabled` 成功后，会查询另一个接口并以 false 设置边框属性，成功后才调用 `StartCapture`。

实验仅针对上表中的原文件哈希和本机确实缺失该属性的情况：

| 项目 | 值 |
| --- | --- |
| 文件偏移 | 251911 / `0x3D807` |
| 虚拟地址 RVA | `0x3E407` |
| 原指令字节 | `48 83 64 24 60 00` |
| 实验字节 | `E9 95 00 00 00 90` |
| 分支目标 RVA | `0x3E4A1`，既有 StartCapture 代码入口 |
| 实验文件 SHA-256 | `2c5bb0414f98e25f95b18cd18c2e7c2d64d1d820021b721b45b60b7ef4ec57eb` |

补丁跳过可选的关闭边框操作，不跳过应用授权、URL 策略或其他访问检查；没有注入新代码段，也没有更改操作系统信任策略。字节变更使原 Authenticode 哈希不再匹配，该副作用在执行前已经说明，最终随回退消除。

实际结果：

1. `SetIsBorderRequired` 错误消失。
2. 首次窗口截图变为 `FrameArrived timed out: timed out waiting on channel`。
3. 激活目标窗口后按恢复流程再试，变为 `window capture timed out: timed out waiting on channel`。
4. 对左屏上的另一个资源管理器窗口试验也超时。
5. 为排除前一次工作线程卡住的影响，恢复原文件后重新应用同一补丁、使用全新的辅助进程，先对左屏取图，仍出现 `FrameArrived timed out`。

结论：已验证边框设置是原先遇到的首个阻断点，但当前后端还存在没有收到捕获帧的问题。未取得足够证据将后者归因于某个虚拟显示驱动、系统补丁或 GPU。

两次补丁备份分别位于：

- `artifacts/backups/wgc-default-border-20260921/`
- `artifacts/backups/wgc-left-display-20260921/`

两份清单最终状态均为 `rolled-back`。没有保留实验补丁作为工作版本。

## 回退时处理的进程问题

捕获操作会派生一个同名的系统光标管理子进程。初版脚本把它视为第二个独立辅助会话，因此主动拒绝批量终止。核对父子关系与角色后，脚本只终止唯一的主辅助进程，并等待其光标子进程自行恢复状态和退出。

Windows 在进程退出后曾短暂保留文件映射，第一次恢复复制被占用错误阻止。重试后恢复成功；脚本现加入有上限的短时复制重试。没有结束主 ChatGPT 应用，也没有批量结束其他任务进程。

## 最终状态核验

| 检查 | 结果 |
| --- | --- |
| 已安装辅助程序哈希 | 与原始 Rust 程序完全相同 |
| Authenticode | Valid |
| 安装目录新增的三个 DLL | 均已移除；原 Swift 目录不变 |
| 官方窗口枚举 | 成功 |
| 官方可访问性文本 | 成功，项目窗口文本树非空 |
| 备用 GDI 主屏截图 | 成功，3840×2160 |
| 官方原生截图 | 仍未修复 |
| 系统、驱动、全局权限设置 | 未改动 |

结构化记录见 [local-repair.json](evidence/2026-09-21-local-repair.json)。二进制备份、反汇编和截图都保留在 Git 忽略的 `artifacts` 下，没有加入提交。

## 如何检查当前状态

在项目目录命令提示符中执行：

```bat
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts\repair-wgc-compat.ps1 -Mode Status
```

本轮最终应为 `IsOriginal: true`、`IsPatched: false`、`Signature: Valid`。实验脚本的默认模式只读取状态；当前已回退，无需再次执行 Apply 或 Rollback。

下一步应先做独立 WGC 最小复现，定位设备、帧池与帧事件链路，再决定是否需要后端源码修复或系统 / 驱动维护。不能根据这两次失败就断言重装某个运行库、升级系统或卸载虚拟显示器一定有效。
