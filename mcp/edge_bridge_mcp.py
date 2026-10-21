#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
edge_bridge_mcp.py — Edge AI Bridge 的 MCP 服务器（stdio）

让 Codex / Claude / 任何 MCP 客户端把「已装插件的那个浏览器」当成工具来调：
复用浏览器现有登录态，后台开标签、读页面、执行 JS、截图，全程不弹窗。

零第三方依赖：MCP 的 stdio 帧就是按行分隔的 JSON-RPC，手写即可；
浏览器操作全部转发给同目录 client.py 的 Edge 类（唯一一份协议实现，
不在这儿重新发明 push/ack/done 那套）。

用法（Codex 的 config.toml）：
    [mcp_servers.edge-bridge]
    command = '<python 路径>'
    args = ['D:/_Project/edge-ai-bridge/mcp/edge_bridge_mcp.py']

环境变量（都可省）：
    BRIDGE_PORT   桥接端口，默认读 extension/config.json，再退 8800
    BRIDGE_TOKEN  令牌，默认读运行数据目录 token.txt
    BRIDGE_TIMEOUT 单条命令超时秒数，默认 30
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "examples"))

from client import Edge, BridgeError  # noqa: E402


def _default_port():
    env = os.environ.get("BRIDGE_PORT", "").strip()
    if env.isdigit():
        return int(env)
    cfg = os.path.join(ROOT, "extension", "config.json")
    try:
        # utf-8-sig：config.json 常被 PowerShell 5.1 的 Set-Content -Encoding UTF8
        # 写成带 BOM 的文件，用 utf-8 读会 JSONDecodeError，端口就会悄悄回落到 8800
        # ——表现是「桥接明明在 8801，工具却说连不上 8800」。
        with open(cfg, encoding="utf-8-sig") as f:
            return int(json.load(f).get("port") or 8800)
    except Exception:
        return 8800


try:
    _TIMEOUT = float(os.environ.get("BRIDGE_TIMEOUT", "30"))
except ValueError:
    _TIMEOUT = 30.0

EDGE = Edge(port=_default_port(), timeout=_TIMEOUT)

# 工具描述里刻意写清「浏览器和插件都得活着」，
# 不然模型会把 30 秒超时当成桥接的 bug 去瞎修。
TOOLS = [
    {
        "name": "browser_status",
        "description": "检查桥接服务和浏览器插件是否在线。做任何浏览器操作前先调它；没实例就先让用户跑 launcher\\launch_with_extension.ps1。",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "browser_tabs",
        "description": "列出浏览器所有标签页（tabId / 标题 / URL / 是否激活）。",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "browser_open",
        "description": "后台新开标签页打开 URL（不抢焦点、不弹窗），返回 tabId。",
        "inputSchema": {
            "type": "object",
            "properties": {"url": {"type": "string", "description": "http(s) 地址"}},
            "required": ["url"],
        },
    },
    {
        "name": "browser_close_tab",
        "description": "关闭指定标签页。只关自己开的页，别关用户的。",
        "inputSchema": {
            "type": "object",
            "properties": {"tab_id": {"type": "integer"}},
            "required": ["tab_id"],
        },
    },
    {
        "name": "browser_goto",
        "description": "让某个标签页跳转到新地址（省略 tab_id 用最近操作的页）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"},
                "tab_id": {"type": "integer", "description": "可省略"},
            },
            "required": ["url"],
        },
    },
    {
        "name": "browser_text",
        "description": "取页面可见文本（整页或某个选择器）。等渲染完成可先用 browser_wait。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "selector": {"type": "string", "description": "CSS 选择器，省略取整页"},
                "tab_id": {"type": "integer"},
            },
            "required": [],
        },
    },
    {
        "name": "browser_html",
        "description": "取页面 HTML（整页或某个选择器的 outerHTML）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "selector": {"type": "string"},
                "tab_id": {"type": "integer"},
            },
            "required": [],
        },
    },
    {
        "name": "browser_eval",
        "description": (
            "在页面的真实作用域（MAIN world）执行 JS 表达式，支持 await，"
            "返回值必须可 JSON 序列化。注意：受页面 CSP 限制，强 CSP 站点（GitHub/必应等）"
            "上 eval 会被拒 —— 那种页面改用 browser_text / browser_html。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "JS 表达式，最后一个表达式的值会被返回"},
                "tab_id": {"type": "integer"},
            },
            "required": ["code"],
        },
    },
    {
        "name": "browser_wait",
        "description": "等某个 CSS 选择器出现（默认 10 秒）。SPA 渲染慢时先等再读。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "selector": {"type": "string"},
                "timeout_ms": {"type": "integer", "default": 10000},
                "tab_id": {"type": "integer"},
            },
            "required": ["selector"],
        },
    },
    {
        "name": "browser_click",
        "description": "点击页面里的元素（CSS 选择器）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "selector": {"type": "string"},
                "tab_id": {"type": "integer"},
            },
            "required": ["selector"],
        },
    },
    {
        "name": "browser_type",
        "description": "往输入框写文本（兼容 React 受控组件；触发 input/change 事件）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "selector": {"type": "string"},
                "text": {"type": "string"},
                "tab_id": {"type": "integer"},
            },
            "required": ["selector", "text"],
        },
    },
    {
        "name": "browser_screenshot",
        "description": "给标签页截图存成 PNG 文件，返回路径。路径要绝对、在可写目录。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "绝对路径，如 D:\\\\shots\\\\page.png"},
                "tab_id": {"type": "integer"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "browser_cookie",
        "description": "读单个 cookie 值（需要 url + name）。只在确实需要时读，不要把值写进任何输出文件。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"},
                "name": {"type": "string"},
            },
            "required": ["url", "name"],
        },
    },
]


