# 通信协议

桥接服务和扩展之间只有 4 个 HTTP 接口。全部走 `127.0.0.1`，请求头带 `X-Bridge-Token`。

## 鉴权

除 `OPTIONS` 外，所有请求都要带：

```
X-Bridge-Token: <运行数据目录 token.txt 里的令牌，旧版在 server/token.txt>
```

服务端用 `--no-token` 启动时跳过校验（仅限本机调试）。

## 任务的生命周期

```
AI 侧                     桥接服务                      扩展 offscreen
  │                          │                              │
  │  POST /push              │                              │
  │─────────────────────────>│  任务入队，分配 id            │
  │<─────────────────────────│  {id: "t7"}                  │
  │                          │                              │
  │                          │<───── GET /task?iid=iXXX ─────│  每 1 秒
  │                          │───── {task: {...}} ─────────>│
  │                          │                              │  执行
  │                          │<───── POST /ack ─────────────│  {id, ok, ...}
  │                          │  队头出队，结果存入 done       │
  │  GET /done               │                              │
  │─────────────────────────>│                              │
  │<─────────────────────────│  {done: [{id: "t7", ...}]}   │
```

关键点：**任务只有 ack 回来才出队**。所以浏览器崩了、页面卡住了，任务会一直留在队头，
AI 侧等超时就知道出问题了，不会静默丢任务。

## 接口

### `GET /health`

需要令牌（和其余接口一样带 `X-Bridge-Token`）。

```json
{
  "ok": true,
  "version": "0.2.2",
  "active": "iXXX",
  "instances": ["iXXX"],
  "instances_detail": { "iXXX": { "last_seen": 1792367578.5, "browser": "edge" } },
  "browsers": ["edge"],
  "pending": 0,
  "done": 3
}
```

`instances` 为空 = 浏览器没起来或扩展没加载。

- `instances_detail` 给出每个实例（扩展的一个浏览器进程）最近一次轮询的 Unix 时间戳，
  以及它自报的浏览器类型；判定「装没装插件」看的就是这里的时间戳是否新鲜（`launcher/check_extension.ps1`
  用的是 60 秒窗口）。
- `browsers` 是去重后的浏览器类型集合，方便一次问「哪些浏览器连上了」。
- 实例 ID 由扩展生成，形如 `edge-le21fturmvhyqt5p` / `chrome-…` / `firefox-…`：前缀是浏览器类型，
  后半段随机 + 时间戳。旧版扩展只发 `i…` 前缀，服务端照收，只是 `browser` 字段会缺失。

### `GET /task?iid=<实例ID>`

扩展调用。同一时刻只有队头任务能被取走。

```json
{ "task": { "id": "t7", "action": "page.eval", "args": { "code": "document.title" }, "target": null, "created": 1792367578.5 } }
```

没有任务时返回 `{"task": null}`。

`target` 非空时只有该实例能取到任务，用于一台机器开多个浏览器实例的场景。

### `POST /push`

AI 侧调用，推一个任务。

```json
{ "action": "tab.open", "args": { "url": "https://example.com" }, "id": "自定义id", "target": null }
```

`id` 可省略，服务端自增生成。返回 `{"ok": true, "id": "t7", "pending": 1}`。

### `POST /ack`

扩展调用，回传执行结果。

```json
{ "id": "t7", "ok": true, "tabId": 123, "url": "https://example.com" }
```

`id` 与队头一致时出队。结果原样存进 `done`（最多保留 500 条）。

### `GET /done` / `GET /flush`

读全部回执 / 清空回执。

## 命令表

| action | args | 返回 |
| --- | --- | --- |
| `ping` | — | `{pong, ts}` |
| `info` | — | `{version, tabCount, lastTabId, platform, userAgent}` |
| `tabs.list` | — | `{tabs: [{tabId, windowId, active, title, url}]}` |
| `tab.open` | `{url}` | `{tabId, url}`，后台打开不抢焦点 |
| `tab.close` | `{tabId}` | `{tabId}` |
| `tab.activate` | `{tabId}` | `{}` |
| `tab.navigate` | `{url, tabId?}` | `{tabId}` |
| `tab.reload` | `{tabId?}` | `{tabId}` |
| `page.eval` | `{code, tabId?}` | `{value, url}` |
| `page.waitFor` | `{selector, timeout?, tabId?}` | `{found}` |
| `page.click` | `{selector, tabId?}` | `{clicked, found}` |
| `page.type` | `{selector, text, tabId?}` | `{}` |
| `page.text` | `{selector?, tabId?}` | `{text, found}` |
| `page.html` | `{selector?, tabId?}` | `{html, found}` |
| `page.screenshot` | `{tabId?}` | `{dataUrl}`（PNG base64） |
| `cookies.get` | `{url, name}` | `{cookie}` |
| `cookies.set` | `{url, name, value, domain?, path?, secure?, httpOnly?}` | `{cookie}` |

`tabId` 省略时作用在「上一次操作过的标签页」，其次最近一个 http(s) 页。
这个规则很重要——无头浏览器启动时前台页是 `about:blank`，而扩展没有 `about:blank` 的注入权限。

返回里 `ok` 表示命令是否执行成功，`found` 表示元素是否存在。两者是分开的：
`page.text` 找不到元素时 `ok: true, found: false, text: ""`，不当作错误。
