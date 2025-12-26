#include <napi.h>
#include <windows.h>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>

using namespace Napi;

// Types uit Delphi
typedef int PTY_HANDLE;

typedef void (__stdcall *TPtyDataCallback)(PTY_HANDLE, const char*, int);
typedef void (__stdcall *TPtyExitCallback)(PTY_HANDLE, int);
typedef void (__stdcall *TPtyErrorCallback)(PTY_HANDLE, int, const char*);

// Function pointer types
typedef int (__stdcall *FPty_Init)();
typedef int (__stdcall *FPty_Create)(
  const char* command,
  const char** args,
  int argCount,
  const char* cwd,
  const char** env,
  int cols,
  int rows,
  TPtyDataCallback onData,
  TPtyExitCallback onExit,
  TPtyErrorCallback onError
);
typedef int (__stdcall *FPty_Write)(PTY_HANDLE, const char*, int);
typedef int (__stdcall *FPty_Resize)(PTY_HANDLE, int, int);
typedef int (__stdcall *FPty_Close)(PTY_HANDLE);
typedef int (__stdcall *FPty_Kill)(PTY_HANDLE);
typedef int (__stdcall *FPty_IsAlive)(PTY_HANDLE);
typedef int (__stdcall *FPty_GetExitCode)(PTY_HANDLE, int*);

// Globals
static HMODULE hDelphi = nullptr;
static FPty_Init        g_Pty_Init        = nullptr;
static FPty_Create      g_Pty_Create      = nullptr;
static FPty_Write       g_Pty_Write       = nullptr;
static FPty_Resize      g_Pty_Resize      = nullptr;
static FPty_Close       g_Pty_Close       = nullptr;
static FPty_Kill        g_Pty_Kill        = nullptr;
static FPty_IsAlive     g_Pty_IsAlive     = nullptr;
static FPty_GetExitCode g_Pty_GetExitCode = nullptr;

// Callback beheer
struct PtyCallbacks {
  ThreadSafeFunction onData;
  ThreadSafeFunction onExit;
  ThreadSafeFunction onError;
};

static std::map<PTY_HANDLE, PtyCallbacks> g_callbacks;
static std::mutex g_cbMutex;

// --------- DLL laden en exports resolven ----------

void LoadDelphiPty() {
  if (hDelphi) return;

  hDelphi = LoadLibraryA("DelphiPty.dll");
  if (!hDelphi) {
    throw std::runtime_error("Could not load DelphiPty.dll");
  }

  auto load = [&](auto& fp, const char* name) {
    fp = reinterpret_cast<std::decay_t<decltype(fp)>>(
      GetProcAddress(hDelphi, name)
    );
    if (!fp) {
      throw std::runtime_error(std::string("Missing export: ") + name);
    }
  };

  load(g_Pty_Init,        "Pty_Init");
  load(g_Pty_Create,      "Pty_Create");
  load(g_Pty_Write,       "Pty_Write");
  load(g_Pty_Resize,      "Pty_Resize");
  load(g_Pty_Close,       "Pty_Close");
  load(g_Pty_Kill,        "Pty_Kill");
  load(g_Pty_IsAlive,     "Pty_IsAlive");
  load(g_Pty_GetExitCode, "Pty_GetExitCode");

  int rc = g_Pty_Init();
  if (rc < 0) {
    throw std::runtime_error("Pty_Init failed with code " + std::to_string(rc));
  }
}

// --------- Helpers: JS -> C ---------

std::vector<std::string> JsArrayToStringVector(const Array& arr) {
  std::vector<std::string> out;
  out.reserve(arr.Length());
  for (uint32_t i = 0; i < arr.Length(); ++i) {
    out.push_back(arr.Get(i).ToString().Utf8Value());
  }
  return out;
}

