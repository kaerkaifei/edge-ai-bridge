/**
 * Edge AI Bridge — background service worker
 *
 * 职责：
 *   1. 保证 offscreen 文档存在（由它负责和本地桥接服务保持连接）
 *   2. 接收 offscreen 转发来的命令，用 chrome.* API 在浏览器里执行
 *   3. 把执行结果回传给 offscreen，由它 ACK 给桥接服务
 *
 * 设计要点：
 *   - MV3 的 service worker 会被浏览器随时休眠，所以轮询不放在这里，放在 offscreen 文档里
 *   - 所有脚本注入都走 chrome.scripting.executeScript，world: "MAIN"，
 *     这样能拿到页面真实的 window（框架、全局变量都可见）
 */

const DEFAULT_PORT = 8800;

let creatingOffscreen = null;

async function getConfig() {
  const c = await chrome.storage.local.get(["port", "token"]);
  return {
    port: Number(c.port) || DEFAULT_PORT,
    token: String(c.token || ""),
  };
}

/**
 * 从扩展目录里的 config.json 读取启动配置。
 *
 * 为什么要有这一步：无头启动时没有人去点弹窗填端口和令牌，必须让"文件"替人做这件事。
 * 扩展是 --load-extension 从磁盘加载的，launcher 只要在启动浏览器前把 config.json 写好，
 * 扩展一启动就能自己读到。比去改 Chrome 的 LevelDB 存储靠谱得多。
 */
async function applyBundledConfig() {
  try {
    const res = await fetch(chrome.runtime.getURL("config.json"), { cache: "no-store" });
    if (!res.ok) return;
    const cfg = await res.json();
    const patch = {};
    if (cfg.port !== undefined && cfg.port !== null && cfg.port !== "") {
      patch.port = Number(cfg.port);
    }
    if (cfg.token !== undefined && cfg.token !== null) {
      patch.token = String(cfg.token);
    }
    if (Object.keys(patch).length) {
      await chrome.storage.local.set(patch);
    }
  } catch (e) {
    // config.json 不存在或格式不对：静默跳过，用弹窗里的旧配置
  }
}

/** 确保 offscreen 文档存在（重复调用安全） */
async function ensureOffscreen() {
  try {
    if (chrome.runtime.getContexts) {
      const ctx = await chrome.runtime.getContexts({
        contextTypes: ["OFFSCREEN_DOCUMENT"],
      });
      if (ctx && ctx.length) return;
    }
    if (creatingOffscreen) return creatingOffscreen;
    creatingOffscreen = chrome.offscreen
      .createDocument({
        url: "offscreen.html",
        reasons: ["WORKERS"],
        justification: "与本地 AI 桥接服务保持长连接并轮询任务",
      })
      .catch(() => {})
      .finally(() => {
        creatingOffscreen = null;
      });
    return creatingOffscreen;
  } catch (e) {
    // 已经存在时会抛错，忽略即可
    return null;
  }
}

async function boot() {
  await applyBundledConfig();
  await ensureOffscreen();
}

chrome.runtime.onInstalled.addListener(() => boot());
chrome.runtime.onStartup.addListener(() => boot());
boot();

/* ------------------------------------------------------------------ */
/* 工具函数                                                             */
/* ------------------------------------------------------------------ */

/**
 * 记住"当前标签页"。
 *
 * 为什么不能只靠 active tab：无头启动时前台页是 about:blank，
 * 而扩展没有 about:blank 的注入权限，会报
 *   Cannot access contents of url "about:blank"
 * 所以自己记一个 lastTabId：tab.open / tab.navigate 时更新，
 * 后续不带 tabId 的命令默认作用在它身上。这符合"我刚开的那页就是我在操作的那页"的直觉。
 */
let lastTabId = null;

async function tabUrl(tabId) {
  try {
    const t = await chrome.tabs.get(tabId);
    return t.url || "";
  } catch (e) {
    return "";
  }
}

