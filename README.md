# Edge AI Bridge

让 AI 直接接管你的 Edge 浏览器 —— 复用它已有的登录态，全程**没有窗口**，不抢你的鼠标、不弹窗、不打扰你。

> 一句话概括：一个浏览器扩展 + 一个本地 HTTP 服务，把「操作浏览器」变成「发一条 HTTP 请求」。

```
python examples/client.py open https://example.com
python examples/client.py eval "document.title"
# -> Example Domain
```

---

## 为什么做这个

我想让 AI 帮我处理一个需要在网页上点几十次的任务。试过的方案都有硬伤：

| 方案 | 问题 |
| --- | --- |
| Playwright / Puppeteer | 会启动一个**新的可见浏览器窗口**，在你眼前弹出来；而且新 profile 没有你的登录态，得重新扫码登录 |
| 直接调 CDP | 要自己管进程、管端口、管重连，而且 `--remote-debugging-port` 一旦暴露在公网上就是灾难 |
| 油猴脚本 | 只能在自己注入的那个页面里活动，跨页面、开新标签、截图都做不到 |
| 让用户手动操作 | 那还要 AI 干什么 |

于是有了这个项目。核心诉求只有三条：

1. **复用真实浏览器** —— 登录态、Cookie、扩展、指纹全都在，不用重新认证
2. **绝对不可见** —— 不能有任何窗口跳出来打扰人
3. **AI 侧接口要简单** —— 就一条 HTTP 请求，不依赖特定语言的 SDK

---

## 效果

`launcher/selftest.ps1` 的真实输出：

```
>>> 启动桥接服务（端口 8811）
>>> 启动无头 Edge
>>> 等待扩展连上（最多 15 秒）
  [OK] 扩展已连上：igqzw3ck7mvehj4cc
>>> ping
  [OK] 浏览器有响应
>>> 打开 https://example.com（后台标签页）
  [OK] tabId=521483335
>>> 等 body 出现
  [OK] 页面已渲染
>>> 读 document.title
  [OK] 标题：Example Domain
>>> 在页面里执行复杂 JS
  [OK] 链接 1 个，正文 917 字
>>> 页面里 await 一个 Promise
  [OK] Promise 能被正确等待
>>> 截图
  [OK] 已保存 examples\selftest.png（51 KB）
>>> 关闭标签页
  [OK] 已关闭
>>> 检查是否真的没有可见窗口
  [OK] 本实例进程 16 个，其中带主窗口的 0 个
  [OK] 确认：全程无可见窗口
```

注意最后两行 —— 这不是「窗口挪到屏幕外面」那种自欺欺人，是真的一个窗口都没创建。

---

## 架构

```
┌──────────────┐   POST /push    ┌────────────────┐   GET /task   ┌─────────────────────┐
│  AI / 脚本    │ ──────────────> │  桥接服务       │ <──────────── │  Edge 扩展           │
│  client.py   │                 │  bridge.py     │               │  ├ background.js    │
│              │ <────────────── │  127.0.0.1:8800│ ────────────> │  │  (真正干活)       │
└──────────────┘   GET /done     └────────────────┘   POST /ack    │  └ offscreen.js     │
                                                                  │     (轮询，常驻)     │
                                                                  └──────────┬──────────┘
                                                                             │ chrome.scripting
                                                                             │ world: "MAIN"
                                                                  ┌──────────▼──────────┐
                                                                  │  无头 Edge 实例      │
                                                                  │  --headless=new     │
                                                                  │  独立 user-data-dir │
                                                                  └─────────────────────┘
```

### 为什么是「轮询」而不是「服务端推」

扩展**没有办法**主动监听一个本地端口。它不能开 socket server，也不能长轮询之外的方式被唤醒。
所以只能是扩展主动向服务端拉 —— 方向是反的，这是整个设计的地基。

### 为什么轮询放在 offscreen 文档里

