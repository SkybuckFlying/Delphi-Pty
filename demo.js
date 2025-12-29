const { createPty } = require('./index');

const pty = createPty({
  command: 'cmd.exe',
  args: [],
  onData: (chunk) => process.stdout.write(chunk),
  onExit: (code) => console.log("\n[EXIT]", code),
  onError: (code, msg) => console.error("[ERR]", code, msg),
});

setTimeout(() => {
  pty.write('dir\r\n');
}, 500);

setTimeout(() => {
  pty.write('exit\r\n');
}, 2000);

// Auto-kill after 3 seconds to verify clean exit
setTimeout(async () => {
  // Wait for output before killing
  console.log("Waiting for output for 3 seconds...");
  await new Promise(resolve => setTimeout(resolve, 3000));

  console.log("Killing PTY...");
  pty.kill();
}, 3000);