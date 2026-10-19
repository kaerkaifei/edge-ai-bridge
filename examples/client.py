#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Edge AI Bridge — 客户端（命令行 + 可导入的库）

用法示例：
    python examples/client.py ping
    python examples/client.py open https://example.com
    python examples/client.py tabs
    python examples/client.py text
    python examples/client.py eval "document.title"
    python examples/client.py eval @script.js
    python examples/client.py click "#submit"
    python examples/client.py type "#q" "hello"
    python examples/client.py wait ".result"
    python examples/client.py shot out.png
    python examples/client.py close 12

作为库用：

    from client import Edge
    e = Edge()
    tab = e.open("https://example.com")
    print(e.text(tab["tabId"]))
    e.close(tab["tabId"])

设计要点：
  · 每个命令都会先 /push 再轮询 /done，所以是同步阻塞的，调用方不用管异步
  · 用 ProxyHandler({}) 显式绕过系统代理 —— 本机回环地址走代理会 10053 报错
  · 令牌从 server/token.txt 自动读，也可用 --token / BRIDGE_TOKEN 覆盖
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOKEN_FILE = os.path.join(ROOT, "server", "token.txt")
CONFIG_FILE = os.path.join(ROOT, "extension", "config.json")

DEFAULT_PORT = 8800

# 关键：显式禁用代理。系统里一旦设了 HTTP_PROXY，
# urllib 会把 127.0.0.1 的请求也丢给代理，直接 WinError 10053。
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class BridgeError(RuntimeError):
    pass


def _read_token():
    t = os.environ.get("BRIDGE_TOKEN", "").strip()
    if t:
        return t
    if os.path.exists(TOKEN_FILE):
        try:
            with open(TOKEN_FILE, encoding="utf-8") as f:
                t = f.read().strip()
            if t:
                return t
        except OSError:
            pass
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, encoding="utf-8") as f:
                return str(json.load(f).get("token") or "").strip()
        except (OSError, ValueError):
            pass
    return ""


