# Computer Use 截图故障排查与修复

2026-09-21 在本机完成基线保存、故障定位、备用截图工具和原生截图的本地兼容修复。

**当前状态：官方 Computer Use 原生截图已在资源管理器中恢复，连续截图与文字读取验收通过；备用截图工具继续可用。**

当前安装的是针对单一版本的本地兼容层：保留默认捕获边框，并使用 D3D11 纹理读取避开回调内的异步转换等待。已通过官方 `sky.get_window_state` 验收，并验证完整回退与重新安装。当前程序不再具有有效厂商签名，原文件已完整备份；详见 [原生修复与回退说明](docs/09-原生截图兼容修复与验收.md)。微信小程序业务页及完整应用更新或重启尚未验收。

前两轮 Swift 后端切换和仅跳过边框设置的失败试验已回退，历史记录见 [本地修复试验与完整回退](docs/07-本地修复试验与完整回退.md)。

| 项目 | 实测结果 |
| --- | --- |
| Windows | Windows 10 Enterprise LTSC 2021，21H2，19044.1620 |
| 原版窗口截图 | `SetIsBorderRequired failed: 不支持此接口 (0x80004002)` |
| 当前本地兼容版本 | 官方窗口截图与文字读取成功；回退后重新安装复测通过 |
| Windows 能力 | WGC 可用，但 `GraphicsCaptureSession.IsBorderRequired` 不存在 |
| Computer Use 文本树 | 与截图同时读取成功，最终连续三次文本树长度 7637、7688、7688 |
| 本项目备用截图 | 整屏 5280×2560、主屏 3840×2160、局部 1000×700 均成功 |
| 附带发现 | Codex 捆绑 PowerShell 因 CET 错误启动失败；Windows PowerShell 5.1 可运行诊断 |

原始材料先提交为 `2df52f4`：`docs(baseline): 保存 Computer Use 截图故障原始线索`。随后才开始新增排障脚本和整理文档。原文和归档目录已按要求从工作区移除，Git 历史仍可追溯。

项目文件夹名称为 `fix_computer-use`，同步到同名的 [GitHub 私有仓库](https://github.com/llbk-kevin/fix_computer-use)。远端为 `origin`，主分支为 `main`；截图、二进制备份和完整诊断输出留在本机的 `artifacts/` 中，不加入提交。

## 文档导航

1. [本机环境与证据](docs/01-本机环境与证据.md)：哪些能力存在、哪些缺失，以及证据边界。
2. [根因分析](docs/02-根因分析.md)：解释 WGC、UI Automation、CET 与沙箱之间的区别。
3. [分阶段修复计划](docs/03-分阶段修复计划.md)：当前恢复措施、官方后端修复、系统迁移备选方案。
4. [截图工具使用说明](docs/04-截图工具使用说明.md)：整屏、单屏、裁剪及双屏坐标转换。
5. [验收、执行记录与回退](docs/05-验收执行记录与回退.md)：通过项、未通过项和复测命令。
6. [官方后端问题报告草稿](docs/06-官方后端问题报告草稿.md)：最小复现和预期兼容行为，尚未提交给维护者。
7. [本地修复试验与完整回退](docs/07-本地修复试验与完整回退.md)：实际部署过的两条路线、后续捕获超时及回退证明。
8. [目录迁移与仓库维护](docs/08-目录迁移与仓库维护.md)：更名后的路径检查、Git 状态和同步方式。
9. [原生截图兼容修复与验收](docs/09-原生截图兼容修复与验收.md)：当前有效修复、实际验收、版本限制与恢复命令。
10. [工具入口与配置排查](docs/10-工具入口与配置排查.md)：`node_repl` 的作用、CC Switch 检查结果及只读复查工具。

[环境摘要](docs/evidence/2026-09-21-environment.json) 可机器读取。原始资料可从基线提交 `2df52f4` 查阅。

## 检查原生修复状态

在项目目录的命令提示符中执行：

```bat
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts\install-wgc-readback.ps1 -Mode Status
```

当前应为 `IsReadbackCompat: true`、`CompanionMatches: true`、`BackupExists: true`。正常任务仍通过官方 `@oai/sky` 调用截图，并处理对应的应用授权。无需重复执行安装脚本。

## 备用截图工具

在项目目录下打开命令提示符，执行：

```bat
python tools\capture_screen.py --list-monitors
python tools\capture_screen.py --full
python tools\capture_screen.py --monitor 2
```

本机已有 Python 3.12.7 和 Pillow 12.2.0，无需安装额外截图依赖。截图和 JSON 元数据默认保存到 `artifacts/screenshots/`，该目录已被 Git 忽略。每次使用新的默认文件名，不覆盖已有结果。

这个工具读取可见桌面像素，供原生链路不可用时临时截图，也不能获取被其他窗口遮住的内容。当前 `sky.get_window_state({ include_screenshot: true })` 的恢复来自前述原生兼容层，两者各自保留独立验收记录。
