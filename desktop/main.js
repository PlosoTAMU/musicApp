// Electron shell. nodeIntegration on: the renderer IS the app (fs scan, firebase,
// audio) — acceptable for a personal local app loading only local content;
// revisit before ever loading remote pages.
const { app, BrowserWindow, ipcMain, dialog, globalShortcut } = require("electron");

app.whenReady().then(() => {
  const win = new BrowserWindow({
    fullscreen: !process.env.PULSOR_SHOT,     // windowed for screenshot runs
    width: 1280,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    backgroundColor: "#0A0809",
    titleBarStyle: "hidden",
    titleBarOverlay: { color: "#0A0809", symbolColor: "#F4EDEA", height: 36 },
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });
  win.loadFile("index.html");

  ipcMain.handle("pick-folder", async () => {
    const r = await dialog.showOpenDialog(win, { properties: ["openDirectory"] });
    return r.canceled ? undefined : r.filePaths[0];
  });

  // F11 fullscreen toggle, Esc exits.
  win.webContents.on("before-input-event", (_e, input) => {
    if (input.type !== "keyDown") return;
    if (input.key === "F11") win.setFullScreen(!win.isFullScreen());
    if (input.key === "Escape" && win.isFullScreen()) win.setFullScreen(false);
  });

  // Hardware media keys → renderer → engine.route() (works when focused or not).
  for (const [accel, msg] of [
    ["MediaPlayPause", "toggle"], ["MediaNextTrack", "next"], ["MediaPreviousTrack", "prev"],
  ]) {
    globalShortcut.register(accel, () => win.webContents.send("media", msg));
  }

  // Dev screenshot driver: PULSOR_SHOT=setup|main npx electron .
  // Writes PULSOR_SHOT_OUT (or shot.png) and quits. Inert in normal runs.
  if (process.env.PULSOR_SHOT) {
    win.webContents.once("did-finish-load", async () => {
      await new Promise(r => setTimeout(r, 2500));
      if (process.env.PULSOR_SHOT === "main") {
        await win.webContents.executeJavaScript(`(() => {
          for (let i = 1; i < 99999; i++) { clearInterval(i); clearTimeout(i); }
          document.getElementById("setup").hidden = true;
          document.getElementById("main").hidden = false;
          const role = document.getElementById("role");
          role.hidden = false; role.textContent = "Remote"; role.className = "chip";
          document.getElementById("track-title").textContent = "Blinding Lights";
          document.getElementById("eq").hidden = false;
          const p = document.getElementById("progress");
          p.max = "200000"; p.value = "74000"; p.style.setProperty("--fill", "37%");
          document.getElementById("time-cur").textContent = "1:14";
          document.getElementById("time-dur").textContent = "3:20";
          document.getElementById("btn-toggle").innerHTML =
            '<svg viewBox="0 0 24 24"><path d="M7 5h3.4v14H7zM13.6 5H17v14h-3.4z"/></svg>';
          const mkRow = (list, name, chip, cls) => {
            const li = document.createElement("li");
            if (cls) li.className = cls;
            const t = document.createElement("span"); t.className = "title"; t.textContent = name; li.appendChild(t);
            if (chip) { const c = document.createElement("span"); c.className = "chip"; c.textContent = chip; li.appendChild(c); }
            const b = document.createElement("button"); b.className = "row-btn"; b.textContent = "\\u2715"; li.appendChild(b);
            list.appendChild(li);
          };
          const q = document.getElementById("queue"); q.innerHTML = "";
          mkRow(q, "Save Your Tears", "", "");
          mkRow(q, "As It Was", "not here yet", "ghost");
          mkRow(q, "Levitating", "syncing", "ghost syncing");
          document.getElementById("upnext-count").textContent = "3";
          const lib = document.getElementById("library-list"); lib.innerHTML = "";
          mkRow(lib, "Blinding Lights", "Synthwave", "playing");
          for (const n of ["After Hours", "Starboy", "Out of Time", "Die For You", "Less Than Zero"])
            mkRow(lib, n, "Downloads", "");
          document.getElementById("lib-status").textContent = "212 local tracks";
          document.getElementById("repl-status").textContent = 'Uploading \\u201CStarboy\\u201D\\u2026';
        })()`);
        await new Promise(r => setTimeout(r, 400));
      }
      const img = await win.webContents.capturePage();
      require("fs").writeFileSync(process.env.PULSOR_SHOT_OUT || "shot.png", img.toPNG());
      app.quit();
    });
  }
});

app.on("will-quit", () => globalShortcut.unregisterAll());
app.on("window-all-closed", () => app.quit());