/** 没传 tabId 时：上次操作过的页 → 任一 http(s) 页 → active 页 */
async function resolveTab(tabId) {
  if (tabId) {
    lastTabId = tabId;
    return tabId;
  }

  if (lastTabId !== null) {
    try {
      const t = await chrome.tabs.get(lastTabId);
      if (t && t.id) return t.id;
    } catch (e) {
      lastTabId = null; // 已经被关掉了
    }
  }

  const all = await chrome.tabs.query({});
  const usable = all.filter(
    (t) => t.id && t.url && /^(https?|file|ftp):/i.test(t.url)
  );
  if (usable.length) {
    lastTabId = usable[usable.length - 1].id;
    return lastTabId;
  }

  const active = all.find((t) => t.active && t.id);
  if (active) return active.id;
  if (all.length && all[0].id) return all[0].id;
  throw new Error("没有可用标签页，请先 tab.open 打开一个页面");
}

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabId === lastTabId) lastTabId = null;
});

/** 在页面 MAIN world 执行一个函数，参数走序列化传递 */
async function runInTab(tabId, func, args) {
  const results = await chrome.scripting.executeScript({
    target: { tabId },
    world: "MAIN",
    func,
    args: args || [],
  });
  return results && results[0] ? results[0].result : null;
}

function safeJson(v) {
  try {
    return JSON.parse(JSON.stringify(v === undefined ? null : v));
  } catch (e) {
    return String(v);
  }
}

/* ------------------------------------------------------------------ */
/* 命令实现                                                             */
/* ------------------------------------------------------------------ */

const handlers = {
  async ping() {
    return { ok: true, pong: true, ts: Date.now() };
  },

  async info() {
    const tabs = await chrome.tabs.query({});
    return {
      ok: true,
      version: chrome.runtime.getManifest().version,
      tabCount: tabs.length,
      lastTabId,
      platform: navigator.platform,
      userAgent: navigator.userAgent,
    };
  },

  async "tabs.list"() {
    const tabs = await chrome.tabs.query({});
    return {
      ok: true,
      tabs: tabs.map((t) => ({
        tabId: t.id,
        windowId: t.windowId,
        active: t.active,
        title: t.title || "",
        url: t.url || "",
      })),
    };
  },

  async "tab.open"(args) {
    const tab = await chrome.tabs.create({
      url: args.url || "about:blank",
      active: false, // 默认后台打开，不抢焦点
    });
    lastTabId = tab.id;
    return { ok: true, tabId: tab.id, url: tab.url || args.url };
  },

  async "tab.close"(args) {
    await chrome.tabs.remove(args.tabId);
    return { ok: true, tabId: args.tabId };
  },

  async "tab.activate"(args) {
    await chrome.tabs.update(args.tabId, { active: true });
    return { ok: true };
  },

  async "tab.navigate"(args) {
    const tabId = await resolveTab(args.tabId);
    await chrome.tabs.update(tabId, { url: args.url });
    lastTabId = tabId;
    return { ok: true, tabId };
  },

  async "tab.reload"(args) {
    const tabId = await resolveTab(args.tabId);
    await chrome.tabs.reload(tabId);
    return { ok: true, tabId };
  },

  /** 在页面里执行任意 JS（字符串），返回可 JSON 序列化的结果 */
  async "page.eval"(args) {
    const tabId = await resolveTab(args.tabId);
    const code = String(args.code || "");
    const value = await runInTab(
      tabId,
      (src) => {
        try {
          // 用间接 eval，在页面真实作用域里执行
          const v = (0, eval)(src);
          if (v && typeof v.then === "function") {
            return v.then(
              (r) => ({ __ok: true, value: JSON.parse(JSON.stringify(r === undefined ? null : r)) }),
              (e) => ({ __ok: false, error: String((e && e.message) || e) })
            );
          }
          return { __ok: true, value: JSON.parse(JSON.stringify(v === undefined ? null : v)) };
        } catch (e) {
          return { __ok: false, error: String((e && e.message) || e) };
        }
      },
      [code]
    );
    if (!value) return { ok: false, error: "页面没有返回结果" };
    if (!value.__ok) return { ok: false, error: value.error };
    return { ok: true, value: value.value, url: await tabUrl(tabId) };
  },

  /** 等待元素出现 */
  async "page.waitFor"(args) {
    const tabId = await resolveTab(args.tabId);
    const found = await runInTab(
      tabId,
      async (selector, timeout) => {
        const deadline = Date.now() + (timeout || 10000);
        while (Date.now() < deadline) {
          if (document.querySelector(selector)) return true;
          await new Promise((r) => setTimeout(r, 200));
        }
        return false;
      },
      [String(args.selector), Number(args.timeout) || 10000]
    );
    // ok 表示"命令执行成功"，found 表示"元素在不在"，两者别混
    return { ok: true, found: !!found };
  },

  async "page.click"(args) {
    const tabId = await resolveTab(args.tabId);
    const clicked = await runInTab(
      tabId,
      (selector) => {
        const el = document.querySelector(selector);
        if (!el) return false;
        el.click();
        return true;
      },
      [String(args.selector)]
    );
    return { ok: true, clicked: !!clicked, found: !!clicked };
  },

  /** 写输入框：同时触发 input/change，兼容 React 受控组件 */
  async "page.type"(args) {
    const tabId = await resolveTab(args.tabId);
    const done = await runInTab(
      tabId,
      (selector, text) => {
        const el = document.querySelector(selector);
        if (!el) return false;
        el.focus();
        const proto =
          el instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
        setter.call(el, text);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      },
      [String(args.selector), String(args.text == null ? "" : args.text)]
    );
    return { ok: !!done };
  },

  /** 取文本（不传 selector 则取 body） */
  async "page.text"(args) {
    const tabId = await resolveTab(args.tabId);
    const text = await runInTab(
      tabId,
      (selector) => {
        const el = selector ? document.querySelector(selector) : document.body;
        return el ? el.innerText || "" : null;
      },
      [args.selector ? String(args.selector) : ""]
    );
    return { ok: true, found: text !== null, text: text === null ? "" : text };
  },

  async "page.html"(args) {
    const tabId = await resolveTab(args.tabId);
    const html = await runInTab(
      tabId,
      (selector) => {
        const el = selector ? document.querySelector(selector) : document.documentElement;
        return el ? el.outerHTML : null;
      },
      [args.selector ? String(args.selector) : ""]
    );
    return { ok: true, found: html !== null, html: html === null ? "" : html };
  },

  /**
   * 截图：只能截「当前窗口的可见标签页」。
   * 无头模式下通常仍可用，但若标签页不在前台会失败，需先 tab.activate。
   */
  async "page.screenshot"(args) {
    const tabId = await resolveTab(args.tabId);
    const tab = await chrome.tabs.get(tabId);
    await chrome.tabs.update(tabId, { active: true });
    await new Promise((r) => setTimeout(r, 300));
    const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, {
      format: "png",
    });
    return { ok: true, dataUrl };
  },

  async "cookies.get"(args) {
    const cookie = await chrome.cookies.get({
      url: String(args.url),
      name: String(args.name),
    });
    return { ok: true, cookie };
  },

  async "cookies.set"(args) {
    const cookie = await chrome.cookies.set({
      url: String(args.url),
      name: String(args.name),
      value: String(args.value),
      domain: args.domain || undefined,
      path: args.path || "/",
      secure: !!args.secure,
      httpOnly: !!args.httpOnly,
      expirationDate: args.expirationDate || undefined,
    });
    return { ok: !!cookie, cookie };
  },
};

