const { app, BrowserWindow, Menu, globalShortcut, ipcMain, screen, shell } = require("electron");
const path = require("node:path");

const appName = "Negotiator";
const devServerUrl = "http://127.0.0.1:5173";
const shouldLoadBuiltRenderer = app.isPackaged || process.env.NEGOTIATOR_DESKTOP_LOAD_DIST === "1";

let overlayWindow;

app.setName(appName);

function createApplicationMenu() {
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      {
        label: appName,
        submenu: [
          { role: "about", label: `About ${appName}` },
          { type: "separator" },
          { role: "hide", label: `Hide ${appName}` },
          { role: "hideOthers" },
          { role: "unhide" },
          { type: "separator" },
          { role: "quit", label: `Quit ${appName}` },
        ],
      },
      {
        label: "Window",
        submenu: [{ role: "minimize" }, { role: "close" }],
      },
    ]),
  );
}

function createOverlayWindow() {
  const display = screen.getPrimaryDisplay();
  const width = Math.min(520, display.workArea.width - 48);
  const height = Math.min(720, display.workArea.height - 48);
  const x = display.workArea.x + display.workArea.width - width - 24;
  const y = display.workArea.y + 24;

  overlayWindow = new BrowserWindow({
    width,
    height,
    x,
    y,
    minWidth: 380,
    minHeight: 480,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    alwaysOnTop: true,
    skipTaskbar: false,
    show: false,
    title: appName,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  overlayWindow.setAlwaysOnTop(true, "screen-saver");
  overlayWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  overlayWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });

  if (shouldLoadBuiltRenderer) {
    overlayWindow.loadFile(path.join(__dirname, "../dist/index.html"));
  } else {
    overlayWindow.loadURL(devServerUrl);
  }

  overlayWindow.once("ready-to-show", () => {
    overlayWindow.show();
  });
}

function toggleOverlayVisibility() {
  if (!overlayWindow) {
    return;
  }

  if (overlayWindow.isVisible()) {
    overlayWindow.hide();
  } else {
    overlayWindow.show();
    overlayWindow.focus();
  }
}

app.whenReady().then(() => {
  createApplicationMenu();
  createOverlayWindow();

  globalShortcut.register("CommandOrControl+Shift+Space", toggleOverlayVisibility);

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createOverlayWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("will-quit", () => {
  globalShortcut.unregisterAll();
});

ipcMain.handle("overlay:minimize", () => {
  overlayWindow?.minimize();
});

ipcMain.handle("overlay:close", () => {
  overlayWindow?.close();
});

ipcMain.handle("overlay:toggle-visibility", () => {
  toggleOverlayVisibility();
});
