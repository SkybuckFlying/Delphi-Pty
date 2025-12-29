const { createPty } = require('./index');

console.log("Starting Interactive PTY (type 'exit' to quit)...");

const pty = createPty({
    command: 'cmd.exe',
    args: [],
    onData: (data) => {
        process.stdout.write(data);
    },
    onExit: (code) => {
        console.log(`\n[PTY EXIT] Code: ${code}`);
        process.exit(0);
    },
    onError: (code, msg) => {
        console.error(`[PTY ERROR] Code: ${code}, Msg: ${msg}`);
    }
});

process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.setEncoding('utf8');

process.stdin.on('data', (key) => {
    // Ctrl+C
    if (key === '\u0003') {
        console.log("\nCtrl+C detected. Killing PTY...");
        pty.kill();
        process.exit();
    }

    pty.write(key);
});

// Handle terminal resize if possible
process.stdout.on('resize', () => {
    const { columns, rows } = process.stdout;
    console.log(`\nResizing PTY to ${columns}x${rows}`);
    pty.resize(columns, rows);
});
