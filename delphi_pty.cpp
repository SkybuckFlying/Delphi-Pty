#include <napi.h>
#include <windows.h>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <atomic>

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
    TPtyDataCallback onData, TPtyExitCallback onExit, TPtyErrorCallback onError,
    int* outPid // Added PID support
);
typedef int (__stdcall *FPty_Write)(PTY_HANDLE, const char*, int);
typedef int (__stdcall *FPty_Resize)(PTY_HANDLE, int, int);
typedef int (__stdcall *FPty_Close)(PTY_HANDLE);
typedef int (__stdcall *FPty_Kill)(PTY_HANDLE);
typedef int (__stdcall *FPty_IsAlive)(PTY_HANDLE);
typedef int (__stdcall *FPty_GetExitCode)(PTY_HANDLE, int*);

// --- Globals ---
static HMODULE hDelphi = nullptr;
static FPty_Init       g_Pty_Init        = nullptr;
static FPty_Create     g_Pty_Create      = nullptr;
static FPty_Write       g_Pty_Write       = nullptr;
static FPty_Resize      g_Pty_Resize      = nullptr;
static FPty_Close       g_Pty_Close       = nullptr;
static FPty_Kill        g_Pty_Kill        = nullptr;
static FPty_IsAlive     g_Pty_IsAlive     = nullptr;
static FPty_GetExitCode g_Pty_GetExitCode = nullptr;

// --- Callback Container ---
struct PtyCallbacks {
    ThreadSafeFunction onData;
    ThreadSafeFunction onExit;
    ThreadSafeFunction onError;
    std::atomic<bool> alive;

    PtyCallbacks(ThreadSafeFunction d, ThreadSafeFunction ex, ThreadSafeFunction err)
        : onData(d), onExit(ex), onError(err), alive(true) {}

    PtyCallbacks(PtyCallbacks&& other) noexcept
        : onData(std::move(other.onData)),
          onExit(std::move(other.onExit)),
          onError(std::move(other.onError)),
          alive(other.alive.load()) {}
};

static std::map<PTY_HANDLE, PtyCallbacks> g_callbacks;
static std::mutex g_cbMutex;

// --- Internal Helper: Load DLL ---
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

// --- Callbacks ---

void __stdcall DataCallback(PTY_HANDLE handle, const char* data, int len) {
    std::lock_guard<std::mutex> lock(g_cbMutex);
    auto it = g_callbacks.find(handle);
    if (it == g_callbacks.end() || !it->second.alive.load()) return;

    auto blob = new std::vector<char>(data, data + len);
    it->second.onData.BlockingCall(blob, [](Napi::Env env, Function jsCallback, std::vector<char>* vec) {
        jsCallback.Call({ Buffer<char>::Copy(env, vec->data(), vec->size()) });
        delete vec;
    });
}

void __stdcall ExitCallback(PTY_HANDLE handle, int exitCode) {
    ThreadSafeFunction tsExit, tsData, tsError;
    {
        std::lock_guard<std::mutex> lock(g_cbMutex);
        auto it = g_callbacks.find(handle);
        if (it == g_callbacks.end()) return;

        tsExit = it->second.onExit;
        tsData = it->second.onData;
        tsError = it->second.onError;
        g_callbacks.erase(it);
    }

    if (tsExit) {
        tsExit.BlockingCall(new int(exitCode), [](Napi::Env env, Function jsCallback, int* code) {
            jsCallback.Call({ Number::New(env, *code) });
            delete code;
        });
        tsExit.Release();
        if (tsData) tsData.Release();
        if (tsError) tsError.Release();
    }
}