std::vector<const char*> BuildCStringArray(const std::vector<std::string>& vec) {
  std::vector<const char*> out;
  out.reserve(vec.size());
  for (auto& s : vec) {
    out.push_back(s.c_str());
  }
  return out;
}

// --------- C callbacks <- Delphi roept deze aan ---------

void __stdcall DataCallback(PTY_HANDLE handle, const char* data, int len) {
  std::lock_guard<std::mutex> lock(g_cbMutex);
  auto it = g_callbacks.find(handle);
  if (it == g_callbacks.end()) return;

  auto tsfn = it->second.onData;
  if (!tsfn) return;

  std::string chunk(data, len);

  tsfn.BlockingCall(
    new std::string(std::move(chunk)),
    [](Napi::Env env, Function jsCallback, std::string* str) {
      jsCallback.Call({ String::New(env, *str) });
      delete str;
    }
  );
}

void __stdcall ExitCallback(PTY_HANDLE handle, int exitCode) {
  std::lock_guard<std::mutex> lock(g_cbMutex);
  auto it = g_callbacks.find(handle);
  if (it == g_callbacks.end()) return;

  auto tsfn = it->second.onExit;
  if (!tsfn) return;

  tsfn.BlockingCall(
    new int(exitCode),
    [](Napi::Env env, Function jsCallback, int* code) {
      jsCallback.Call({ Number::New(env, *code) });
      delete code;
    }
  );
}

void __stdcall ErrorCallback(PTY_HANDLE handle, int errCode, const char* msg) {
  std::lock_guard<std::mutex> lock(g_cbMutex);
  auto it = g_callbacks.find(handle);
  if (it == g_callbacks.end()) {
    if (msg) fprintf(stderr, "[Native Error] Handle %d: %s (Code: %d)\n", handle, msg, errCode);
    return;
  }

  auto tsfn = it->second.onError;
  if (!tsfn) return;

  auto payload = new std::pair<int, std::string>(errCode, msg ? msg : "");

  tsfn.BlockingCall(
    payload,
    [](Napi::Env env, Function jsCallback, std::pair<int, std::string>* p) {
      jsCallback.Call({
        Number::New(env, p->first),
        String::New(env, p->second)
      });
      delete p;
    }
  );
}

// --------- N-API functies ---------

Value CreatePty(const CallbackInfo& info) {
  Env env = info.Env();
  LoadDelphiPty();

  if (info.Length() < 1 || !info[0].IsObject()) {
    throw TypeError::New(env, "Options object required");
  }

  Object opts = info[0].As<Object>();

  std::string command = opts.Get("command").ToString().Utf8Value();
  Array argsArr = opts.Has("args") ? opts.Get("args").As<Array>() : Array::New(env);
  std::string cwd = opts.Has("cwd")
    ? opts.Get("cwd").ToString().Utf8Value()
    : std::string("");

  Object envObj = opts.Has("env") ? opts.Get("env").As<Object>() : Object::New(env);
  int cols = opts.Has("cols") ? opts.Get("cols").ToNumber().Int32Value() : 80;
  int rows = opts.Has("rows") ? opts.Get("rows").ToNumber().Int32Value() : 25;

  Function onData = opts.Get("onData").As<Function>();
  Function onExit = opts.Get("onExit").As<Function>();
  Function onError = opts.Get("onError").As<Function>();

  auto argVec = JsArrayToStringVector(argsArr);
  auto argC = BuildCStringArray(argVec);

  std::vector<std::string> envPairs;
  std::vector<const char*> envC;
  {
    Array keys = envObj.GetPropertyNames();
    envPairs.reserve(keys.Length());
    for (uint32_t i = 0; i < keys.Length(); ++i) {
      std::string k = keys.Get(i).ToString().Utf8Value();
      std::string v = envObj.Get(k).ToString().Utf8Value();
      envPairs.push_back(k + "=" + v);
    }
    std::sort(envPairs.begin(), envPairs.end());
    envC = BuildCStringArray(envPairs);
    envC.push_back(nullptr); // Null-terminate for Delphi
  }

  auto tsOnData = ThreadSafeFunction::New(env, onData, "onData", 0, 1);
  auto tsOnExit = ThreadSafeFunction::New(env, onExit, "onExit", 0, 1);
  auto tsOnError = ThreadSafeFunction::New(env, onError, "onError", 0, 1);

  PTY_HANDLE handle = g_Pty_Create(
    command.c_str(),
    argC.empty() ? nullptr : argC.data(),
    static_cast<int>(argC.size()),
    cwd.empty() ? nullptr : cwd.c_str(),
    envC.empty() ? nullptr : envC.data(),
    cols,
    rows,
    DataCallback,
    ExitCallback,
    ErrorCallback
  );

  if (handle <= 0) {
    tsOnData.Release();
    tsOnExit.Release();
    tsOnError.Release();
    throw Error::New(env, "Pty_Create failed with code " + std::to_string(handle));
  }

  {
    std::lock_guard<std::mutex> lock(g_cbMutex);
    g_callbacks[handle] = { tsOnData, tsOnExit, tsOnError };
  }

  return Number::New(env, handle);
}

