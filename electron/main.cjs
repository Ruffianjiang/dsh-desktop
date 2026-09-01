const {
  app,
  BrowserWindow,
  Tray,
  Menu,
  ipcMain,
  nativeImage,
  net: electronNet,
  dialog,
  shell,
  Notification,
} = require("electron");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const net = require("net");

// ---------------------------------------------------------------------------
// DeepSeek Harness desktop shell
//
// Strategy (community-standard pattern):
//   1. Spawn `dsh web` as a child process (default http://127.0.0.1:3080).
//      - If the port is already serving, attach to it instead of spawning.
//   2. Load the URL in a BrowserWindow once the port is reachable.
//   3. Window close hides to tray; tray menu "退出" truly quits and kills
//      the child process tree (taskkill /T /F on Windows) — no orphans.
// ---------------------------------------------------------------------------

const DEFAULT_PORT = Number(process.env.DSH_PORT || 3080);

let mainWindow = null;
let tray = null;
let dshProcess = null;
let dshPort = DEFAULT_PORT;
let quitting = false;
let booting = false;
let lastLogs = "";
let dshVersion = "";
let updating = false;

const RES = (p) => path.join(__dirname, p);

function dshBin() {
  return process.env.DSH_BIN || "dsh";
}

function log(line) {
  lastLogs = (lastLogs + line + "\n").split("\n").slice(-30).join("\n");
  console.log("[dsh]", line);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function portOpen(port, timeout = 600) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    const done = (ok) => {
      try { socket.destroy(); } catch (_) { /* noop */ }
      resolve(ok);
    };
    socket.setTimeout(timeout);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
    socket.connect(port, "127.0.0.1");
  });
}

async function waitForPort(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await portOpen(port)) return true;
    await sleep(400);
  }
  return false;
}

function sendStatus(payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send("dsh:status", payload);
  }
}

function killDsh() {
  if (!dshProcess) return;
  const pid = dshProcess.pid;
  dshProcess = null;
  try {
    if (process.platform === "win32") {
      // Kill the whole child tree (dsh may spawn its own children).
      spawn("taskkill", ["/pid", String(pid), "/T", "/F"], { windowsHide: true });
    } else {
      process.kill(pid, "SIGTERM");
    }
    log(`已终止 dsh 子进程树 (pid=${pid})`);
  } catch (e) {
    log("kill 失败: " + e.message);
  }
}

// Probe `dsh --version` (non-fatal; null if unavailable within 15s).
function probeDshVersion() {
  return new Promise((resolve) => {
    const child = spawn(dshBin(), ["--version"], {
      windowsHide: true,
      shell: process.platform === "win32",
      env: process.env,
    });
    let out = "";
    let settled = false;
    const finish = (v) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { child.kill(); } catch (_) { /* noop */ }
      resolve(v);
    };
    const timer = setTimeout(() => finish(null), 15000);
    child.stdout.on("data", (d) => { out += String(d); });
    child.stderr.on("data", (d) => { out += String(d); });
    child.on("error", () => finish(null));
    child.on("exit", () => {
      const line = out.trim().split(/\r?\n/).filter(Boolean).pop() || "";
      const m = line.trim().match(/^[\w.+-]+$/);
      finish(m ? m[0] : null);
    });
  });
}

// Tray-triggered kernel update: npm i -g @deepseek-ai/dsh@latest, then restart.
function updateDsh() {
  if (updating) return;
  updating = true;
  log("开始更新 dsh 内核: npm i -g @deepseek-ai/dsh@latest");
  sendStatus({
    state: "starting",
    message: "正在更新 dsh 内核（npm i -g @deepseek-ai/dsh@latest）…",
  });
  const child = spawn("npm", ["i", "-g", "@deepseek-ai/dsh@latest"], {
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
    shell: process.platform === "win32",
    env: process.env,
  });
  child.stdout.on("data", (d) => log(String(d).trim()));
  child.stderr.on("data", (d) => log("[npm] " + String(d).trim()));
  child.on("error", (err) => {
    updating = false;
    sendStatus({
      state: "failed",
      message: `更新失败：${err.message}`,
      logs: lastLogs,
    });
  });
  child.on("exit", (code) => {
    updating = false;
    if (code === 0) {
      log("dsh 更新完成，重启内核…");
      dshVersion = "";
      killDsh();
      bootstrap();
    } else {
      log(`npm 更新失败 code=${code}`);
      sendStatus({
        state: "failed",
        message: `dsh 更新失败（npm code=${code}），详见日志。`,
        logs: lastLogs,
      });
    }
  });
}

// ---------------------------------------------------------------------------
// Self-update: check GitHub Releases, download the portable exe, restart.
// Uses Electron `net` (Chromium stack) so the system proxy applies automatically.
// ---------------------------------------------------------------------------
const REPO = "Ruffianjiang/dsh-desktop";
let pendingUpdatePath = null;

