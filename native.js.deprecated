const ffi = require("ffi-napi");
const ref = require("ref-napi");
const ArrayType = require("ref-array-di")(ref);

const CString = ref.types.CString;
const CStringArray = ArrayType(CString);

const dataCbType = ffi.Function("void", ["int", "string", "int"]);
const exitCbType = ffi.Function("void", ["int", "int"]);
const errCbType  = ffi.Function("void", ["int", "int", "string"]);

const lib = ffi.Library("DelphiPty", {
  Pty_Init:        ["int", []],
  Pty_Create:      ["int", ["string", CStringArray, "int", "string", CStringArray, "int", "int", "pointer", "pointer", "pointer"]],
  Pty_Write:       ["int", ["int", "string", "int"]],
  Pty_Resize:      ["int", ["int", "int", "int"]],
  Pty_Close:       ["int", ["int"]],
  Pty_Kill:        ["int", ["int"]],
  Pty_IsAlive:     ["int", ["int"]],
  Pty_GetExitCode: ["int", ["int", "pointer"]]
});

module.exports = {
  lib,
  types: {
    dataCbType,
    exitCbType,
    errCbType,
    CStringArray
  }
};