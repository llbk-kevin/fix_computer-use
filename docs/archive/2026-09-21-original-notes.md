# Computer Use截图失败总结

对，你看到的不是“完全失败”。准确说是：

- **可访问性文本成功**：我能读到小程序暴露给 Windows UI Automation 的文本树，所以能看到订单内容、`查看全部`、`实付`等。
- **像素截图失败**：我没能拿到真正的屏幕/窗口 bitmap，所以没法生成 `01-原始截图` 所需图片。

**刚刚尝试过的截图/获取思路**

1. **Computer Use 窗口截图**
    - 目标：`WeChatAppEx.exe` 的 `拼多多` 窗口。
    - API：`get_window_state({ include_screenshot: true })`
    - 结果：失败。
    - 错误：`SetIsBorderRequired failed: 不支持此接口 (0x80004002)`
    - 推断：Computer Use 底层的 Windows Graphics Capture 对这个环境/窗口组合不兼容。
2. **Computer Use 文本状态**
    - API：`get_window_state({ include_screenshot: false, include_text: true })`
    - 结果：成功。
    - 这就是为什么我能读到 `12 文本 查看全部`。小程序实际左右分屏，可访问性树同时暴露左边“个人中心”和右边“我的订单”。
3. **微信主窗口截图**
    - 目标：外层微信主窗口。
    - 结果：同样失败，还是 `0x80004002`。
    - 说明问题不只是拼多多小程序右侧窗格，而是当前 Computer Use 截图层更普遍地失败。
4. **Win32 枚举窗口 + PIL 抓窗口**
    - 思路：用普通 Windows API 找标题为 `拼多多` 的窗口，再截窗口矩形。
    - 结果：普通 Win32 枚举找不到这个小程序窗口标题；Computer Use 给的窗口 id 也不是可直接传给 `GetWindowRect` 的 HWND。
    - 这类小程序窗口可能是特殊宿主/子窗口/合成窗口，不一定像普通桌面窗口那样暴露。
5. **PIL ImageGrab 整屏截图**
    - 思路：不找窗口，直接抓整屏，然后裁右侧订单区域。
    - 结果：沙箱内失败：`OSError: screen grab failed`。
    - 申请沙箱外执行时被系统拒绝，原因是当前用量限制，不是技术判断。

**哪些被 skill 规范限制**

Computer Use skill 明确要求：Windows APP 自动化要优先用 Computer Use，不要一上来绕到 PowerShell/SendKeys/自写 UI Automation。

被限制或不宜做的包括：

- 用 PowerShell `SendKeys`、鼠标模拟、窗口前台控制来替代 Computer Use。
- 通过 Windows Run、终端窗口、文件管理器 UI 间接执行命令。
- 在同一轮里混用 Computer Use 和直接 PowerShell UI Automation 去控制同一个 APP。
- Computer Use 截图失败后继续用 stale 坐标盲点、盲滚。

但**纯截图读取像素**本身不等于 UI 自动化控制。比如 `PIL.ImageGrab`、DXGI、GDI 截屏属于读屏幕像素；它不点击、不输入、不改 APP 状态。这个方向不是 skill 本身禁止，主要是被沙箱/权限挡住了。

**哪些被沙箱挡住**

- `PIL.ImageGrab.grab()` 整屏截图在沙箱内失败。
- 请求沙箱外执行整屏截图被系统拒绝。这个拒绝来自当前平台用量/审批限制。

**一般其他 APP 截屏怎么做**

常见路径有几类：

1. **Computer Use / Windows Graphics Capture**
    - 正常情况下，Computer Use 通过 Windows Graphics Capture 抓窗口。
    - 优点：可以抓被遮挡窗口，适合窗口级自动化。
    - 限制：某些窗口、GPU/权限/系统组合会失败。
2. **GDI / BitBlt / PrintWindow**
    - 老派 Win32 截屏。
    - 对传统桌面 APP 很好用。
    - 对 Chromium、Electron、微信小程序、游戏、硬件加速窗口可能黑屏或不完整。
3. **DXGI Desktop Duplication**
    - 抓整个显示器帧。
    - 游戏录屏、截图工具常用类似路径。
    - 优点：接近真实屏幕。
    - 限制：需要桌面会话权限，沙箱里常失败。
