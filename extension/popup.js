/** Edge AI Bridge — 设置与状态弹窗 */

const $ = (id) => document.getElementById(id);

async function load() {
  const c = await chrome.storage.local.get(["port", "token", "status"]);
  $("port").value = c.port || 8800;
  $("token").value = c.token || "";
  renderStatus(c.status);
}

function renderStatus(st) {
  const box = $("status");
  if (!st || !st.updatedAt) {
    box.innerHTML = '<span class="dot"></span>尚未检测（服务未启动或扩展刚安装）';
    return;
  }
  const ago = Math.max(0, Math.round((Date.now() - st.updatedAt) / 1000));
  const alive = ago < 15;
  const lines = [
    `<span class="dot ${alive ? "on" : "off"}"></span>${alive ? "轮询正常" : "连接中断"}（${ago}s 前心跳）`,
    `实例：${st.iid || "-"}`,
    `已执行任务：${st.tasks || 0}　错误：${st.errors || 0}`,
  ];
  if (st.lastError) lines.push(`最近错误：${st.lastError}`);
  if (st.lastTask) lines.push(`最近任务：${st.lastTask.action} #${st.lastTask.id}`);
  box.innerHTML = lines.join("<br />");
}

async function save() {
  const port = Number($("port").value) || 8800;
  const token = $("token").value.trim();
  await chrome.storage.local.set({ port, token });
  // 通知后台重启 offscreen 轮询
  try {
    await chrome.runtime.sendMessage({ type: "config-changed" });
  } catch (e) {
    /* 忽略 */
  }
  $("status").innerHTML = '<span class="dot on"></span>已保存，正在重新连接…';
  setTimeout(refresh, 1500);
}

async function test() {
  const port = Number($("port").value) || 8800;
  const token = $("token").value.trim();
  $("status").innerHTML = '<span class="dot"></span>测试中…';
  try {
    const headers = token ? { "X-Bridge-Token": token } : {};
    const res = await fetch(`http://127.0.0.1:${port}/health`, { headers });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const data = await res.json();
    const peers = (data.instances || []).length;
    $("status").innerHTML = [
      `<span class="dot on"></span>服务正常（端口 ${port}）`,
      `在线实例：${peers}`,
      `待执行任务：${data.pending || 0}`,
      data.active ? `活跃实例：${data.active}` : "活跃实例：无",
    ].join("<br />");
  } catch (e) {
    $("status").innerHTML =
      `<span class="dot off"></span>连不上服务：${String((e && e.message) || e)}<br />` +
      "请先运行 <code>python server/bridge.py</code>";
  }
}

async function refresh() {
  const c = await chrome.storage.local.get(["status"]);
  renderStatus(c.status);
}

$("save").addEventListener("click", save);
$("test").addEventListener("click", test);
load();
setInterval(refresh, 2000);
