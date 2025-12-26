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

Batch files:
BuildAddOn.bat
CleanAddOn.bat
InstallAddOn.bat
BuildDLL.bat
RunDemo.bat
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

## Building the Delphi DLL (DelphiPty.dll)

The backend DLL must be compiled before Node.js can load it.

### Option 1 — Build using Delphi IDE

1. Open `DelphiPty.dproj` in Delphi.
2. Select **Build ? Build All**.
3. The output file will be generated as:

```
DelphiPty.dll
```

Place the DLL next to `demo.js` or in a directory that the addon can load via `LoadLibraryA`.

---

### Option 2 — Build using the batch file

This repository includes:

```
BuildDLL.bat
```

Running it will:

- Invoke the Delphi command-line compiler  
- Build `DelphiPty.dll`  
- Place it in the correct output directory  

Usage:

```
BuildDLL.bat
```

---

## Utility Batch Files

| File                 | Purpose                                               |
|----------------------|-------------------------------------------------------|
| **BuildAddOn.bat**   | Builds the Node.js N-API addon (`delphi_pty.node`)    |
| **CleanAddOn.bat**   | Removes `build/` and other generated addon files      |
| **InstallAddOn.bat** | Runs `npm install` and prepares the addon environment |
| **BuildDLL.bat**     | Compiles the Delphi backend DLL (`DelphiPty.dll`)     |
| **RunDemo.bat**      | Runs the demo (`node demo.js`)                        |

These scripts are optional but help maintain a clean, repeatable workflow.

---

## Using the Native Addon (.node file)

When you build the addon, node-gyp produces:

```
build/Release/delphi_pty.node
```

This is the compiled N-API module that Node.js loads at runtime.

### Where to place the .node file

#### Option 1 — Keep it in build/Release/
If your `index.js` loads it like:

```js
const addon = require('./build/Release/delphi_pty.node');
```

…then nothing else is needed.

#### Option 2 — Copy it next to index.js
If you prefer a flatter structure, copy it manually or run:

```
InstallAddOn.bat
```

Then load it like:

```js
const addon = require('./delphi_pty.node');
```

### Requirements for successful loading

1. `delphi_pty.node` must be in the correct location  
2. `DelphiPty.dll` must be in the same directory or in the system PATH  
3. Node.js architecture must match the DLL (x64 recommended)

If anything is missing, Node will throw:

```
Error: The specified module could not be found.
```

---

## Full Clean Reinstall (if npm install fails)

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

```
rmdir /s /q C:\Users\<YOUR_USERNAME>\AppData\Local\node-gyp
```

This forces node-gyp to download fresh headers.

---

## Running the Demo

```
node demo.js
```

Or simply:

```
RunDemo.bat
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
