# 通信协议

桥接服务和扩展之间只有 4 个 HTTP 接口。全部走 `127.0.0.1`，请求头带 `X-Bridge-Token`。

## 鉴权

除 `OPTIONS` 外，所有请求都要带：

```
X-Bridge-Token: <server/token.txt 里的令牌>
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

不需要令牌（便于脚本探活）。

```json
{ "ok": true, "version": "0.1.0", "active": "iXXX", "instances": ["iXXX"], "pending": 0, "done": 3 }
```

`instances` 为空 = 浏览器没起来或扩展没加载。

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