function parseVer(v) {
  return String(v)
    .replace(/^v/i, "")
    .split(".")
    .map((n) => parseInt(n, 10) || 0);
}

function isNewer(a, b) {
  const A = parseVer(a);
  const B = parseVer(b);
  for (let i = 0; i < 3; i++) {
    if ((A[i] || 0) !== (B[i] || 0)) return (A[i] || 0) > (B[i] || 0);
  }
  return false;
}

function ghGetJson(url) {
  return new Promise((resolve, reject) => {
    const req = electronNet.request({
      url,
      headers: { "User-Agent": "dsh-desktop-app" },
    });
    let body = "";
    const timer = setTimeout(() => {
      try { req.abort(); } catch (_) { /* noop */ }
      reject(new Error("请求超时"));
    }, 15000);
    req.on("response", (res) => {
      res.on("data", (c) => { body += String(c); });
      res.on("end", () => {
        clearTimeout(timer);
        if (res.statusCode !== 200) {
          return reject(new Error("HTTP " + res.statusCode));
        }
        try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
      });
    });
    req.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    req.end();
  });
}

function downloadFile(url, dest) {
  return new Promise((resolve, reject) => {
    const req = electronNet.request({
      url,
      headers: { "User-Agent": "dsh-desktop-app" },
    });
    let received = 0;
    let lastLogged = 0;
    const timer = setTimeout(() => {
      try { req.abort(); } catch (_) { /* noop */ }
      reject(new Error("下载超时"));
    }, 10 * 60 * 1000);
    req.on("response", (res) => {
      if (res.statusCode !== 200) {
        clearTimeout(timer);
        return reject(new Error("HTTP " + res.statusCode));
      }
      const file = fs.createWriteStream(dest);
      res.on("data", (c) => {
        received += c.length;
        const mb = received / 1048576;
        if (mb - lastLogged >= 10) {
          lastLogged = mb;
          log(`下载中 ${mb.toFixed(1)} MB…`);
        }
      });
      res.pipe(file);
      file.on("finish", () => {
        file.close(() => {
          clearTimeout(timer);
          log(`下载完成: ${dest}`);
          resolve(dest);
        });
      });
      file.on("error", (e) => {
        clearTimeout(timer);
        reject(e);
      });
    });
    req.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    req.end();
  });
}

function applyUpdate(filePath) {
  pendingUpdatePath = filePath;
  quitting = true;
  killDsh();
  app.quit();
}

async function checkAppUpdate() {
  try {
    log("检查应用更新…");
    const rel = await ghGetJson(`https://api.github.com/repos/${REPO}/releases/latest`);
    const tag = rel.tag_name || "";
    if (!isNewer(tag, app.getVersion())) {
      new Notification({
        title: "DSH Desktop",
        body: `已是最新版本（v${app.getVersion()}）`,
      }).show();
      return;
    }
    const asset = (rel.assets || []).find((a) =>
      /^DSH-Desktop-.*-portable\.exe$/.test(a.name)
    );
    if (!asset) {
      new Notification({
        title: "发现新版本",
        body: `${tag} 已发布，但未找到 portable 安装包资产`,
      }).show();
      return;
    }
    new Notification({
      title: "发现新版本",
      body: `v${app.getVersion()} → ${tag}，开始下载…`,
    }).show();
    const dest = path.join(app.getPath("downloads"), asset.name);
    await downloadFile(asset.browser_download_url, dest);
    const r = await dialog.showMessageBox({
      type: "info",
      title: "更新就绪",
      message: `${tag} 已下载完成`,
      detail: `${dest}\n\n「立即重启升级」将退出当前应用并启动新版本。`,
      buttons: ["立即重启升级", "打开下载目录", "稍后"],
      defaultId: 0,
      cancelId: 2,
    });
    if (r.response === 0) applyUpdate(dest);
    else if (r.response === 1) shell.showItemInFolder(dest);
  } catch (e) {
    log("检查更新失败: " + ((e && e.message) || e));
    new Notification({
      title: "检查更新失败",
      body: String((e && e.message) || e),
    }).show();
  }
}

function spawnDsh() {
  const args = ["web"];
  // Only pass --port when explicitly overridden; the default 3080 path uses
  // the well-known bare `dsh web` invocation.
  if (DEFAULT_PORT !== 3080) {
    args.push("--port", String(DEFAULT_PORT));
  }
  log(`spawn: ${dshBin()} ${args.join(" ")}`);
  // Windows: npm installs `dsh` as a .cmd shim — spawn it through the shell
  // so CreateProcess can resolve it. Args are static (no user input).
  const child = spawn(dshBin(), args, {
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
    env: process.env,
    shell: process.platform === "win32",
  });
  dshProcess = child;
  child.stdout.on("data", (d) => log(String(d).trim()));
  child.stderr.on("data", (d) => log("[stderr] " + String(d).trim()));
  child.on("error", (err) => {
    log("spawn error: " + err.message);
    sendStatus({
      state: "failed",
      message: `未找到可执行文件 "${dshBin()}"（${err.message}）。请先执行 npm i -g @deepseek-ai/dsh，或设置环境变量 DSH_BIN 指向 dsh 可执行文件。`,
      logs: lastLogs,
    });
  });
  child.on("exit", (code) => {
    if (dshProcess === child) dshProcess = null;
    if (!quitting) {
      log(`dsh 进程退出 code=${code}`);
      sendStatus({
        state: "failed",
        message: `dsh 进程已退出（code=${code}）。`,
        logs: lastLogs,
      });
    }
  });
}