def _dispatch(name, args):
    """工具名 → Edge 方法。统一返回 dict，出错也返回 dict（不抛，保 stdio 不断）。"""
    if name == "browser_status":
        return {"port": EDGE.base, "health": EDGE.health(), "info": EDGE.info()}
    if name == "browser_tabs":
        return EDGE.tabs()
    if name == "browser_open":
        r = EDGE.open(args["url"])
        return {"tab_id": r.get("tabId"), "url": r.get("url")}
    if name == "browser_close_tab":
        return EDGE.close(int(args["tab_id"]))
    if name == "browser_goto":
        tab = args.get("tab_id")
        return EDGE.goto(args["url"], tab_id=int(tab) if tab else None)
    if name == "browser_text":
        tab = args.get("tab_id")
        return EDGE.text(args.get("selector"), tab_id=int(tab) if tab else None)
    if name == "browser_html":
        tab = args.get("tab_id")
        return EDGE.html(args.get("selector"), tab_id=int(tab) if tab else None)
    if name == "browser_eval":
        tab = args.get("tab_id")
        return EDGE.eval(args["code"], tab_id=int(tab) if tab else None)
    if name == "browser_wait":
        tab = args.get("tab_id")
        return EDGE.wait(args["selector"], int(args.get("timeout_ms") or 10000),
                         tab_id=int(tab) if tab else None)
    if name == "browser_click":
        tab = args.get("tab_id")
        return EDGE.click(args["selector"], tab_id=int(tab) if tab else None)
    if name == "browser_type":
        tab = args.get("tab_id")
        return EDGE.type(args["selector"], args.get("text", ""), tab_id=int(tab) if tab else None)
    if name == "browser_screenshot":
        tab = args.get("tab_id")
        r = EDGE.screenshot(args["path"], tab_id=int(tab) if tab else None)
        return {"saved": r.get("saved"), "path": r.get("path")}
    if name == "browser_cookie":
        return EDGE.cookie(args["url"], args["name"])
    return {"ok": False, "error": "未知工具 " + name}


def _result(request_id, payload):
    msg = {"jsonrpc": "2.0", "id": request_id, "result": payload}
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _error(request_id, code, message):
    msg = {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue

        method = req.get("method")
        rid = req.get("id")

        if method == "initialize":
            _result(rid, {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "edge-ai-bridge", "version": "0.2.2"},
            })
        elif method == "notifications/initialized":
            pass  # 通知没有 id，不回
        elif method == "ping":
            _result(rid, {})
        elif method == "tools/list":
            _result(rid, {"tools": TOOLS})
        elif method == "tools/call":
            params = req.get("params") or {}
            name = params.get("name", "")
            args = params.get("arguments") or {}
            try:
                out = _dispatch(name, args)
                _result(rid, {
                    "content": [{"type": "text",
                                 "text": json.dumps(out, ensure_ascii=False, indent=1)}],
                    "isError": not (out.get("ok", True) if isinstance(out, dict) else True),
                })
            except BridgeError as e:
                # 把「为什么连不上/超时」原样给模型，这些文案自带排查步骤
                _result(rid, {"content": [{"type": "text", "text": str(e)}], "isError": True})
            except Exception as e:  # noqa: BLE001
                _result(rid, {"content": [{"type": "text",
                                           "text": "%s: %s" % (type(e).__name__, e)}],
                              "isError": True})
        elif rid is not None:
            _error(rid, -32601, "不支持的方法 " + str(method))


if __name__ == "__main__":
    sys.exit(main())
