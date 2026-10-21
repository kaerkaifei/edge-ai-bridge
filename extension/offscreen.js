/**
 * Edge AI Bridge — offscreen 轮询器
 *
 * 为什么要有这个文件：
 *   MV3 的 service worker 在空闲约 30 秒后会被杀掉，setInterval 也跟着没了。
 *   offscreen document 的生命周期独立、可以常驻，把轮询放在这里最稳。
 *
 * 为什么这里一行 chrome.storage 都没有：
 *   实测（Edge 155 / Chromium 155）offscreen 文档里 chrome.storage 是 undefined，
 *   直接调 chrome.storage.local.get 会抛 TypeError。这个异常被 loop 的 catch 吞掉，
 *   表现就是「扩展装上了、进程也在、但一个请求都不发」——非常难查。
 *   所以配置一律通过 chrome.runtime.sendMessage 向 background 要，
 *   状态也交给 background 去写 storage。
 *
 * offscreen 也不能调 chrome.tabs / chrome.scripting，
 * 真正的浏览器操作同样转发给 background 执行。
 */

const POLL_INTERVAL = 1000; // 轮询间隔（毫秒）
const MAX_BACKOFF = 8000;

/**
 * 浏览器名，写在实例 id 前面发给桥接服务。
 *
 * 为什么需要它：安装脚本要判断「即将同步的那个浏览器装没装插件」。
 * 光看「有没有实例在线」会骗人——可能在线的是 Chrome，而用户要同步的是 Edge。
 * navigator.userAgent 在 offscreen 文档里是可用的（和 chrome.storage 不一样）。
 */
const BROWSER_TAG = (() => {
  const ua = (navigator.userAgent || "").toLowerCase();
  if (ua.includes("edg/")) return "edge";
  if (ua.includes("brave/")) return "brave";
  if (ua.includes("vivaldi/")) return "vivaldi";
  if (ua.includes("opr/")) return "opera";
  if (ua.includes("chrome/")) return "chrome";
  return "chromium";
})();

let iid = null;
let busy = false;
let backoff = POLL_INTERVAL;
let timer = null;
let stats = { polls: 0, tasks: 0, errors: 0, lastError: "", lastTask: null };

function instanceId() {
  if (!iid) {
    // 形如 edge-ab12cd34x1kz9，前缀让服务端一眼认出浏览器
    iid = BROWSER_TAG + "-" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
  }
  return iid;
}

/** 配置从 background 拿（offscreen 没有 chrome.storage） */
async function getConfig() {
  const r = await chrome.runtime.sendMessage({ type: "get-config" });
  const cfg = (r && r.config) || {};
  return {
    port: Number(cfg.port) || 8800,
    token: String(cfg.token || ""),
  };
}

function headers(cfg) {
  const h = { "Content-Type": "application/json" };
  if (cfg.token) h["X-Bridge-Token"] = cfg.token;
  return h;
}

/** 心跳交给 background 写进 storage，弹窗才看得到 */
async function reportStatus() {
  try {
    await chrome.runtime.sendMessage({
      type: "status",
      status: { iid: instanceId(), ...stats, updatedAt: Date.now() },
    });
  } catch (e) {
    /* background 暂时不在，忽略 */
  }
}

async function pollOnce() {
  if (busy) return;

  let cfg;
  try {
    cfg = await getConfig();
  } catch (e) {
    stats.errors++;
    stats.lastError = "取配置失败: " + String((e && e.message) || e);
    backoff = Math.min(backoff * 1.6, MAX_BACKOFF);
    return;
  }
  if (!cfg.port) return;

  const url = `http://127.0.0.1:${cfg.port}/task?iid=${encodeURIComponent(instanceId())}`;

  let task = null;
  try {
    const res = await fetch(url, { headers: headers(cfg), cache: "no-store" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const data = await res.json();
    task = data && data.task;
    backoff = POLL_INTERVAL;
    stats.polls++;
    stats.lastError = "";
  } catch (e) {
    stats.errors++;
    stats.lastError = String((e && e.message) || e);
    backoff = Math.min(backoff * 1.6, MAX_BACKOFF);
    await reportStatus();
    return;
  }

  if (!task) {
    await reportStatus();
    return;
  }

  busy = true;
  stats.tasks++;
  stats.lastTask = { id: task.id, action: task.action, at: Date.now() };

  let result;
  try {
    const resp = await chrome.runtime.sendMessage({ type: "exec", cmd: task });
    result = resp && resp.result ? resp.result : { ok: false, error: "后台没有返回结果" };
  } catch (e) {
    result = { ok: false, error: String((e && e.message) || e) };
  }

  try {
    await fetch(`http://127.0.0.1:${cfg.port}/ack`, {
      method: "POST",
      headers: headers(cfg),
      body: JSON.stringify({ id: task.id, ...result }),
    });
  } catch (e) {
    stats.errors++;
    stats.lastError = String((e && e.message) || e);
  }

  busy = false;
  await reportStatus();
}

function loop() {
  clearTimeout(timer);
  pollOnce()
    .catch(() => {})
    .finally(() => {
      timer = setTimeout(loop, backoff);
    });
}

// 启动
loop();

// background 转发来的配置变更：立即重连，别等退避
chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.type === "config-changed") {
    backoff = POLL_INTERVAL;
    loop();
  }
});

// 每 20 秒刷一次心跳，方便弹窗判断死活
setInterval(reportStatus, 20000);
