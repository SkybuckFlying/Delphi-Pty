# Delphi-PTY Backend

A high-performance Windows ConPTY backend implemented in Delphi, exposed to Node.js through a native N-API addon (C++).
This project provides a stable, future-proof alternative to `ffi-napi`, fully compatible with Node.js 22+.

It allows Node.js applications to spawn and control Windows pseudo-terminals (ConPTY) with:

- real-time data streaming
- resize support
- environment variable injection
- working directory control
- exit notifications
- error callbacks
- full UTF-8 support

The backend is implemented in Delphi for maximum performance and reliability, while the Node.js side uses a modern N-API addon to ensure ABI stability across future Node versions.

---

## Features

- Native Windows ConPTY (CreatePseudoConsole / ResizePseudoConsole)
- Delphi DLL backend for stable Windows API interaction
- Node.js N-API addon (C++), no more ffi-napi
- Works on Node.js 18, 20, 22, 23...
- Thread-safe callbacks (data, exit, error)
- Zero-copy streaming from Delphi to Node
- Simple JavaScript API

---

## Project Structure

```
DelphiPty.dll          <- Delphi ConPTY backend
addon.cpp              <- N-API C++ addon (Node.js binding)
binding.gyp            <- node-gyp build config
index.js               <- JS wrapper around the addon
demo.js                <- Example usage
package.json
PtyCore.pas            <- Delphi implementation
DelphiPty.dpr/.dproj   <- Delphi project files
```

---

## Requirements

### Windows
- Windows 10 or 11 (ConPTY API required)

### Delphi
- Delphi 10.3+ (or any version with WinAPI + ConPTY support)

### Node.js
- Node.js 18 or higher
- Fully compatible with Node 22+

### Build Tools
- Visual Studio Build Tools 2022
- Python 3.x
- node-gyp (installed automatically)

---

## Building the Node Addon

Open a terminal in:

```
M:\Delphi-Pty\Branch\Develop\Delphi
```

Then run:

```
npm install
npx node-gyp configure build
```

If successful, you will get:

```
build/Release/delphi_pty.node
```

This is the compiled native addon that Node.js loads.

---

## Full Clean Reinstall (if npm install fails)

Sometimes `npm install` may fail to install dependencies correctly, especially when native modules are involved.
This can happen even if `node_modules` was deleted, because npm also uses `package-lock.json` to decide what is already installed.

If you see errors like:

```
error C1083: Cannot open include file: 'napi.h'
```

then perform a full clean reinstall:

```
rmdir /s /q node_modules
del package-lock.json
npm install
npx node-gyp rebuild
```

### Optional: Clear the global node-gyp cache

If you suspect corrupted Node headers or stale build metadata, you can also remove the global node-gyp cache:

```
rmdir /s /q C:\Users\<YOUR_USERNAME>\AppData\Local\node-gyp
```

Replace `<YOUR_USERNAME>` with your actual Windows user folder name.

Why this may help:

- node-gyp caches downloaded Node headers
- old cached versions may contain incorrect include paths
- clearing the cache forces node-gyp to download fresh headers
- this resolves many mysterious build errors on Windows

Removing both the local folders **and** the global node-gyp cache ensures a completely clean, correct reinstall.

---

## Running the Demo

```
node demo.js
```

You should see:

- ConPTY output from cmd.exe
- Directory listings
- Exit codes
- Real-time streaming

---

## JavaScript Usage

```js
const { createPty } = require('./index');

const pty = createPty({
  command: 'cmd.exe',
  args: [],
  cols: 120,
  rows: 40,
  onData: chunk => process.stdout.write(chunk),
  onExit: code => console.log("Exited:", code),
  onError: (code, msg) => console.error("Error:", code, msg),
});

pty.write("dir\r\n");
```

---

## How It Works

### Delphi Side
- Implements ConPTY using Windows API
- Manages pipes, process creation, callbacks
- Exports a clean C interface via stdcall

### Node Side
- Loads the DLL using LoadLibraryA
- Resolves function pointers
- Wraps everything in N-API functions
- Uses ThreadSafeFunction for async callbacks
- Exposes a simple JS API

This architecture is future-proof because N-API guarantees ABI stability across Node versions.

---

## Why Not ffi-napi?

Because:

- ffi-napi depends on libffi
- libffi breaks on Node 22+
- ffi-napi is no longer actively maintained
- Node 22 introduced a new ABI
- N-API addons remain stable forever

This project removes all those issues.

---

## Roadmap

- Add PowerShell support
- Add UTF-16 passthrough mode
- Add binary mode for raw terminal streams
- Publish as an npm package

---