MV3 的 service worker **空闲约 30 秒就会被浏览器杀掉**，`setInterval` 跟着一起没。
如果轮询写在 background.js 里，你会遇到「刚启动好用，半分钟后就不响应了」的诡异现象。

`chrome.offscreen` 创建的文档生命周期独立，可以常驻。它不能调 `chrome.tabs` / `chrome.scripting`，
所以只负责收发，真正的浏览器操作 `chrome.runtime.sendMessage` 转给 background。

---

## 快速开始

### 环境要求

- Windows（launcher 是 PowerShell，其他系统可以照着手动拼命令行）
- **Edge / Chrome ≥ 137**（`--headless=new` 支持扩展的版本）
- Python ≥ 3.8（只用了标准库，零依赖）

### 三步

```powershell
# 1. 自检：确认这套东西在你机器上能跑通（会自己起服务、起浏览器、跑一遍、再收摊）
powershell -ExecutionPolicy Bypass -File launcher\selftest.ps1

# 2. 正式启动（完全无窗口，进程后台跑）
powershell -ExecutionPolicy Bypass -File launcher\launch_hidden.ps1

# 3. 用
python examples\client.py open https://example.com
python examples\client.py text
python examples\client.py shot page.png
```

想双击启动、连一闪而过的黑框都不要：

```
wscript.exe launcher\silent.vbs
```

用完收摊：

```powershell
powershell -ExecutionPolicy Bypass -File launcher\stop.ps1 -StopBridge
```

### 作为库用

```python
from examples.client import Edge

e = Edge()                       # 自动读 server/token.txt
tab = e.open("https://example.com")
print(e.eval("document.title", tab_id=tab["tabId"])["value"])
e.screenshot("shot.png", tab_id=tab["tabId"])
e.close(tab["tabId"])
```

---

## 命令一览

| 命令 | 说明 |
| --- | --- |
| `health` / `ping` / `info` | 探活、看实例、看浏览器信息 |
| `tabs` | 列出所有标签页 |
| `open <url>` | 后台新开标签页（**不抢焦点**） |
| `close <tabId>` / `goto <url>` / `reload` | 关、跳、刷 |
| `eval <js>` / `eval @file.js` | 在页面里执行任意 JS，支持 await |
| `wait <selector> [--ms]` | 等元素出现 |
| `click <selector>` | 点元素 |
| `type <selector> <text>` | 写输入框（兼容 React 受控组件） |
| `text [selector]` / `html [selector]` | 取文本 / HTML |
| `shot <path>` | 截图 |
| `cookie <url> <name>` | 读 Cookie |

完整协议见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

---

## 制作方法

从零复现的完整路径，按我实际踩坑的顺序写。

### 1. 先把「通道」想清楚

不要一上来就写扩展。先回答一个问题：**AI 和浏览器谁主动？**

浏览器扩展没有 server 能力，所以只能是扩展拉、AI 推。这一步想错了，后面全要返工。

于是定了三个角色：

- `bridge.py`：队列 + 回执，纯内存，标准库 `ThreadingHTTPServer`
- `offscreen.js`：唯一的网络出口，每秒拉一次
- `background.js`：唯一的执行者，拿着 `chrome.*` 权限

### 2. 写扩展骨架（manifest v3）

```json
{
  "manifest_version": 3,
  "minimum_chrome_version": "116",
  "permissions": ["tabs", "scripting", "storage", "offscreen", "cookies", "activeTab"],
  "host_permissions": ["<all_urls>"],
  "background": { "service_worker": "background.js" }
}
```

`offscreen` 权限必须显式声明，否则 `chrome.offscreen.createDocument` 直接报错。

### 3. 执行器：为什么用 `world: "MAIN"`

```js
await chrome.scripting.executeScript({
  target: { tabId },
  world: "MAIN",        // ← 关键
  func: (src) => (0, eval)(src),
  args: [code],
});
```

