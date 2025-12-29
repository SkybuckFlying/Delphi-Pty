const { createPty, write, resize, kill, isAlive } = require('./index');

console.log("Testing Error Handling...");

// Case 1: Non-existent command
try {
    console.log("\n1. Spawning non-existent command...");
    const pty1 = createPty({
        command: 'non_existent_command_12345.exe',
        onData: (data) => console.log("Data:", data),
        onError: (code, msg) => console.log("Expected Error Callback:", code, msg)
    });
} catch (e) {
    console.log("Expected Catch:", e.message);
}

// Case 2: Invalid handle operations
console.log("\n2. Testing invalid handle operations...");
const invalidHandle = 99999;
console.log("Write to invalid handle:", write(invalidHandle, "test"));
console.log("Resize invalid handle:", resize(invalidHandle, 80, 25));
console.log("IsAlive invalid handle:", isAlive(invalidHandle));

// Case 3: Double close/kill
console.log("\n3. Testing double close/kill...");
const pty2 = createPty({
    command: 'cmd.exe',
    args: ['/c', 'echo hi'],
    onData: (data) => { },
    onExit: (code) => console.log("PTY2 Exit Code:", code)
});

setTimeout(() => {
    console.log("Closing PTY2...");
    pty2.close();
    console.log("Closing PTY2 again...");
    console.log("Second close result:", pty2.close());
    console.log("Killing PTY2...");
    console.log("Kill result:", pty2.kill());
}, 1000);

setTimeout(() => {
    console.log("\nError demo finished.");
    process.exit(0);
}, 3000);
