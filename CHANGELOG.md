# 更新日志

## 0.2.0 — 2026-10-21

### 新增：安装期检测 + 一键安装

- `launcher/check_extension.ps1`（双击 `检查插件.cmd`）：在同步前检测「即将同步的那个浏览器」到底有没有加载插件。
  退出码 `0` 已就绪 / `2` 没装 / `1` 环境不对，`-Json` 输出机器可读结果。
- `launcher/install_extension.ps1`（双击 `安装插件.cmd`）：Edge 一键装。备份 `Local State` → 等浏览器自己退出 →
  带 `--load-extension` + `--restore-last-session` 重启 → 轮询 `/health` 等心跳 → 桌面建「带插件启动」快捷方式。
  Chrome 品牌版只能手动装一次，脚本把扩展目录复制到剪贴板并打开 `chrome://extensions` 引导。支持 `-DryRun`。
- `launcher/launch_with_extension.ps1`：日常启动器（桌面快捷方式指向它）；浏览器已在带插件运行就直接返回 0。
- `launcher/lib_browser.ps1`：浏览器发现（Edge / Chrome / Firefox）、心跳检测、启动参数生成。
  三个脚本共用一份判定逻辑，不会出现「检测说没装、安装以为装了」。

### 改进：桥接服务

- `/health` 新增 `instances_detail`（每个实例最近心跳时间 + 浏览器类型）和 `browsers`（去重后的浏览器集合），
  检测不再依赖 `Win32_Process` 命令行。
- 实例 ID 改成 `edge-…` / `chrome-…` / `firefox-…` 前缀，服务端兼容旧的 `i…` 格式。

### 文档

- README：新增「日常浏览器没装插件？先检测，再一键装」小节；新增坑 11（品牌版 Chrome 硬禁 `--load-extension`，
  以及为什么**不要**用 `--disable-extensions-except`）；已知限制补「检测靠心跳」与 Chrome 手动安装；目录结构同步更新。
- `docs/PROTOCOL.md`：补 `/health` 新字段与实例 ID 格式；修正 `/health` 鉴权说明（实际需要令牌）。

### 修复

- `install_extension.ps1` / `launch_with_extension.ps1` 的 Chrome 分支：空参数 `Start-Process` 被吞异常、重复 if/else。
- 检测脚本「上次安装过（）」空括号提示，改为按 `installedAt / checkedAt` 与 `mode` 分别给话术。

### 兼容性

- Edge / Chrome ≥ 137。Chrome 命令行加载扩展自 137 起被品牌版禁用，只能手动装一次（装完持久保存）。

## 0.1.0 — 初始版本

- 本地桥接服务（纯 Python 标准库）+ MV3 扩展 + PowerShell 启动器；默认无头无窗口运行。
- `ping` / `info` / `tabs.list` / `tab.open` / `tab.close` / `tab.activate` / `tab.navigate` / `tab.reload` /
  `page.eval` / `page.waitFor` / `page.click` / `page.type` / `page.text` / `page.html` / `page.screenshot` /
  `cookies.get` / `cookies.set` 共 17 个 action。