默认的 `ISOLATED` world 是一个隔离沙箱，你能看到 DOM，但**看不到页面自己的 JS 变量**。
很多页面把状态挂在 `window.__INITIAL_STATE__` 或者框架的实例上，隔离世界里一片空白。
`MAIN` world 直接在页面真实作用域里跑，`document`、`window`、页面自己的全局变量全都摸得到。

代价是拿不到 `chrome.*` API —— 但你本来也不需要在那里用扩展 API。

顺带解决了异步：`executeScript` 会 await 注入函数返回的 Promise，所以
`page.eval` 里写 `await fetch(...)` 或者 `new Promise(...)` 都能正确拿到结果。

### 4. 轮询器：offline 文档 + 退避

```js
const POLL_INTERVAL = 1000;
const MAX_BACKOFF = 8000;

async function pollOnce() { /* fetch /task → sendMessage → fetch /ack */ }

function loop() {
  clearTimeout(timer);
  pollOnce().catch(() => {}).finally(() => {
    timer = setTimeout(loop, backoff);
  });
}
```

用 `setTimeout` 递归而不是 `setInterval` —— 保证上一次没跑完不会叠加。
连接失败时 `backoff * 1.6` 指数退避，最长 8 秒，别把本地服务打爆。

### 5. 隐形启动：`--headless=new` + 一个隐藏开关

```powershell
msedge.exe `
  --user-data-dir="<独立目录>" `
  --load-extension="<扩展目录>" `
  --disable-extensions-except="<扩展目录>" `
  --disable-features=DisableLoadExtensionCommandLineSwitch `
  --headless=new --disable-gpu --window-size=1440,900
```

三个细节：

- `--headless=new`：老的 `--headless` **不支持扩展**，必须带 `=new`
- `--user-data-dir` 必须独立：不独立会和你日常的 Edge 抢 profile 锁，还会污染你的真实配置
- `DisableLoadExtensionCommandLineSwitch`：见下面坑 3，不加这个扩展根本不会加载

`--window-position=-32000,-32000` 是备选方案：某些页面在无头模式下渲染不对时，
用真实窗口但挪到虚拟屏幕外。进程还在，任务栏能看到，但永远不会跳到你面前。

### 6. 配置注入：让文件替人点弹窗

无头启动时没人去点扩展弹窗填端口和令牌。解法很土但很有效：

launcher 在启动浏览器**之前**，把配置写进 `extension/config.json`；
扩展启动时 `fetch(chrome.runtime.getURL("config.json"))` 读出来塞进 storage。

比去改 Chrome 的 LevelDB 存储靠谱一万倍。

---

## 踩过的坑

这一节是整篇文档里最值钱的部分。每一条都真实发生过，都花了不少时间。

### 坑 1：MV3 service worker 30 秒后自己没了

**现象**：刚启动时命令正常，放着不管半分钟，再发命令就超时。

**原因**：MV3 的 background service worker 空闲约 30 秒就被回收，`setInterval` 一起消失。

**解法**：轮询搬进 `chrome.offscreen` 文档。这个文档的生命周期独立于 SW，可以常驻。

### 坑 2：offscreen 里没有 `chrome.storage`（最阴的一个）

**现象**：扩展装上了，进程也在，`/health` 里 `instances` 永远是空数组 —— **一个请求都没发出去**。

**排查过程**：先用 CDP 连进 offscreen 页面，发现脚本确实加载了、`pollOnce` 是 function、
`stats.polls` 是 0。手动调一次 `pollOnce()`，抓到真正的异常：

```
TypeError: Cannot read properties of undefined (reading 'local')
    at getConfig (offscreen.js:28:34)
```

`chrome.storage` 在这个上下文里是 `undefined`。

**为什么难查**：异常被 `loop()` 里的 `.catch(() => {})` 吞掉了。循环看起来在正常跑，
其实每次都在第一步就挂了。**空 catch 是最贵的代码**。

**解法**：配置改由 background 供给。

```js
// offscreen.js
const r = await chrome.runtime.sendMessage({ type: "get-config" });