4. **Windows Graphics Capture API**
    - Windows 10+ 官方现代截图 API。
    - 能抓窗口或显示器。
    - 需要窗口兼容和权限，Computer Use 大概率用的是这类路径。
5. **应用自身 API**
    - 浏览器：Chrome DevTools Protocol 截图。
    - Electron：有时可走内部页面截图。
    - 手机/模拟器：ADB screenshot。
    - 这些通常比屏幕像素抓取更稳定。
6. **系统截图工具**
    - Snipping Tool、Snipaste、ShareX 这类。
    - 通常有更高权限、更完整的桌面访问，也会做大量窗口识别兼容。

**Snipaste 是怎么做到吸附边框的**

不看源码只能讲通用实现，但大致是这样：

1. **全局热键进入截图模式**
    - 注册全局快捷键。
    - 创建一个全屏透明/半透明 overlay 覆盖所有显示器。
    - overlay 接收鼠标移动、绘制高亮框。
2. **鼠标下窗口识别**
    - 鼠标移动时调用类似：
        - `WindowFromPoint`
        - `ChildWindowFromPointEx`
        - `GetAncestor`
        - `GetWindowRect`
        - `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`
        - UI Automation hit test
    - 它会判断鼠标下是哪个窗口、控件、子区域，然后画出边框。
3. **边界修正**
    - 直接 `GetWindowRect` 往往不准，因为有阴影、DPI 缩放、无边框窗口、透明边缘。
    - 所以会结合 DWM 扩展边框、DPI 信息、多显示器坐标做修正。
    - 有些工具还会做图像边缘检测，辅助识别实际可见边界。
4. **截图像素获取**
    - 可能用 GDI `BitBlt`、DXGI Desktop Duplication、Windows Graphics Capture，或多套 fallback。
    - 截图 overlay 自己会临时隐藏或从捕获结果中排除，否则会把自己的遮罩截进去。
5. **为什么它比普通脚本准**
    - 它是专门的桌面程序，不在我们的沙箱里。
    - 它长期适配各种窗口类型、DPI、透明边框、多屏。
    - 它可以实时 hit test 鼠标下的 HWND/控件，再把结果视觉化。

所以这次最现实的改进方向是：用类似 Snipaste 的“整屏抓取 + 右侧窗格裁剪 + Computer Use 翻页”方案。但在当前 Codex 沙箱里，整屏抓取权限被挡住；如果由你手动触发 Snipaste 截图，或者允许一个本地非沙箱脚本抓屏，那就会容易很多。

- Computer Use截图失败，系统版本原因
    
    如果 Computer Use 截图 get_window_state({ include_screenshot: true }) 失败，并报：SetIsBorderRequired failed: 不支持此接口 (0x80004002)，那么可能是Windows版本问题。
    
    请先检查 Windows 版本和 WinRT API 支持情况，我的机器是 Windows 10 Enterprise LTSC 2021 21H2，build 19044.x。Microsoft 文档显示 Windows.Graphics.Capture.GraphicsCaptureSession.IsBorderRequired 从10.0.20348.0 才引入。
    
    可用 ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired") 验证；如果返回 False，那么这是 Computer Use native 截图层无条件调用较新 API 导致的兼容性问题。
    
- 双屏截图，坐标说明：
    
    当前机器是双屏虚拟桌面：
    
    - 左侧是竖屏
    - 右侧是 4K 横屏
    - Windows 虚拟桌面原点不是当前 4K 屏左上角，ImageGrab 截到的是整个虚拟桌面。
    
    所以不要直接用“人眼屏幕坐标”裁图，必须先保存一张整张虚拟桌面截图，再在这张图的像素坐标里定位拼多多窗口。
    
    已知可用流程：
    
    1. 先用脚本全屏截图：
    python tools\capture_pdd_order_pane.py --screen --method auto --full --index <debug>
    2. 查看整屏图，定位拼多多窗口。
    3. 正式截图命令示例：
    python tools\capture_pdd_order_pane.py --screen --method auto --crop 3025,215,3525,1665 --index 1