const { createPty } = require('./index');
const path = require('path');

console.log("Starting Comprehensive Demo...");

const pty = createPty({
    command: 'cmd.exe',
    args: ['/c', 'dir'],
    cwd: process.cwd(),
    env: {
        ...process.env,
        PTY_TEST_VAR: 'DelphiPtyRocks'
    },
    cols: 80,
    rows: 24,
    onData: (data) => {
        process.stdout.write(`[PTY DATA]: ${data}`);
    },
    onExit: (code) => {
        console.log(`\n[PTY EXIT] Code: ${code}`);
        process.exit(0);
    },
    onError: (code, msg) => {
        console.error(`[PTY ERROR] Code: ${code}, Msg: ${msg}`);
    }
});

console.log(`PTY Created with handle: ${pty.handle}`);

setTimeout(() => {
    console.log("\nResizing PTY to 120x40...");
    pty.resize(120, 40);
}, 1000);

setTimeout(() => {
    if (pty.isAlive()) {
        console.log("\nPTY is still alive. Sending 'whoami'...");
        pty.write('whoami\r\n');
    }
}, 2000);

setTimeout(() => {
    console.log("\nClosing PTY gracefully...");
    pty.close();
}, 5000);

// Fallback timeout
setTimeout(() => {
    console.log("\nDemo timed out. Killing PTY...");
    pty.kill();
    process.exit(1);
}, 10000);
