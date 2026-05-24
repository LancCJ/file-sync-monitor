const { spawnSync } = require("child_process");
const os = require("os");
const path = require("path");

const command = process.argv[2] || "dev";
const root = path.resolve(__dirname, "..");
const kernelDir = path.join(root, "sync-kernel");
const cargoBin = path.join(os.homedir(), ".cargo", "bin");
const tauriBin = path.join(
  root,
  "node_modules",
  ".bin",
  process.platform === "win32" ? "tauri.cmd" : "tauri"
);

const env = {
  ...process.env,
  PATH: `${cargoBin}${path.delimiter}${process.env.PATH || ""}`,
};

const executable = require("fs").existsSync(tauriBin) ? tauriBin : "tauri";
const result = spawnSync(executable, [command], {
  cwd: kernelDir,
  env,
  stdio: "inherit",
  shell: process.platform === "win32",
});

process.exit(result.status ?? 1);