// background.js
if (msg.type === "get-config") {
  getConfig().then((config) => sendResponse({ config }));
  return true;   // ← 异步响应必须返回 true
}
```

同时把空 catch 改成记录到 `stats.lastError`，下次至少能在弹窗里看到。

### 坑 3：`--load-extension` 被 Chromium 静默禁用了

**现象**：浏览器起来了，`about:blank` 正常，但 `edge://extensions` 里什么都没有，
`Preferences` 里 `extensions.settings` 是空的 `{}`。**没有任何报错**。

**原因**：Chromium 137 起，出于安全考虑默认屏蔽了 `--load-extension` 命令行开关
（恶意程序曾用它静默安装扩展）。

**解法**：这个屏蔽逻辑挂在 `DisableLoadExtensionCommandLineSwitch` 这个 feature 上，
把它关掉即可：

```
--disable-features=DisableLoadExtensionCommandLineSwitch
```

加上之后立刻就能在 CDP 的 target 列表里看到自己的 service worker 和 offscreen 页面了。

**这条特别值得记**：它不报错、不警告，表现是「浏览器起来了但什么反应都没有」，
极容易误判成网络问题或代码 bug，从而在错误的方向上debug很久。

### 坑 4：PowerShell 重定向遇上 `http_proxy` / `HTTP_PROXY`

**现象**：

```
Start-Process : Item has already been added. Key in dictionary: 'http_proxy'
```

**原因**：系统里同时存在 `http_proxy` 和 `HTTP_PROXY`（大小写不同但 Windows 环境变量不区分），
`Start-Process -RedirectStandardOutput` 在构造环境块时会因为这个重复键直接抛 `ArgumentException`。

**解法**：干脆不用 PowerShell 重定向。给 `bridge.py` 加个 `--log` 参数，让进程自己写日志。
顺带还能解决另一个问题 —— 见坑 5。

### 坑 5：`pythonw` 下 `sys.stdout` 是 `None`，而且 Tee 会递归到爆栈

**现象**：用 `pythonw.exe`（无控制台）后台启动，日志文件一直是空的。

**原因**：两层。

1. `pythonw.exe` 是 GUI 子系统程序，`sys.stdout` / `sys.stderr` 都是 `None`
2. 我写的 `Tee.write()` 里调 `sys.stdout.write()`，而 `sys.stdout` 已经被替换成 Tee 自己
   → 无限递归

**解法**：赋值前先把原始流存下来，并且对 `None` 做保护。

```python
class Tee:
    def __init__(self, path):
        self.out = sys.stdout          # 先存下来
        self.f = open(path, "a", encoding="utf-8", buffering=1)

    def write(self, s):
        if self.out is not None:       # pythonw 下是 None
            self.out.write(s)
        self.f.write(s)
        self.f.flush()
```

### 坑 6：`about:blank` 没有注入权限

**现象**：

```
Cannot access contents of url "about:blank".
Extension manifest must request permission to access this host.
```

**原因**：无头浏览器启动时的前台标签页是 `about:blank`，`<all_urls>` 不覆盖它。
所有不带 `tabId` 的命令都打到了这一页上。

**解法**：background 里记一个 `lastTabId`，`tab.open` / `tab.navigate` 时更新，
`resolveTab` 的优先级是：显式传入 → `lastTabId` → 最近一个 http(s) 页 → active 页。

这也顺带修好了另一个体验问题：用户 `open` 了一页，接着 `text`，直觉上就该读那一页，
而不是「当前窗口的激活页」。

### 坑 7：`captureVisibleTab` 只能截「当前可见标签页」

**现象**：截图返回空白或者报错。

**原因**：这个 API 截的是窗口的可见区域，不是某个 tab 的渲染结果。tab 在后台就截不到。

**解法**：截之前先 `chrome.tabs.update(tabId, { active: true })` 把它切到前台，等 300ms 再截。
无头模式下这个操作没有副作用（反正也看不见）。

### 坑 8：轮询间隔比任务耗时短 → 同一个任务被执行多次