Value Write(const CallbackInfo& info) {
  Env env = info.Env();
  if (info.Length() < 2) {
    throw TypeError::New(env, "handle, data required");
  }
  PTY_HANDLE handle = info[0].ToNumber().Int32Value();
  std::string data = info[1].ToString().Utf8Value();

  int rc = g_Pty_Write(handle, data.c_str(), (int)data.size());
  return Number::New(env, rc);
}

Value Resize(const CallbackInfo& info) {
  Env env = info.Env();
  PTY_HANDLE handle = info[0].ToNumber().Int32Value();
  int cols = info[1].ToNumber().Int32Value();
  int rows = info[2].ToNumber().Int32Value();
  int rc = g_Pty_Resize(handle, cols, rows);
  return Number::New(env, rc);
}

Value Close(const CallbackInfo& info) {
  Env env = info.Env();
  PTY_HANDLE handle = info[0].ToNumber().Int32Value();

  {
    std::lock_guard<std::mutex> lock(g_cbMutex);
    auto it = g_callbacks.find(handle);
    if (it != g_callbacks.end()) {
      it->second.onData.Release();
      it->second.onExit.Release();
      it->second.onError.Release();
      g_callbacks.erase(it);
    }
  }

  int rc = g_Pty_Close(handle);
  return Number::New(env, rc);
}

Value Kill(const CallbackInfo& info) {
  Env env = info.Env();
  PTY_HANDLE handle = info[0].ToNumber().Int32Value();
  int rc = g_Pty_Kill(handle);
  return Number::New(env, rc);
}

Value IsAlive(const CallbackInfo& info) {
  Env env = info.Env();
  PTY_HANDLE handle = info[0].ToNumber().Int32Value();
  int v = g_Pty_IsAlive(handle);
  return Boolean::New(env, v == 1);
}

Value GetExitCode(const CallbackInfo& info) {
  Env env = info.Env();
  PTY_HANDLE handle = info[0].ToNumber().Int32Value();
  int code = 0;
  int rc = g_Pty_GetExitCode(handle, &code);
  if (rc < 0) {
    return env.Null();
  }
  return Number::New(env, code);
}

// Module init
Object InitAll(Env env, Object exports) {
  exports.Set("createPtyNative", Function::New(env, CreatePty));
  exports.Set("write",           Function::New(env, Write));
  exports.Set("resize",          Function::New(env, Resize));
  exports.Set("close",           Function::New(env, Close));
  exports.Set("kill",            Function::New(env, Kill));
  exports.Set("isAlive",         Function::New(env, IsAlive));
  exports.Set("getExitCode",     Function::New(env, GetExitCode));
  return exports;
}

NODE_API_MODULE(delphi_pty, InitAll)