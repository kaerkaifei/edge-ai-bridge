#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
演示：让 AI 完整跑一遍「打开 → 等 → 读 → 点 → 截图」的流程。

这个脚本本身就是一篇用法说明。跑之前先：
    1. powershell -ExecutionPolicy Bypass -File launcher\\launch_hidden.ps1
    2. python examples\\demo.py

你会看到所有动作都在一个你看不见的浏览器里完成，
屏幕上不会有任何窗口跳出来。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from client import BridgeError, Edge  # noqa: E402


def main():
    e = Edge()

    # ---- 0. 先确认通道通 ----
    h = e.health()
    if not h.get("instances"):
        print("没有实例在线。先启动：launcher\\launch_hidden.ps1")
        return 1
    print("实例在线：%s" % ", ".join(h["instances"]))

    p = e.ping()
    print("ping -> %s" % ("ok" if p.get("pong") else p))

    # ---- 1. 后台开一个标签页 ----
    # 注意 active=False：不会把你正在看的页面顶掉
    tab = e.open("https://example.com")
    tab_id = tab["tabId"]
    print("新标签页 tabId=%s" % tab_id)

    try:
        # ---- 2. 等页面加载完 ----
        # 别用 sleep 猜时间，直接等元素出现。
        # 注意：example.com 改版后已经没有 <h1> 了，这里等 body 更稳。
        r = e.wait("body", timeout_ms=15000, tab_id=tab_id)
        if not r.get("found"):
            print("页面没加载出来")
            return 1

        # ---- 3. 读内容 ----
        print("标题：%s" % e.eval("document.title", tab_id=tab_id)["value"])
        body = e.text(tab_id=tab_id)["text"]
        print("正文前 80 字：%s" % body[:80].replace("\n", " "))

        # ---- 4. 在页面里执行一段复杂点的 JS ----
        # page.eval 用间接 eval 在 MAIN world 跑，页面的框架和全局变量都摸得到
        stats = e.eval(
            """
            (() => {
              const links = [...document.querySelectorAll('a')];
              return {
                links: links.length,
                hrefs: links.slice(0, 5).map(a => a.href),
                bodyLen: document.body.innerText.length,
              };
            })()
            """,
            tab_id=tab_id,
        )["value"]
        print("链接数：%s" % stats["links"])
        for u in stats["hrefs"]:
            print("   " + u)

        # ---- 5. 截图 ----
        # 无头模式下截图仍然可用，尺寸由 --window-size 决定
        out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo.png")
        e.screenshot(out, tab_id=tab_id)
        print("截图：%s" % out)

        # ---- 6. 演示异步等待 ----
        # 页面里返回 Promise 也能被正确 await
        r = e.eval(
            "new Promise(res => setTimeout(() => res('等到了'), 300))",
            tab_id=tab_id,
        )
        print("Promise 返回：%s" % r["value"])

    finally:
        # ---- 7. 收尾：关掉自己开的标签页，不留垃圾 ----
        e.close(tab_id)
        print("已关闭 tabId=%s" % tab_id)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BridgeError as ex:
        print("错误：" + str(ex), file=sys.stderr)
        sys.exit(1)
