#include <napi.h>
#include <windows.h>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>

using namespace Napi;

typedef int PTY_HANDLE;

// --- Delphi Export Prototypes ---
typedef void (__stdcall *TPtyDataCallback)(PTY_HANDLE, const char*, int);
typedef void (__stdcall *TPtyExitCallback)(PTY_HANDLE, int);
typedef void (__stdcall *TPtyErrorCallback)(PTY_HANDLE, int, const char*);

typedef int (__stdcall *FPty_Init)();
typedef int (__stdcall *FPty_Create)(
  const char* command, const char** args, int argCount,
  const char* cwd, const char** env, int cols, int rows,
  TPtyDataCallback onData, TPtyExitCallback onExit, TPtyErrorCallback onError
);
typedef int (__stdcall *FPty_Write)(PTY_HANDLE, const char*, int);
typedef int (__stdcall *FPty_Resize)(PTY_HANDLE, int, int);
typedef int (__stdcall *FPty_Close)(PTY_HANDLE);
typedef int (__stdcall *FPty_Kill)(PTY_HANDLE);
typedef int (__stdcall *FPty_IsAlive)(PTY_HANDLE);
typedef int (__stdcall *FPty_GetExitCode)(PTY_HANDLE, int*);

// --- Globals ---
static HMODULE hDelphi = nullptr;
static FPty_Init        g_Pty_Init        = nullptr;
static FPty_Create      g_Pty_Create      = nullptr;
static FPty_Write       g_Pty_Write       = nullptr;
static FPty_Resize      g_Pty_Resize      = nullptr;
static FPty_Close       g_Pty_Close       = nullptr;
static FPty_Kill        g_Pty_Kill        = nullptr;
static FPty_IsAlive     g_Pty_IsAlive     = nullptr;
static FPty_GetExitCode g_Pty_GetExitCode = nullptr;

struct PtyCallbacks {
  ThreadSafeFunction onData;
  ThreadSafeFunction onExit;
  ThreadSafeFunction onError;
};

static std::map<PTY_HANDLE, PtyCallbacks> g_callbacks;
static std::mutex g_cbMutex;

// --- Helpers ---
bool IsUint8Array(const Napi::Value& v) {
    return v.IsTypedArray() && v.As<Napi::TypedArray>().TypedArrayType() == napi_uint8_array;
}

void LoadDelphiPty() {
  if (hDelphi) return;
  hDelphi = LoadLibraryA("DelphiPty.dll");
  if (!hDelphi) throw std::runtime_error("Could not load DelphiPty.dll");

  auto load = [&](auto& fp, const char* name) {
    fp = reinterpret_cast<std::decay_t<decltype(fp)>>(GetProcAddress(hDelphi, name));
    if (!fp) throw std::runtime_error(std::string("Missing export: ") + name);
  };

  load(g_Pty_Init, "Pty_Init");
  load(g_Pty_Create, "Pty_Create");
  load(g_Pty_Write, "Pty_Write");
  load(g_Pty_Resize, "Pty_Resize");
  load(g_Pty_Close, "Pty_Close");
  load(g_Pty_Kill, "Pty_Kill");
  load(g_Pty_IsAlive, "Pty_IsAlive");
  load(g_Pty_GetExitCode, "Pty_GetExitCode");

  if (g_Pty_Init() < 0) throw std::runtime_error("Pty_Init failed");
}

// --- Callbacks (Delphi -> C++ -> JS) ---

void __stdcall DataCallback(PTY_HANDLE handle, const char* data, int len) {
  std::lock_guard<std::mutex> lock(g_cbMutex);
  auto it = g_callbacks.find(handle);
  if (it == g_callbacks.end() || !it->second.onData) return;

  auto blob = new std::vector<char>(data, data + len);
  it->second.onData.BlockingCall(blob, [](Napi::Env env, Function jsCallback, std::vector<char>* vec) {
    jsCallback.Call({ Buffer<char>::Copy(env, vec->data(), vec->size()) });
    delete vec;
  });
}

void __stdcall ExitCallback(PTY_HANDLE handle, int exitCode) {
  std::lock_guard<std::mutex> lock(g_cbMutex);
  auto it = g_callbacks.find(handle);
  if (it == g_callbacks.end()) return;

  if (it->second.onExit) {
    it->second.onExit.BlockingCall(new int(exitCode), [](Napi::Env env, Function jsCallback, int* code) {
      jsCallback.Call({ Number::New(env, *code) });
      delete code;
    });
  }

  it->second.onData.Release();
  it->second.onExit.Release();
  it->second.onError.Release();
  g_callbacks.erase(it);
} // <--- Fixed the brace here (no more "end;")

void __stdcall ErrorCallback(PTY_HANDLE handle, int errCode, const char* msg) {
  std::lock_guard<std::mutex> lock(g_cbMutex);
  auto it = g_callbacks.find(handle);
  if (it == g_callbacks.end() || !it->second.onError) return;

  auto payload = new std::pair<int, std::string>(errCode, msg ? msg : "");
  it->second.onError.BlockingCall(payload, [](Napi::Env env, Function jsCallback, std::pair<int, std::string>* p) {
    jsCallback.Call({ Number::New(env, p->first), String::New(env, p->second) });
    delete p;
  });
}

// --- JS Exports ---

