// Electron shell. nodeIntegration on: the renderer IS the app (fs scan, firebase,
// audio) — acceptable for a personal local app loading only local content;
// revisit before ever loading remote pages.
const { app, BrowserWindow, ipcMain, dialog, globalShortcut } = require("electron");
const path = require("path");

// The app owns the media keys (globalShortcut below → renderer toggle). With
// Chromium's built-in handling left on, a play/pause key ALSO pauses the
// <audio> element directly, so one press toggled twice and ended where it
// started. Standard Electron fix for apps that register MediaPlayPause.
app.commandLine.appendSwitch("disable-features", "HardwareMediaKeyHandling,MediaSessionService");

app.whenReady().then(() => {
  const win = new BrowserWindow({
    show: false,                              // shown maximized below (no flash)
    // PULSOR_SHOT_W/H: dev screenshot driver only (see below).
    width: Number(process.env.PULSOR_SHOT_W) || 1280,
    height: Number(process.env.PULSOR_SHOT_H) || 800,
    minWidth: 900,
    minHeight: 600,
    backgroundColor: "#0A0809",
    icon: path.join(__dirname, "build", "icon.png"),
    titleBarStyle: "hidden",
    titleBarOverlay: { color: "#0A0809", symbolColor: "#F4EDEA", height: 36 },
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });
  // Maximized, NOT fullscreen — F11 still toggles fullscreen on demand.
  if (!process.env.PULSOR_SHOT) win.maximize();
  win.show();
  win.loadFile("index.html");

  // Closing while this device owns the shared session: hold the window for
  // up to 1.5 s so the renderer can hand the session back (paused at the
  // current position) instead of leaving a phantom owner that the phone only
  // gives up on after the 45 s lease (sync-audit-5 S7). destroy() skips a
  // second `close`, so this runs exactly once.
  let releasing = false;
  win.on("close", e => {
    if (releasing) return;
    releasing = true;
    e.preventDefault();
    let done = false;
    const finish = () => { if (done) return; done = true; clearTimeout(timer); win.destroy(); };
    const timer = setTimeout(finish, 1500);
    ipcMain.once("seat-released", finish);
    win.webContents.send("release-seat");
  });

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

  // E2E connect driver: PULSOR_E2E_SECRET=<phrase> npx electron .
  // Types the secret, clicks Connect, prints the visible status every 2 s
  // until the main view appears (or 40 s), then quits. Inert in normal runs.
  if (process.env.PULSOR_E2E_SECRET) {
    win.webContents.on("console-message", (_e, _lvl, msg) => console.log("[renderer]", msg));
    win.webContents.once("did-finish-load", async () => {
      await new Promise(r => setTimeout(r, 1500));
      await win.webContents.executeJavaScript(`(() => {
        const s = document.getElementById("secret-input");
        s.value = ${JSON.stringify(process.env.PULSOR_E2E_SECRET)};
        document.getElementById("btn-connect").click();
      })()`);
      for (let i = 0; i < 20; i++) {
        await new Promise(r => setTimeout(r, 2000));
        const st = await win.webContents.executeJavaScript(`JSON.stringify({
          status: document.getElementById("setup-status").textContent,
          main: !document.getElementById("main").hidden,
          role: document.getElementById("role").textContent,
        })`);
        console.log("[e2e]", st);
        if (JSON.parse(st).main) break;
      }
      app.quit();
    });
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
          document.getElementById("btn-toggle").classList.add("playing");
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
          // Real renderer for the library rows when the renderer exposes its
          // stage hook (PULSOR_SHOT builds), so the shot shows the actual row
          // markup; hand-built rows otherwise.
          const names = ["Blinding Lights", "After Hours", "Starboy", "Out of Time", "Die For You", "Less Than Zero"];
          if (window.__pulsorStage) {
            window.__pulsorStage(names);
          } else {
            const lib = document.getElementById("library-list"); lib.innerHTML = "";
            mkRow(lib, "Blinding Lights", "Synthwave", "playing");
            for (const n of names.slice(1)) mkRow(lib, n, "Downloads", "");
          }
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