async function execCommand(cmd) {
  const action = cmd && cmd.action;
  const args = (cmd && cmd.args) || {};
  const fn = handlers[action];
  if (!fn) return { ok: false, error: "未知命令: " + action };
  try {
    const r = await fn(args);
    return { ok: true, ...r };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg) return;

  if (msg.type === "exec") {
    execCommand(msg.cmd)
      .then((r) => sendResponse({ result: safeJson(r) }))
      .catch((e) => sendResponse({ result: { ok: false, error: String(e) } }));
    return true; // 异步响应
  }

  // offscreen 没有 chrome.storage，配置由这里供给
  if (msg.type === "get-config") {
    getConfig()
      .then((config) => sendResponse({ config }))
      .catch(() => sendResponse({ config: { port: DEFAULT_PORT, token: "" } }));
    return true;
  }

  // offscreen 的心跳，写进 storage 给弹窗读
  if (msg.type === "status") {
    chrome.storage.local.set({ status: msg.status }).catch(() => {});
    sendResponse({ ok: true });
    return false;
  }

  if (msg.type === "config-changed") {
    ensureOffscreen();
    sendResponse({ ok: true });
    return false;
  }
});

// 弹窗改了端口/令牌 → 通知 offscreen 立即重连
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (!changes.port && !changes.token) return;
  chrome.runtime
    .sendMessage({ type: "config-changed" })
    .catch(() => {});
});