Value CreatePty(const CallbackInfo& info) {
  Env env = info.Env();
  LoadDelphiPty();
  Object opts = info[0].As<Object>();

  std::string command = opts.Get("command").ToString().Utf8Value();
  std::string cwd = opts.Has("cwd") ? opts.Get("cwd").ToString().Utf8Value() : "";
  int cols = opts.Has("cols") ? opts.Get("cols").ToNumber().Int32Value() : 80;
  int rows = opts.Has("rows") ? opts.Get("rows").ToNumber().Int32Value() : 25;

  std::vector<std::string> argVec;
  if (opts.Has("args")) {
    Array arr = opts.Get("args").As<Array>();
    for (uint32_t i = 0; i < arr.Length(); ++i) argVec.push_back(arr.Get(i).ToString().Utf8Value());
  }
  std::vector<const char*> argC;
  for (const auto& s : argVec) argC.push_back(s.c_str());

  std::vector<std::string> envPairs;
  if (opts.Has("env")) {
    Object envObj = opts.Get("env").As<Object>();
    Array keys = envObj.GetPropertyNames();
    for (uint32_t i = 0; i < keys.Length(); ++i) {
      std::string k = keys.Get(i).ToString().Utf8Value();
      envPairs.push_back(k + "=" + envObj.Get(k).ToString().Utf8Value());
    }
    std::sort(envPairs.begin(), envPairs.end());
  }
  std::vector<const char*> envC;
  for (const auto& s : envPairs) envC.push_back(s.c_str());
  envC.push_back(nullptr);

  auto tsOnData = ThreadSafeFunction::New(env, opts.Get("onData").As<Function>(), "onData", 0, 1);
  auto tsOnExit = ThreadSafeFunction::New(env, opts.Get("onExit").As<Function>(), "onExit", 0, 1);
  auto tsOnError = ThreadSafeFunction::New(env, opts.Get("onError").As<Function>(), "onError", 0, 1);

  // UNREF these to allow Node to exit cleanly
  tsOnData.Unref(env);
  tsOnExit.Unref(env);
  tsOnError.Unref(env);

  PTY_HANDLE handle = g_Pty_Create(
    command.c_str(), argC.data(), (int)argC.size(),
    cwd.empty() ? nullptr : cwd.c_str(), envC.data(),
    cols, rows, DataCallback, ExitCallback, ErrorCallback
  );

  if (handle <= 0) {
    tsOnData.Release(); tsOnExit.Release(); tsOnError.Release();
    throw Error::New(env, "Pty_Create failed");
  }

  std::lock_guard<std::mutex> lock(g_cbMutex);
  g_callbacks[handle] = { tsOnData, tsOnExit, tsOnError };
  return Number::New(env, handle);
}

Value Write(const CallbackInfo& info) {
  Env env = info.Env();
  PTY_HANDLE handle = info[0].ToNumber().Int32Value();
  const char* data = nullptr;
  size_t length = 0;

  if (info[1].IsBuffer()) {
    auto buf = info[1].As<Buffer<char>>();
    data = buf.Data();
    length = buf.Length();
  } else if (IsUint8Array(info[1])) {
    auto buf = info[1].As<Uint8Array>();
    data = reinterpret_cast<const char*>(buf.Data());
    length = buf.ByteLength();
  } else {
    throw TypeError::New(env, "Data must be Buffer or Uint8Array");
  }

  int rc = g_Pty_Write(handle, data, static_cast<int>(length));
  return Number::New(env, rc);
}

Value Resize(const CallbackInfo& info) {
  return Number::New(info.Env(), g_Pty_Resize(info[0].ToNumber().Int32Value(), info[1].ToNumber().Int32Value(), info[2].ToNumber().Int32Value()));
}

Value Close(const CallbackInfo& info) {
  PTY_HANDLE h = info[0].ToNumber().Int32Value();
  std::lock_guard<std::mutex> lock(g_cbMutex);
  auto it = g_callbacks.find(h);
  if (it != g_callbacks.end()) {
    it->second.onData.Release(); it->second.onExit.Release(); it->second.onError.Release();
    g_callbacks.erase(it);
  }
  return Number::New(info.Env(), g_Pty_Close(h));
}

Value Kill(const CallbackInfo& info) {
  return Number::New(info.Env(), g_Pty_Kill(info[0].ToNumber().Int32Value()));
}

Value IsAlive(const CallbackInfo& info) {
  return Boolean::New(info.Env(), g_Pty_IsAlive(info[0].ToNumber().Int32Value()) == 1);
}

Value GetExitCode(const CallbackInfo& info) {
  int code = 0;
  if (g_Pty_GetExitCode(info[0].ToNumber().Int32Value(), &code) < 0) return info.Env().Null();
  return Number::New(info.Env(), code);
}

Object InitAll(Env env, Object exports) {
  exports.Set("createPtyNative", Function::New(env, CreatePty));
  exports.Set("write", Function::New(env, Write));
  exports.Set("resize", Function::New(env, Resize));
  exports.Set("close", Function::New(env, Close));
  exports.Set("kill", Function::New(env, Kill));
  exports.Set("isAlive", Function::New(env, IsAlive));
  exports.Set("getExitCode", Function::New(env, GetExitCode));
  return exports;
}

NODE_API_MODULE(delphi_pty, InitAll)