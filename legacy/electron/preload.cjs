const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("dsh", {
  onStatus: (cb) => ipcRenderer.on("dsh:status", (_e, payload) => cb(payload)),
  retry: () => ipcRenderer.send("dsh:retry"),
});
