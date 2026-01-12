const { createPty } = require('./index.js');

console.log("Starting PTY Test...");

const pty = createPty({
    command: 'cmd.exe',
    args: [],
    // Use \r\n for Windows cmd.exe to ensure commands actually execute
    onData: (data) => {
        process.stdout.write(`[PTY OUTPUT]: ${data.toString()}`);
    },
    onExit: (code) => {
        console.log(`\n[PROCESS EXITED] with code: ${code}`);
        process.exit(0); // Force the Node process to end once the PTY is gone
    },
    onError: (err, msg) => {
        console.error(`[PTY ERROR] ${err}: ${msg}`);
    }
});

console.log(`PTY started with PID: ${pty.pid}`);

// 1. Write 'dir' - Note the \r\n
setTimeout(() => {
    console.log("Sending 'dir'...");
    pty.write("dir\r\n");
}, 1000);

// 2. Write 'exit' - The proper way to close a shell
setTimeout(() => {
    console.log("Sending 'exit'...");
    pty.write("exit\r\n");
}, 3000);

// 3. Fail-safe: If it hasn't exited in 6 seconds, kill it hard
setTimeout(() => {
    if (pty.isAlive()) {
        console.log("PTY still hanging, forcing kill...");
        pty.kill();
        process.exit(1);
    }
}, 6000);