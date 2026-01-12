const addon = require('./build/Release/delphi_pty.node');

/**
 * Ensures data is in a Buffer format for the native addon.
 */
function toBuffer(data) {
  if (Buffer.isBuffer(data) || data instanceof Uint8Array) return data;
  return Buffer.from(String(data));
}

function createPty(opts) {
  const {
    command,
    args = [],
    cwd = process.cwd(),
    env = process.env,
    cols = process.stdout.columns || 80,
    rows = process.stdout.rows || 25,
    onData,
    onExit,
    onError,
  } = opts || {};

  if (!command) {
    throw new Error("createPty: command is required");
  }

  const handle = addon.createPtyNative({
    command,
    args,
    cwd,
    env,
    cols,
    rows,
    onData: onData || ((chunk) => process.stdout.write(chunk)),
    onExit: onExit || ((code) => console.log("PTY exit", code)),
    onError: onError || ((code, msg) => console.error("PTY error", code, msg)),
  });

  return {
    handle,
    write:       (data) => addon.write(handle, toBuffer(data)),
    resize:      (c, r) => addon.resize(handle, c, r),
    close:       ()     => addon.close(handle),
    kill:        ()     => addon.kill(handle),
    isAlive:     ()     => addon.isAlive(handle),
    getExitCode: ()     => addon.getExitCode(handle),
  };
}

module.exports = {
  createPty,
  write: (handle, data) => addon.write(handle, toBuffer(data)),
  resize: addon.resize,
  close: addon.close,
  kill: addon.kill,
  isAlive: addon.isAlive,
  getExitCode: addon.getExitCode,
};