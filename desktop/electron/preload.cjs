const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("negotiatorOverlay", {
  minimize: () => ipcRenderer.invoke("overlay:minimize"),
  close: () => ipcRenderer.invoke("overlay:close"),
  toggleVisibility: () => ipcRenderer.invoke("overlay:toggle-visibility"),
});