这是在另一个项目里踩到的，教训同样适用。

**现象**：一个「提交评分」的任务被重复执行了 6 次，全都返回同样的结果。

**原因**：轮询 1.5 秒一次，任务要跑 5 秒。第一次没 ack 完，第二次又取到了同一个任务。

**解法**：两层保险。

1. **任务带显式 ID**，ack 时只出队 id 匹配的队头
2. **页面侧加锁**：任务 id 记在 `window.__done` 里，重复的直接返回 `DUP-SKIP`

客户端也要能识别重复结果，别把 `DUP-SKIP` 当成真实返回。

### 坑 9：本机回环地址被系统代理劫持

**现象**：

```
ConnectionAbortedError: [WinError 10053] 您的主机中的软件中止了一个已建立的连接
```

**原因**：环境里设了 `HTTP_PROXY=http://127.0.0.1:60898`，`urllib` 把发往 `127.0.0.1` 的请求
也丢给了代理，代理当然不认识。

**解法**：客户端显式禁用代理，比改环境变量干净：

```python
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
```

### 坑 10：别用进程名杀 `msedge.exe`

**现象**：为了清理测试实例，`taskkill /IM msedge.exe`，结果把用户正在写文档的浏览器一起关了。

**教训**：这是最严重的一类错误 —— **你的进程和用户的进程长得一模一样**。

**解法**：按 `user-data-dir` 精确匹配命令行，只杀自己拉起来的那些：

