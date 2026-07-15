// TEMP audit driver — copy of main.js's shot path with richer staging.
// Run: env -u ELECTRON_RUN_AS_NODE ./node_modules/.bin/electron.cmd main.audit.js
// DELETE THIS FILE after the audit.
const { app, BrowserWindow, ipcMain, dialog } = require("electron");
const path = require("path");

app.whenReady().then(() => {
  const win = new BrowserWindow({
    show: true,
    width: Number(process.env.AUDIT_W || 900),
    height: Number(process.env.AUDIT_H || 600),
    minWidth: 900,
    minHeight: 600,
    backgroundColor: "#0A0809",
    titleBarStyle: "hidden",
    titleBarOverlay: { color: "#0A0809", symbolColor: "#F4EDEA", height: 36 },
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });
  win.loadFile("index.html");
  ipcMain.handle("pick-folder", async () => undefined);

  win.webContents.on("console-message", (_e, _lvl, msg) => console.log("[r]", msg));
  win.webContents.once("did-finish-load", async () => {
    await new Promise(r => setTimeout(r, 3000));
    const report = await win.webContents.executeJavaScript(`(async () => {
      const $ = id => document.getElementById(id);
      // Stage: force main visible, many library rows, lyrics open w/ lines.
      $("setup").hidden = true; $("main").hidden = false;
      const lib = $("library-list"); lib.innerHTML = "";
      for (let i = 0; i < 60; i++) {
        const li = document.createElement("li");
        const t = document.createElement("span"); t.className = "title";
        t.textContent = "Track number " + i; li.appendChild(t);
        lib.appendChild(li);
      }
      const q = $("queue"); q.innerHTML = "";
      for (let i = 0; i < 12; i++) {
        const li = document.createElement("li");
        const t = document.createElement("span"); t.className = "title";
        t.textContent = "Queued " + i; li.appendChild(t);
        q.appendChild(li);
      }
      // Open lyrics via the real button, then inject lines.
      if ($("lyrics-panel").hidden) $("btn-lyrics").click();
      const body = $("lyrics-body"); body.innerHTML = "";
      for (let i = 0; i < 40; i++) {
        const d = document.createElement("div"); d.className = "lyr-line";
        d.textContent = "Lyric line " + i; body.appendChild(d);
      }
      await new Promise(r => setTimeout(r, 300));
      const m = el => ({ sh: el.scrollHeight, ch: el.clientHeight, st: el.scrollTop });
      const openState = {
        lyricsHidden: $("lyrics-panel").hidden,
        lyricsDisplay: getComputedStyle($("lyrics-panel")).display,
        bodyScroll: m(document.body),
        mainRect: $("main").getBoundingClientRect().toJSON(),
        content: m(document.querySelector(".content")),
        libraryUl: m($("library-list")),
        queueUl: m($("queue")),
        lyricsBody: m($("lyrics-body")),
        libPanelRect: $("library-panel").getBoundingClientRect().toJSON(),
        railScroll: m(document.querySelector(".rail")),
        railLastChildBottom: (() => {
          const fx = $("fx"); return fx.getBoundingClientRect().bottom;
        })(),
        railTopTop: document.querySelector(".rail-top").getBoundingClientRect().top,
        winH: innerHeight, winW: innerWidth,
        statuslineRect: document.querySelector(".statusline").getBoundingClientRect().toJSON(),
      };
      // Now try to CLOSE lyrics via the content-head button.
      $("btn-lyrics").click();
      await new Promise(r => setTimeout(r, 700));
      const afterClose = {
        lyricsHidden: $("lyrics-panel").hidden,
        lyricsDisplay: getComputedStyle($("lyrics-panel")).display,
      };
      // Reopen and close via the rail button.
      $("btn-lyrics").click();
      await new Promise(r => setTimeout(r, 200));
      $("rail-lyrics").click();
      await new Promise(r => setTimeout(r, 200));
      const afterRailClose = {
        lyricsHidden: $("lyrics-panel").hidden,
        lyricsDisplay: getComputedStyle($("lyrics-panel")).display,
      };
      return JSON.stringify({ openState, afterClose, afterRailClose }, null, 1);
    })()`);
    console.log("REPORT", report);
    const img = await win.webContents.capturePage();
    require("fs").writeFileSync(process.env.AUDIT_OUT || "shot-audit.png", img.toPNG());
    app.quit();
  });
});
app.on("window-all-closed", () => app.quit());
