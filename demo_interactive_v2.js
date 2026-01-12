const { createPty } = require('./index');

console.log("Starting Interactive PTY (type 'exit' to quit)...");

const pty = createPty({
    command: 'cmd.exe',
    args: [],
    // Force dimensions immediately to prevent line-wrap issues
    cols: process.stdout.columns || 80,
    rows: process.stdout.rows || 25,
    onData: (data) => {
        // Data is a Buffer, write it directly to terminal
        process.stdout.write(data);
    },
    onExit: (code) => {
        console.log(`\n[PTY EXIT] Code: ${code}`);

        // --- THE HANG FIX ---
        process.stdin.setRawMode(false); // Restore normal terminal behavior
        process.stdin.pause();           // Stop listening to keyboard
        // --------------------
    },
    onError: (code, msg) => {
        console.error(`\n[PTY ERROR] Code: ${code}, Msg: ${msg}`);
    }
});

// Setup Stdin for raw binary interaction
process.stdin.setRawMode(true);
process.stdin.resume();
// NO setEncoding('utf8') here - we want raw binary for Backspace stability

process.stdin.on('data', (key) => {
    // Key is a Buffer. Check for Ctrl+C (0x03)
    if (key.length === 1 && key[0] === 3) {
        console.log("\nCtrl+C detected. Killing PTY...");
        pty.kill();
        // The onExit callback will handle the cleanup/exit
        return;
    }

    // Write the raw buffer directly to the PTY
    // This fixes the "Backspace deletes whole line" issue
    pty.write(key);
});

// Handle terminal window resizing
process.stdout.on('resize', () => {
    const { columns, rows } = process.stdout;
    pty.resize(columns, rows);
});