```powershell
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
  Where-Object { $_.CommandLine.Contains($ProfileDir) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

---

## 心得

### 用户的浏览器不是你的浏览器

这是我从这个项目里得到的最重要的一条。

早期我的做法是「用 Playwright 起一个新浏览器」，技术上完全正确，产品上完全错误 ——
屏幕上会弹出一个用户没要求的窗口，抢走焦点，然后开始自己乱点。用户的反应是愤怒，这是合理的。

**「技术上能开」和「应该开」是两件事。** 当用户说「浏览器已打开」时，
他要的是「在我这个浏览器里干活」，不是「再开一个」。后者的所有便利（干净的 profile、
可控的生命周期）都不足以抵消那一下打扰。

所以现在这个项目的设计原则是：**任何情况下都不创建用户可见的 UI**。
`tab.open` 用 `active: false`，启动用 `--headless=new`，
连启动脚本都准备了 `silent.vbs` 来消除那 0.2 秒的控制台闪窗。

### 空 catch 是最贵的代码

坑 2 之所以花了那么久，就是因为 `.catch(() => {})`。

写的时候想的是「轮询失败很正常，网络抖动而已，别刷屏」。
实际上它把「配置读取失败」这个致命错误也一起吞了，表现成「一切正常，就是没反应」。

现在我的规则是：**catch 里必须留痕**。哪怕只是 `stats.lastError = e.message`，
哪怕没人看，也比静默好。因为排查时你至少能问一句「最后一次错误是什么」。

### 「没有报错」比「报错」难查十倍

坑 3（`--load-extension` 被禁用）和坑 2 都是这一类：不报错、不警告、行为静默降级。

这类问题的排查方法只能是**逐层验证**：不要问「为什么不通」，
要问「哪一层先不通」。所以我在项目里留了 `selftest.ps1` ——
它把整条链路拆成 6 个可独立验证的检查点，哪一步红了就定位到哪一层。

先能观测，再谈修复。

### 尽量让「文件」替人做决定

无头启动最难的部分不是启动，是**没有人坐在那里点弹窗**。

一开始我想过用 CDP 直接写 `chrome.storage`，试了一下发现那是 LevelDB，格式随时会变。
后来意识到：扩展是 `--load-extension` 从磁盘加载的，那目录里的文件就是可写的。
于是 launcher 在启动前写一个 `config.json`，扩展启动时读它。

**能落到文件上的配置，就不要指望 UI。** 这条对任何「无人值守」的场景都成立。

### 隔离要彻底，清理也要精确

`--user-data-dir` 用独立目录，不只是为了不污染用户配置，更是为了**能精确地杀掉自己**。

如果复用用户的 profile，你的进程和用户的进程在系统看来毫无区别，
清理时就只剩「全杀」和「不杀」两个选项，前者会伤到用户。

**给每个自己创建的进程一个独一无二的身份标记**（这里是 profile 路径），
是能安全清理的前提。

### 安全边界要画在代码里，不是文档里

本地服务最大的风险是：用户随便打开一个网页，那个网页就能 `fetch('http://127.0.0.1:8800/push')`
往你浏览器里塞命令。

所以：

- 令牌是必须的，不是可选项
- 令牌走自定义 header `X-Bridge-Token`，跨域请求要过 preflight
- 默认只监听 `127.0.0.1`，不监听 `0.0.0.0`
- `--no-token` 在帮助文本里明确标注「不推荐」

文档里写「请注意安全」是没用的，默认值才是有用的。

---

## 安全说明

| 项 | 做法 |
| --- | --- |
| 监听地址 | 固定 `127.0.0.1`，外网访问不到 |
| 鉴权 | 随机令牌，存在 `server/token.txt`（已 gitignore） |
| 令牌传递 | 自定义 header，跨域需 preflight |
| 浏览器 profile | 独立目录，与你的日常 Edge 完全隔离 |
| 进程清理 | 按 `user-data-dir` 精确匹配，绝不误伤 |

**能力边界**：这个项目让 AI 拥有和「你本人坐在电脑前」同等的网页操作能力。
请只在你自己有权操作的网站上使用它。它不提供、也不应该被用来绕过验证码、
绕过访问控制或违反任何网站的服务条款。

---

## 已知限制

- **只在 Windows 上验证过**。`launcher/` 是 PowerShell；Linux/macOS 可以照 README 里的
  命令行手动拼，理论上完全一致，但我没实测。
- **需要 Edge/Chrome ≥ 137**。更老的版本没有 `--headless=new`，扩展在无头下加载不了。
  退路是用 `-NoHeadless`（窗口挪到屏幕外）。
- **截图尺寸受 `--window-size` 限制**，不是整页长截图。需要长截图得自己滚动了分段截。
- **单实例为主**。协议里有 `target` 字段支持多实例路由，但没做负载均衡和实例选择策略。
- **没有持久化**。任务队列和回执都在内存里，服务重启就没了。

---

## 目录结构

```
edge-ai-bridge/
├── extension/                  # 浏览器扩展（MV3）
│   ├── manifest.json
│   ├── background.js           # 执行器：拿着 chrome.* 权限干活
│   ├── offscreen.html/js       # 轮询器：唯一常驻的网络出口
│   ├── popup.html/js           # 设置面板：端口 / 令牌 / 心跳
│   ├── config.example.json     # launcher 会生成 config.json
│   └── icons/
├── server/
│   └── bridge.py               # 本地桥接服务，纯标准库
├── launcher/
│   ├── launch_hidden.ps1       # 主启动器：无头 + 无窗口
│   ├── launch_setup.ps1        # 一次性可见启动，用于人工确认
│   ├── selftest.ps1            # 端到端自检，6 个检查点
│   ├── silent.vbs              # 零闪窗双击启动
│   └── stop.ps1                # 精确清理
├── examples/
│   ├── client.py               # CLI + 可导入的库
│   └── demo.py                 # 完整流程演示
└── docs/
    └── PROTOCOL.md             # 通信协议
```

---

## 仓库规则

本仓库默认**私有**。公开、发布、凭据管理、提交规范的完整约定见 [RULES.md](RULES.md)。

简单说三条：

1. 「提交到 GitHub」不等于「公开」，公开必须逐次明确授权
2. 令牌、密钥、运行时配置、浏览器用户数据一律不进版本库
3. 安全靠默认值保证（仅监听 `127.0.0.1`、默认开鉴权），不靠文档提醒

---

## License

MIT