class Edge:
    """一个桥接服务的最小客户端。"""

    def __init__(self, host="127.0.0.1", port=DEFAULT_PORT, token=None, timeout=30.0):
        self.base = "http://%s:%d" % (host, port)
        self.token = _read_token() if token is None else token
        self.timeout = timeout

    # ---------- HTTP 底层 ----------

    def _req(self, path, method="GET", body=None):
        url = self.base + path
        data = None
        headers = {"Accept": "application/json"}
        if self.token:
            headers["X-Bridge-Token"] = self.token
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with _OPENER.open(req, timeout=self.timeout) as r:
                raw = r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise BridgeError(
                    "鉴权失败（401）。检查 server/token.txt 和扩展弹窗里的令牌是否一致。"
                )
            raise BridgeError("HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")))
        except urllib.error.URLError as e:
            raise BridgeError(
                "连不上桥接服务 %s —— 是不是没启动？跑 launcher\\launch_hidden.ps1。\n  原始错误：%s"
                % (self.base, e.reason)
            )
        try:
            return json.loads(raw)
        except ValueError:
            raise BridgeError("返回的不是 JSON：%r" % raw[:200])

    # ---------- 核心：推任务 + 等结果 ----------

    def call(self, action, args=None, timeout=None, target=None):
        """
        发一条命令并等它执行完，返回结果 dict。

        action: 命令名，见 README 的协议表
        args:   参数字典
        timeout: 等待秒数，默认用实例的 timeout
        target: 指定实例 id（多浏览器时用），一般不用
        """
        timeout = self.timeout if timeout is None else timeout

        payload = {"action": action, "args": args or {}}
        if target:
            payload["target"] = target

        r = self._req("/push", method="POST", body=payload)
        tid = r.get("id")
        if not tid:
            raise BridgeError("服务没有返回任务 id：%r" % r)

        deadline = time.time() + timeout
        while time.time() < deadline:
            done = self._req("/done").get("done") or []
            for rec in reversed(done):
                if str(rec.get("id")) == str(tid):
                    rec.pop("popped", None)
                    rec.pop("at", None)
                    return rec
            time.sleep(0.15)

        raise BridgeError(
            "等 %s 秒超时：任务 %s (%s) 没有回执。\n"
            "  常见原因：浏览器没启动 / 扩展没连上 / 页面里那句 JS 卡住了。\n"
            "  用 python examples/client.py health 看看有没有实例在线。"
            % (timeout, tid, action)
        )

    # ---------- 便捷封装 ----------

    def health(self):
        return self._req("/health")

    def flush(self):
        return self._req("/flush")

    def ping(self, **kw):
        return self.call("ping", {}, **kw)

    def info(self, **kw):
        return self.call("info", {}, **kw)

    def tabs(self, **kw):
        return self.call("tabs.list", {}, **kw)

    def open(self, url, **kw):
        return self.call("tab.open", {"url": url}, **kw)

    def close(self, tab_id, **kw):
        return self.call("tab.close", {"tabId": tab_id}, **kw)

    def activate(self, tab_id, **kw):
        return self.call("tab.activate", {"tabId": tab_id}, **kw)

    def goto(self, url, tab_id=None, **kw):
        a = {"url": url}
        if tab_id:
            a["tabId"] = tab_id
        return self.call("tab.navigate", a, **kw)

    def reload(self, tab_id=None, **kw):
        a = {}
        if tab_id:
            a["tabId"] = tab_id
        return self.call("tab.reload", a, **kw)

    def eval(self, code, tab_id=None, **kw):
        a = {"code": code}
        if tab_id:
            a["tabId"] = tab_id
        return self.call("page.eval", a, **kw)

    def wait(self, selector, timeout_ms=10000, tab_id=None, **kw):
        a = {"selector": selector, "timeout": timeout_ms}
        if tab_id:
            a["tabId"] = tab_id
        return self.call("page.waitFor", a, **kw)

    def click(self, selector, tab_id=None, **kw):
        a = {"selector": selector}
        if tab_id:
            a["tabId"] = tab_id
        return self.call("page.click", a, **kw)

    def type(self, selector, text, tab_id=None, **kw):
        a = {"selector": selector, "text": text}
        if tab_id:
            a["tabId"] = tab_id
        return self.call("page.type", a, **kw)

    def text(self, selector=None, tab_id=None, **kw):
        a = {}
        if selector:
            a["selector"] = selector
        if tab_id:
            a["tabId"] = tab_id
        return self.call("page.text", a, **kw)

    def html(self, selector=None, tab_id=None, **kw):
        a = {}
        if selector:
            a["selector"] = selector
        if tab_id:
            a["tabId"] = tab_id
        return self.call("page.html", a, **kw)

    def screenshot(self, path=None, tab_id=None, **kw):
        a = {}
        if tab_id:
            a["tabId"] = tab_id
        r = self.call("page.screenshot", a, **kw)
        if path and r.get("dataUrl"):
            import base64

            b64 = r["dataUrl"].split(",", 1)[-1]
            with open(path, "wb") as f:
                f.write(base64.b64decode(b64))
            r["saved"] = os.path.abspath(path)
            r.pop("dataUrl", None)
        return r

    def cookie(self, url, name, **kw):
        return self.call("cookies.get", {"url": url, "name": name}, **kw)


