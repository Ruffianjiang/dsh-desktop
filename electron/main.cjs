const { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage } = require("electron");
const { spawn } = require("child_process");
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
  sendStatus({
    state: "starting",
    message: `正在启动 DeepSeek Harness（端口 ${DEFAULT_PORT}）…`,
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

function createTray() {
  if (tray) return;
  const icon = nativeImage.createFromPath(RES("assets/icon.png"));
  tray = new Tray(icon);
  tray.setToolTip("DSH Desktop");
  const menu = Menu.buildFromTemplate([
    { label: "显示窗口", click: () => ensureWindow() },
    { type: "separator" },
    {
      label: "退出",
      click: () => {
        quitting = true;
        app.quit();
      },
    },
  ]);
  tray.setContextMenu(menu);
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
});
// Keep running in tray on window close (all platforms) — exit via tray menu.
app.on("window-all-closed", () => {});
