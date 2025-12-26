const { createPty } = require("./index");

const pty = createPty({
  command: "cmd.exe",
  args: [],
  cols: 80,
  rows: 25,
  onData: (chunk) => {
    process.stdout.write(chunk);
  },
  onExit: (code) => {
    console.log("\n[PTY exited] code =", code);
  },
  onError: (errCode, msg) => {
    console.error("[PTY error]", errCode, msg);
  }
});

setTimeout(() => {
  pty.write("dir\r\n");
}, 500);

setTimeout(() => {
  pty.resize(120, 40);
}, 2000);

setTimeout(() => {
  pty.close();
}, 5000);