# ------------------------------------------------------------------ #
# CLI                                                                 #
# ------------------------------------------------------------------ #


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Edge AI Bridge 命令行客户端",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--token", default=None)
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--json", action="store_true", help="原样打印 JSON")

    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health", help="看桥接服务和实例状态")
    sub.add_parser("ping", help="问浏览器在不在")
    sub.add_parser("info", help="浏览器基本信息")
    sub.add_parser("tabs", help="列出所有标签页")
    sub.add_parser("text", help="取页面文本").add_argument("selector", nargs="?")
    sub.add_parser("html", help="取页面 HTML").add_argument("selector", nargs="?")

    p = sub.add_parser("open", help="新开一个标签页（后台，不抢焦点）")
    p.add_argument("url")

    p = sub.add_parser("close", help="关闭标签页")
    p.add_argument("tabId", type=int)

    p = sub.add_parser("goto", help="当前页跳转")
    p.add_argument("url")
    p.add_argument("--tab", type=int, default=None)

    p = sub.add_parser("reload", help="刷新")
    p.add_argument("--tab", type=int, default=None)

    p = sub.add_parser("eval", help="在页面里执行 JS；用 @文件名 从文件读")
    p.add_argument("code")
    p.add_argument("--tab", type=int, default=None)

    p = sub.add_parser("wait", help="等元素出现")
    p.add_argument("selector")
    p.add_argument("--ms", type=int, default=10000)
    p.add_argument("--tab", type=int, default=None)

    p = sub.add_parser("click", help="点击元素")
    p.add_argument("selector")
    p.add_argument("--tab", type=int, default=None)

    p = sub.add_parser("type", help="往输入框写内容")
    p.add_argument("selector")
    p.add_argument("text")
    p.add_argument("--tab", type=int, default=None)

    p = sub.add_parser("shot", help="截图存成 png")
    p.add_argument("path")
    p.add_argument("--tab", type=int, default=None)

    p = sub.add_parser("cookie", help="读 cookie")
    p.add_argument("url")
    p.add_argument("name")

    a = ap.parse_args(argv)

    e = Edge(host=a.host, port=a.port, token=a.token, timeout=a.timeout)

    try:
        if a.cmd == "health":
            r = e.health()
        elif a.cmd == "ping":
            r = e.ping()
        elif a.cmd == "info":
            r = e.info()
        elif a.cmd == "tabs":
            r = e.tabs()
        elif a.cmd == "text":
            r = e.text(a.selector)
        elif a.cmd == "html":
            r = e.html(a.selector)
        elif a.cmd == "open":
            r = e.open(a.url)
        elif a.cmd == "close":
            r = e.close(a.tabId)
        elif a.cmd == "goto":
            r = e.goto(a.url, a.tab)
        elif a.cmd == "reload":
            r = e.reload(a.tab)
        elif a.cmd == "eval":
            code = a.code
            if code.startswith("@"):
                with open(code[1:], encoding="utf-8") as f:
                    code = f.read()
            r = e.eval(code, a.tab)
        elif a.cmd == "wait":
            r = e.wait(a.selector, a.ms, a.tab)
        elif a.cmd == "click":
            r = e.click(a.selector, a.tab)
        elif a.cmd == "type":
            r = e.type(a.selector, a.text, a.tab)
        elif a.cmd == "shot":
            r = e.screenshot(a.path, a.tab)
        elif a.cmd == "cookie":
            r = e.cookie(a.url, a.name)
        else:
            ap.error("未知命令 " + a.cmd)
            return 2
    except BridgeError as ex:
        print("错误：" + str(ex), file=sys.stderr)
        return 1

    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    else:
        # 人看的输出：成功就只打印关键内容，别刷一屏 JSON
        if not r.get("ok", True):
            err = r.get("error")
            print("失败：" + (str(err) if err else "命令执行失败（无错误详情）"), file=sys.stderr)
            return 1

        if "value" in r:
            v = r["value"]
            print(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False, indent=2))
        elif "text" in r:
            if r.get("found") is False:
                print("（选择器没有匹配到元素）", file=sys.stderr)
            print(r["text"])
        elif "html" in r:
            if r.get("found") is False:
                print("（选择器没有匹配到元素）", file=sys.stderr)
            print(r["html"])
        elif "tabs" in r:
            for t in r["tabs"]:
                print("%6s  %s  %s" % (t["tabId"], ("*" if t.get("active") else " "), t.get("url", "")))
        elif "saved" in r:
            print("已保存：" + r["saved"])
        elif "found" in r:
            print("找到了" if r["found"] else "没找到")
        else:
            print(json.dumps(r, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