async function ensureDshRunning() {
  // Attach mode: something is already serving on the port (likely an
  // existing dsh instance) — reuse it instead of spawning a second one.
  if (await portOpen(DEFAULT_PORT)) {
    dshPort = DEFAULT_PORT;
    log(`端口 ${DEFAULT_PORT} 已有服务，复用（attach 模式）`);
    return true;
  }
  spawnDsh();
  const ok = await waitForPort(DEFAULT_PORT, 90_000);
  if (ok) {
    dshPort = DEFAULT_PORT;
    return true;
  }
  sendStatus({
    state: "failed",
    message: `等待 http://127.0.0.1:${DEFAULT_PORT} 超时（90s）。请查看下方日志排查。`,
    logs: lastLogs,
  });
  return false;
}

async function bootstrap() {
  if (booting) return;
  booting = true;
  ensureWindow();
  dshVersion = (await probeDshVersion()) || dshVersion;
  refreshTray();
  sendStatus({
    state: "starting",
    message: `正在启动 DeepSeek Harness${dshVersion ? " " + dshVersion : ""}（端口 ${DEFAULT_PORT}）…`,
  });
  const ok = await ensureDshRunning();
  booting = false;
  if (!ok) return;
  sendStatus({ state: "ready", url: `http://127.0.0.1:${dshPort}` });
  try {
    await mainWindow.loadURL(`http://127.0.0.1:${dshPort}`);
  } catch (e) {
    log("loadURL 失败: " + e.message);
  }
}

function ensureWindow() {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.show();
    mainWindow.focus();
    return mainWindow;
  }
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 960,
    minHeight: 600,
    title: "DSH Desktop",
    icon: RES("assets/icon.png"),
    autoHideMenuBar: true,
    backgroundColor: "#0f1115",
    show: false,
    webPreferences: {
      preload: RES("preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWindow.once("ready-to-show", () => mainWindow.show());
  mainWindow.loadFile(RES("error.html"));
  mainWindow.on("close", (e) => {
    if (!quitting) {
      e.preventDefault();
      mainWindow.hide();
    }
  });
  return mainWindow;
}

function trayTooltip() {
  return dshVersion ? `DSH Desktop — dsh ${dshVersion}` : "DSH Desktop";
}

function buildTrayMenu() {
  return Menu.buildFromTemplate([
    { label: dshVersion ? `dsh ${dshVersion}` : "dsh 版本未知", enabled: false },
    { label: `应用 v${app.getVersion()}`, enabled: false },
    { type: "separator" },
    { label: "显示窗口", click: () => ensureWindow() },
    { label: "更新 dsh 内核…", click: () => updateDsh() },
    { label: "检查应用更新…", click: () => checkAppUpdate() },
    { type: "separator" },
    {
      label: "退出",
      click: () => {
        quitting = true;
        app.quit();
      },
    },
  ]);
}

function refreshTray() {
  if (!tray) return;
  tray.setToolTip(trayTooltip());
  tray.setContextMenu(buildTrayMenu());
}

function createTray() {
  if (tray) return;
  const icon = nativeImage.createFromPath(RES("assets/icon.png"));
  tray = new Tray(icon);
  refreshTray();
  tray.on("click", () => ensureWindow());
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on("second-instance", () => ensureWindow());
  ipcMain.on("dsh:retry", () => {
    killDsh();
    bootstrap();
  });
  app.whenReady().then(() => {
    app.setAppUserModelId("com.deepseek.harness.desktop");
    createTray();
    bootstrap();
  });
}

app.on("before-quit", () => {
  quitting = true;
  killDsh();
});
app.on("will-quit", () => {
  killDsh();
  if (pendingUpdatePath) {
    // Launch the freshly downloaded portable exe while we exit. Its NSIS
    // self-extraction takes a few seconds, by which time the single-instance
    // lock of the old version has been released.
    try {
      const child = spawn(pendingUpdatePath, [], {
        detached: true,
        stdio: "ignore",
        windowsHide: true,
      });
      child.unref();
    } catch (_) { /* noop */ }
  }
});
// Keep running in tray on window close (all platforms) — exit via tray menu.
app.on("window-all-closed", () => {});
