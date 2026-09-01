const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("recorder", {
  onBegin: (cb) => ipcRenderer.on("rec:begin", (_e, payload) => cb(payload)),
  onStop: (cb) => ipcRenderer.on("rec:stop", () => cb()),
  chunk: (u8) => ipcRenderer.send("rec:chunk", u8),
  ended: () => ipcRenderer.send("rec:ended"),
  error: (msg) => ipcRenderer.send("rec:error", String(msg)),
});
