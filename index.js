const ref = require("ref-napi");
const { lib, types } = require("./native");

function toCStringArray(arr) {
  const CStringArray = types.CStringArray;
  if (!arr || !arr.length) {
    return new CStringArray([]);
  }
  return new CStringArray(arr);
}

function buildEnvArray(envObj) {
  if (!envObj) return toCStringArray([]);
  const pairs = Object.keys(envObj).map(k => `${k}=${envObj[k]}`);
  return toCStringArray(pairs);
}

function checkRc(rc, context) {
  if (rc >= 0) return;
  const msg = `${context} failed, code=${rc}`;
  throw new Error(msg);
}

const initRc = lib.Pty_Init();
if (initRc < 0) {
  throw new Error("DelphiPty: ConPTY init failed, code=" + initRc);
}

function createPty(opts) {
  const {
    command,
    args = [],
    cwd = process.cwd(),
    env = process.env,
    cols = 80,
    rows = 25,
    onData,
    onExit,
    onError
  } = opts || {};

  if (!command) {
    throw new Error("createPty: command is required");
  }

  const argsArr = args.map(String);
  const argsRef = toCStringArray(argsArr);
  const envRef  = buildEnvArray(env);

  const onDataCb = types.dataCbType((handle, data, len) => {
    if (onData) onData(data);
  });

  const onExitCb = types.exitCbType((handle, exitCode) => {
    if (onExit) onExit(exitCode);
  });

  const onErrorCb = types.errCbType((handle, code, msg) => {
    if (onError) onError(code, msg);
    else console.error("[DelphiPty error]", code, msg);
  });

  const handle = lib.Pty_Create(
    command,
    argsRef,
    argsArr.length,
    cwd,
    envRef,
    cols,
    rows,
    onDataCb,
    onExitCb,
    onErrorCb
  );

  if (handle <= 0) {
    throw new Error("Pty_Create failed with code " + handle);
  }

  function write(data) {
    const s = typeof data === "string" ? data : data.toString("binary");
    const rc = lib.Pty_Write(handle, s, s.length);
    checkRc(rc, "Pty_Write");
  }

  function resize(newCols, newRows) {
    const rc = lib.Pty_Resize(handle, newCols, newRows);
    checkRc(rc, "Pty_Resize");
  }

  function close() {
    const rc = lib.Pty_Close(handle);
    checkRc(rc, "Pty_Close");
  }

  function kill() {
    const rc = lib.Pty_Kill(handle);
    checkRc(rc, "Pty_Kill");
  }

  function isAlive() {
    const v = lib.Pty_IsAlive(handle);
    if (v < 0) return false;
    return v === 1;
  }

  function getExitCode() {
    const out = ref.alloc("int");
    const rc = lib.Pty_GetExitCode(handle, out);
    checkRc(rc, "Pty_GetExitCode");
    return out.deref();
  }

  return {
    handle,
    write,
    resize,
    close,
    kill,
    isAlive,
    getExitCode
  };
}

module.exports = { createPty };