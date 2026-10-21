#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Edge AI Bridge — 本地桥接服务

浏览器扩展（offscreen 文档）每秒向本服务拉取一次任务，执行完把结果 POST 回来。
AI 侧只需要往 /push 里丢任务，然后读 /done 拿结果。

只依赖 Python 标准库，零安装。

用法：
    python bridge.py                    # 默认 127.0.0.1:8800，自动生成令牌
    python bridge.py --port 8800 --token mytoken
    python bridge.py --no-token         # 仅本机调试时可关闭鉴权
"""

import argparse
import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "0.2.2"
HERE = os.path.dirname(os.path.abspath(__file__))

# 运行数据（令牌、日志、浏览器 profile）放在用户级目录，不跟代码走。
# 为什么：代码目录会被移动、重新 clone、被备份或清理牵连；令牌和 profile
# 是「这台机器上的状态」，应当稳定，且不该出现在 git status 里。
# 可用环境变量 BRIDGE_RUNTIME_DIR 覆盖（便携化 / 换盘时用）。
RUNTIME_DIR = os.environ.get("BRIDGE_RUNTIME_DIR") or os.path.join(
    os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "EdgeAiBridge"
)
TOKEN_FILE = os.path.join(RUNTIME_DIR, "token.txt")
# 0.2.0 及更早版本把令牌写在 server/ 里，旧目录还在时继续读，平滑升级
LEGACY_TOKEN_FILE = os.path.join(HERE, "token.txt")

# 扩展连上来时会带一个实例 id（iid）。新版 offscreen 把浏览器名写成前缀，
# 例如 edge-ab12cd34xyz / chrome-98fe76dc。
# 为什么要认这个前缀：安装脚本要回答「即将同步的浏览器到底装没装插件」，
# 只看「有没有实例在线」是不够的——可能是 Chrome 在线、而你要同步的是 Edge。
BROWSER_PREFIXES = ("edge", "chrome", "chromium", "brave", "vivaldi", "opera")

# 扩展每 1 秒拉一次任务，这就是它的「心跳」。超过这么久没动静就当作掉线：
# /health 不再把它算成在线实例（否则安装脚本会被几分钟前的残影骗到）。
INSTANCE_STALE_SEC = 60


def instance_browser(iid: str) -> str:
    """从 iid 前缀推断浏览器；旧版扩展只发随机 id，返回 unknown（保持兼容）。"""
    for name in BROWSER_PREFIXES:
        if iid.startswith(name + "-"):
            return name
    return "unknown"


class State:
    """进程内共享状态：任务队列、回传结果、在线实例。"""

    def __init__(self, token: str, verbose: bool = False):
        self.token = token
        self.verbose = verbose
        self.lock = threading.Lock()
        self.tasks = []        # 待执行任务，[0] 为队头
        self.done = []         # 已完成结果（最多保留 500 条）
        self.instances = {}    # iid -> 最近心跳时间
        self.active = None     # 最近轮询的实例
        self.seq = 0

    def next_id(self) -> str:
        self.seq += 1
        return "t%d" % self.seq


def load_or_create_token(disable: bool) -> str:
    if disable:
        return ""
    env = os.environ.get("BRIDGE_TOKEN", "").strip()
    if env:
        return env
    for path in (TOKEN_FILE, LEGACY_TOKEN_FILE):
        if os.path.exists(path):
            t = open(path, encoding="utf-8").read().strip()
            if t:
                return t
    t = secrets.token_urlsafe(18)
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        f.write(t)
    return t


class Tee:
    """同时写 stdout 和日志文件。

    为什么不交给 PowerShell 的 -RedirectStandardOutput：
    在同时存在 http_proxy / HTTP_PROXY 这类大小写重复的环境变量时，
    Start-Process 的重定向会直接抛 ArgumentException（字典键重复）。
    让进程自己写日志，最省事也最稳。

    坑：pythonw.exe 下 sys.stdout 是 None，而且一旦把 Tee 赋给 sys.stdout，
    write() 里的 sys.stdout.write 就会调回自己 → 无限递归。
    所以必须在赋值前把原始流存下来。
    """

    def __init__(self, path: str):
        self.out = sys.stdout
        self.err = sys.stderr
        self.f = open(path, "a", encoding="utf-8", buffering=1)

    def _raw(self, s, fallback):
        if fallback is not None:
            try:
                fallback.write(s)
            except Exception:
                pass
        try:
            self.f.write(s)
            self.f.flush()
        except Exception:
            pass

    def write(self, s):
        self._raw(s, self.out)

    def flush(self):
        try:
            if self.out is not None:
                self.out.flush()
            self.f.flush()
        except Exception:
            pass


class TeeErr(Tee):
    def write(self, s):
        self._raw(s, self.err)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "EdgeAIBridge/" + VERSION

    # ---------------- 基础工具 ----------------

    def log_message(self, fmt, *args):
        if STATE.verbose:
            sys.stderr.write("[bridge] %s\n" % (fmt % args))

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Bridge-Token")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        if not STATE.token:
            return True
        return self.headers.get("X-Bridge-Token") == STATE.token

    def _read_json(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    # ---------------- 路由 ----------------

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self._authorized():
            return self._json({"err": "unauthorized"}, 401)

        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path == "/":
            return self._json({
                "service": "edge-ai-bridge",
                "version": VERSION,
                "endpoints": ["/health", "/task?iid=", "/push", "/ack", "/done", "/flush"],
            })

        if u.path == "/health":
            with STATE.lock:
                now = time.time()
                # 只报「还活着」的实例：扩展每 1 秒心跳一次，超过 INSTANCE_STALE_SEC
                # 没声音就是掉线了。以前把死实例继续当在线，导致安装脚本看见一个
                # 几分钟前的残影就宣布「插件已连上」，然后 client 等回执等到超时。
                fresh = []
                stale = 0
                for iid, ts in STATE.instances.items():
                    age = now - ts
                    if age > INSTANCE_STALE_SEC:
                        stale += 1
                        continue
                    fresh.append({
                        "iid": iid,
                        "browser": instance_browser(iid),
                        "age_ms": int(max(0.0, age) * 1000),
                    })
                return self._json({
                    "ok": True,
                    "version": VERSION,
                    "active": STATE.active,
                    "instances": [d["iid"] for d in fresh],
                    # 给安装脚本用：谁在线、是哪个浏览器、最后一次心跳多久前
                    "instances_detail": fresh,
                    "instances_stale": stale,
                    "browsers": sorted({d["browser"] for d in fresh}),
                    "pending": len(STATE.tasks),
                    "done": len(STATE.done),
                })

        if u.path == "/task":
            iid = (q.get("iid") or [""])[0]
            with STATE.lock:
                if iid:
                    STATE.instances[iid] = time.time()
                    STATE.active = iid  # 最近轮询者获得任务
                if STATE.tasks:
                    task = dict(STATE.tasks[0])
                    # target 为空表示广播给当前活跃实例
                    if task.get("target") in (None, "", STATE.active):
                        return self._json({"task": task})
                return self._json({"task": None})

        if u.path == "/done":
            with STATE.lock:
                return self._json({"done": list(STATE.done)})

        if u.path == "/flush":
            with STATE.lock:
                STATE.done.clear()
            return self._json({"ok": True})

        return self._json({"err": "unknown path " + u.path}, 404)

    def do_POST(self):
        if not self._authorized():
            return self._json({"err": "unauthorized"}, 401)

        u = urlparse(self.path)
        data = self._read_json()

        if u.path == "/push":
            action = data.get("action")
            if not action:
                return self._json({"err": "missing action"}, 400)
            with STATE.lock:
                task = {
                    "id": str(data.get("id") or STATE.next_id()),
                    "action": action,
                    "args": data.get("args") or {},
                    "target": data.get("target"),
                    "created": time.time(),
                }
                STATE.tasks.append(task)
            return self._json({"ok": True, "id": task["id"], "pending": len(STATE.tasks)})

        if u.path == "/ack":
            tid = str(data.get("id") or "")
            with STATE.lock:
                popped = False
                if STATE.tasks and str(STATE.tasks[0].get("id")) == tid:
                    STATE.tasks.pop(0)
                    popped = True
                record = dict(data)
                record["popped"] = popped
                record["at"] = time.time()
                STATE.done.append(record)
                if len(STATE.done) > 500:
                    del STATE.done[: len(STATE.done) - 500]
            return self._json({"ok": True})

        return self._json({"err": "unknown path " + u.path}, 404)


STATE: State = None  # type: ignore


def main():
    global STATE

    ap = argparse.ArgumentParser(description="Edge AI Bridge 本地桥接服务")
    ap.add_argument("--host", default="127.0.0.1", help="监听地址（默认仅本机）")
    ap.add_argument("--port", type=int, default=8800, help="端口，默认 8800")
    ap.add_argument("--token", default=None, help="访问令牌；不传则自动生成并保存到 token.txt")
    ap.add_argument("--no-token", action="store_true", help="关闭鉴权（不推荐）")
    ap.add_argument("--verbose", action="store_true", help="打印每条请求日志")
    ap.add_argument("--log", default="", help="把输出同时写进这个文件（后台启动时用）")
    args = ap.parse_args()

    if args.log:
        sys.stdout = Tee(args.log)
        sys.stderr = TeeErr(args.log)

    token = args.token if args.token is not None else load_or_create_token(args.no_token)
    STATE = State(token=token, verbose=args.verbose)

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True

    print("=" * 58)
    print(" Edge AI Bridge 服务已启动")
    print("   地址：http://%s:%d" % (args.host, args.port))
    print("   令牌：%s" % (token or "（未启用鉴权）"))
    print("   令牌已写入：%s" % TOKEN_FILE if token else "")
    print("   把「地址端口 + 令牌」填进扩展弹窗即可。")
    print("=" * 58)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")


if __name__ == "__main__":
    main()
