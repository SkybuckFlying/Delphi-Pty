const { createPty } = require('./index');

console.log("Starting Interactive PTY v3 (type 'exit' or Ctrl+C to quit)...");

const pty = createPty({
    command: 'cmd.exe',
    args: [],
    cols: process.stdout.columns || 80,
    rows: process.stdout.rows || 25,
    onData: (data) => {
        process.stdout.write(data);
    },
    onExit: (code) => {
        console.log(`\n\r[PTY EXIT] Code: ${code}`);
        cleanupAndExit(code);
    },
    onError: (code, msg) => {
        console.error(`\n\r[PTY ERROR] Code: ${code}, Msg: ${msg}`);
        cleanupAndExit(code || 1);
    }
});

if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
}
process.stdin.resume();

/**
 * FIXED CLEANUP LOGIC
 * We added a 'force' flag to prevent infinite loops if the exit
 * takes too long.
 */
let isExiting = false;
function cleanupAndExit(code) {
    if (isExiting) return;
    isExiting = true;

    if (process.stdin.isTTY) {
        process.stdin.setRawMode(false);
    }
    process.stdin.pause();

    // Give the DLL a tiny window to clean up, then kill the Node process
    // This is the "hammer" that solves the hang.
    setTimeout(() => {
        process.exit(code);
    }, 100);
}

process.stdin.on('data', (key) => {
    // 1. Handle Ctrl+C (Binary 0x03)
    if (key.length === 1 && key[0] === 3) {
        process.stdout.write('\n\r^C - Killing PTY...\n\r');
        pty.kill();
        // STUPIDITY FIX: Don't wait for the onExit callback.
        // Force the exit sequence now.
        cleanupAndExit(0);
        return;
    }

    // 2. Handle 'exit' command
    const inputStr = key.toString().trim().toLowerCase();
    if (inputStr === 'exit') {
        pty.write(key);
        // STUPIDITY FIX: Give cmd.exe a moment to process the exit string,
        // then trigger our own cleanup.
        setTimeout(() => cleanupAndExit(0), 200);
        return;
    }

    pty.write(key);
});

process.stdout.on('resize', () => {
    pty.resize(process.stdout.columns, process.stdout.rows);
});

// STUPIDITY FIX: Handle SIGINT (external Ctrl+C) explicitly
process.on('SIGINT', () => {
    cleanupAndExit(0);
});