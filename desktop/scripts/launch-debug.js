// Launches Electron with the CDP remote-debugging port open so tooling
// (chrome-devtools-mcp) can attach to the running app.
//
// Why a launcher instead of `electron . --remote-debugging-port=9222` inline:
// some parents (VS Code / Claude Code, themselves Electron) export
// ELECTRON_RUN_AS_NODE=1, which makes our `electron` binary boot as plain Node
// and `require("electron")` return undefined. We strip it before spawning.
const { spawn } = require("child_process");
const path = require("path");

const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;

const port = process.env.PULSOR_DEBUG_PORT || "9222";
const electron = require("electron"); // resolves to the binary path under plain Node

const child = spawn(electron, [path.join(__dirname, ".."), `--remote-debugging-port=${port}`], {
  env,
  stdio: "inherit",
});
child.on("exit", code => process.exit(code ?? 0));