void __stdcall ErrorCallback(PTY_HANDLE handle, int errCode, const char* msg) {
    std::lock_guard<std::mutex> lock(g_cbMutex);
    auto it = g_callbacks.find(handle);
    if (it == g_callbacks.end() || !it->second.alive.load()) return;

    auto payload = new std::pair<int, std::string>(errCode, msg ? msg : "");
    it->second.onError.BlockingCall(payload, [](Napi::Env env, Function jsCallback, std::pair<int, std::string>* p) {
        jsCallback.Call({ Number::New(env, p->first), String::New(env, p->second) });
        delete p;
    });
}

// --- JS Native Interface ---

Value CreatePty(const CallbackInfo& info) {
    Env env = info.Env();
    LoadDelphiPty();
    Object opts = info[0].As<Object>();

    std::string command = opts.Get("command").ToString().Utf8Value();
    int cols = opts.Has("cols") ? opts.Get("cols").ToNumber().Int32Value() : 80;
    int rows = opts.Has("rows") ? opts.Get("rows").ToNumber().Int32Value() : 25;

    auto tsOnData = ThreadSafeFunction::New(env, opts.Get("onData").As<Function>(), "onData", 0, 1);
    auto tsOnExit = ThreadSafeFunction::New(env, opts.Get("onExit").As<Function>(), "onExit", 0, 1);
    auto tsOnError = ThreadSafeFunction::New(env, opts.Get("onError").As<Function>(), "onError", 0, 1);

    tsOnData.Unref(env);
    tsOnError.Unref(env);

    int pid = 0;
    PTY_HANDLE handle = g_Pty_Create(
        command.c_str(), nullptr, 0, nullptr, nullptr,
        cols, rows, DataCallback, ExitCallback, ErrorCallback, &pid
    );

    if (handle <= 0) {
        tsOnData.Release(); tsOnExit.Release(); tsOnError.Release();
        throw Error::New(env, "Pty_Create failed");
    }

    {
        std::lock_guard<std::mutex> lock(g_cbMutex);
        g_callbacks.emplace(handle, PtyCallbacks(tsOnData, tsOnExit, tsOnError));
    }

    Object res = Object::New(env);
    res.Set("handle", Number::New(env, handle));
    res.Set("pid", Number::New(env, pid));
    return res;
}

Value Write(const CallbackInfo& info) {
    PTY_HANDLE handle = info[0].ToNumber().Int32Value();
    Buffer<char> buf = info[1].As<Buffer<char>>();
    int rc = g_Pty_Write(handle, buf.Data(), static_cast<int>(buf.Length()));
    return Number::New(info.Env(), rc);
}

Value Resize(const CallbackInfo& info) {
    PTY_HANDLE handle = info[0].ToNumber().Int32Value();
    int cols = info[1].ToNumber().Int32Value();
    int rows = info[2].ToNumber().Int32Value();
    int rc = g_Pty_Resize(handle, cols, rows);
    return Number::New(info.Env(), rc);
}

Value Close(const CallbackInfo& info) {
    PTY_HANDLE h = info[0].ToNumber().Int32Value();
    {
        std::lock_guard<std::mutex> lock(g_cbMutex);
        auto it = g_callbacks.find(h);
        if (it != g_callbacks.end()) it->second.alive.store(false);
    }
    int rc = g_Pty_Close(h);
    return Number::New(info.Env(), rc);
}

Value Kill(const CallbackInfo& info) {
    return Number::New(info.Env(), g_Pty_Kill(info[0].ToNumber().Int32Value()));
}

Value IsAlive(const CallbackInfo& info) {
    return Boolean::New(info.Env(), g_Pty_IsAlive(info[0].ToNumber().Int32Value()) == 1);
}

Object InitAll(Env env, Object exports) {
    exports.Set("createPtyNative", Function::New(env, CreatePty));
    exports.Set("write", Function::New(env, Write));
    exports.Set("resize", Function::New(env, Resize));
    exports.Set("close", Function::New(env, Close));
    exports.Set("kill", Function::New(env, Kill));
    exports.Set("isAlive", Function::New(env, IsAlive));
    return exports;
}

NODE_API_MODULE(delphi_pty, InitAll)