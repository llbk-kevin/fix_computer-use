# Computer Use 截图故障排查

2026-09-21 在本机完成基线归档、根因验证和桌面像素截图替代方案。

**当前状态：备用截图已可用；官方 Computer Use 原生窗口截图仍未恢复。**

后续已实际尝试切换包内签名有效的 Swift 后端，以及对原后端应用保留默认捕获边框的版本限定补丁。前者在截图时崩溃，后者进入捕获阶段后等待图像帧超时；两项均已完整回退，原始程序哈希和有效签名已恢复。详见 [本地修复试验与回退](docs/07-local-repair-attempts.md)。

| 项目 | 实测结果 |
| --- | --- |
| Windows | Windows 10 Enterprise LTSC 2021，21H2，19044.1620 |
| 官方窗口截图 | `SetIsBorderRequired failed: 不支持此接口 (0x80004002)` |
| Windows 能力 | WGC 可用，但 `GraphicsCaptureSession.IsBorderRequired` 不存在 |
| Computer Use 文本树 | 资源管理器窗口读取成功 |
| 本项目备用截图 | 整屏 5280×2560、主屏 3840×2160、局部 1000×700 均成功 |
| 附带发现 | Codex 捆绑 PowerShell 因 CET 错误启动失败；Windows PowerShell 5.1 可运行诊断 |

原始材料先提交为 `2df52f4`：`docs(baseline): 保存 Computer Use 截图故障原始线索`。随后才开始新增排障脚本和整理文档。仓库仅用于本地追溯，没有配置远端或推送。

## 文档导航

1. [本机环境与证据](docs/01-environment-and-evidence.md)：哪些能力存在、哪些缺失，以及证据边界。
2. [根因分析](docs/02-root-cause.md)：解释 WGC、UI Automation、CET 与沙箱之间的区别。
3. [分阶段修复计划](docs/03-repair-plan.md)：当前恢复措施、官方后端修复、系统迁移备选方案。
4. [截图工具使用说明](docs/04-capture-guide.md)：整屏、单屏、裁剪及双屏坐标转换。
5. [验收、执行记录与回退](docs/05-validation-and-rollback.md)：通过项、未通过项和复测命令。
6. [官方后端问题报告草稿](docs/06-upstream-report.md)：最小复现和预期兼容行为，尚未发送。
7. [本地修复试验与回退](docs/07-local-repair-attempts.md)：实际部署过的两条路线、后续捕获超时及回退证明。

[原始线索](docs/archive/2026-09-21-original-notes.md) 保持内容不变；[环境摘要](docs/evidence/2026-09-21-environment.json) 可机器读取。

## 立即使用

在项目目录下打开命令提示符，执行：

```bat
python tools\capture_screen.py --list-monitors
python tools\capture_screen.py --full
python tools\capture_screen.py --monitor 2
```

本机已有 Python 3.12.7 和 Pillow 12.2.0，无需安装额外截图依赖。截图和 JSON 元数据默认保存到 `artifacts/screenshots/`，该目录已被 Git 忽略。每次使用新的默认文件名，不覆盖已有结果。

这个工具读取可见桌面像素，适合先恢复截图任务；它不会让 `sky.get_window_state({ include_screenshot: true })` 自动成功，也不能获取被其他窗口遮住的内容。原生窗口截图的完整修复以文档中的单独验收条件为准。
