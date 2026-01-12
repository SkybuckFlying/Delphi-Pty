program TestDll;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.DateUtils;

type
  PTY_HANDLE = Integer;

  TPtyDataCallback  = procedure(handle: PTY_HANDLE; data: PAnsiChar; len: Integer); stdcall;
  TPtyExitCallback  = procedure(handle: PTY_HANDLE; exitCode: Integer); stdcall;
  TPtyErrorCallback = procedure(handle: PTY_HANDLE; errorCode: Integer; msg: PAnsiChar); stdcall;

// --- DLL Imports ---
function Pty_Init: Integer; stdcall; external 'DelphiPty.dll';

{ CRITICAL FIX: Added 'out outPid: Integer' to match new PtyCore.pas signature }
function Pty_Create(
  command: PAnsiChar;
  args: PPAnsiChar;
  argCount: Integer;
  cwd: PAnsiChar;
  env: PPAnsiChar;
  cols, rows: Integer;
  onData: TPtyDataCallback;
  onExit: TPtyExitCallback;
  onError: TPtyErrorCallback;
  out outPid: Integer
): PTY_HANDLE; stdcall; external 'DelphiPty.dll';

function Pty_Write(handle: PTY_HANDLE; data: PAnsiChar; len: Integer): Integer; stdcall; external 'DelphiPty.dll';
function Pty_Resize(handle: PTY_HANDLE; cols, rows: Integer): Integer; stdcall; external 'DelphiPty.dll';
function Pty_Close(handle: PTY_HANDLE): Integer; stdcall; external 'DelphiPty.dll';
function Pty_Kill(handle: PTY_HANDLE): Integer; stdcall; external 'DelphiPty.dll';
function Pty_IsAlive(handle: PTY_HANDLE): Integer; stdcall; external 'DelphiPty.dll';
function Pty_GetExitCode(handle: PTY_HANDLE; outExitCode: PInteger): Integer; stdcall; external 'DelphiPty.dll';

var
  GExitCode: Integer = -1;
  GFinished: Boolean = False;

// --- Callback Implementations ---

procedure OnData(handle: PTY_HANDLE; data: PAnsiChar; len: Integer); stdcall;
var
  S: RawByteString;
begin
  SetLength(S, len);
  Move(data^, S[1], len);
  Write(string(S));
end;

procedure OnExit(handle: PTY_HANDLE; exitCode: Integer); stdcall;
begin
  Writeln(Format(#10'[DLL EXIT] Handle: %d, Code: %d', [handle, exitCode]));
  GExitCode := exitCode;
  GFinished := True;
end;

procedure OnError(handle: PTY_HANDLE; errorCode: Integer; msg: PAnsiChar); stdcall;
begin
  Writeln(Format(#10'[DLL ERROR] Handle: %d, Code: %d, Msg: %s', [handle, errorCode, string(msg)]));
end;

procedure RunTest;
var
  Handle: PTY_HANDLE;
  Pid: Integer; // Added to capture PID
  Cmd: AnsiString;
  hOut: THandle;
  csbi: TConsoleScreenBufferInfo;
  Cols, Rows: Integer;
  StartTime: TDateTime;
begin
  if Pty_Init <> 0 then
  begin
    Writeln('Pty_Init failed. ConPTY likely unsupported on this OS.');
    Exit;
  end;

  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  if not GetConsoleScreenBufferInfo(hOut, csbi) then
  begin
    Cols := 80; Rows := 25;
  end
  else
  begin
    Cols := csbi.srWindow.Right - csbi.srWindow.Left + 1;
    Rows := csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
  end;

  Writeln(Format('Creating PTY (%dx%d)...', [Cols, Rows]));

  Cmd := 'cmd.exe';
  { Updated call with Pid parameter }
  Handle := Pty_Create(PAnsiChar(Cmd), nil, 0, nil, nil, Cols, Rows, OnData, OnExit, OnError, Pid);

  if Handle <= 0 then
  begin
    Writeln('Pty_Create failed with error handle: ', Handle);
    Exit;
  end;

  Writeln(Format('PTY Created. Handle: %d, Process ID: %d', [Handle, Pid]));
  Writeln('Wait 1s for prompt...');
  Sleep(1000);

  Writeln(#10'Sending "dir" command...');
  Cmd := 'dir'#13#10;
  Pty_Write(Handle, PAnsiChar(Cmd), Length(Cmd));
  Sleep(2000);

  Writeln(#10'Closing gracefully via "exit"...');
  Cmd := 'exit'#13#10;
  Pty_Write(Handle, PAnsiChar(Cmd), Length(Cmd));

  StartTime := Now;
  while not GFinished do
  begin
    CheckSynchronize(10);
    Sleep(90);

    if SecondSpan(Now, StartTime) > 5 then
    begin
      Writeln(#10'Timeout reached. Forcing Kill...');
      Pty_Kill(Handle);
      Break;
    end;
  end;

  Writeln('Test finished. Process Exit Code: ', GExitCode);
end;

begin
  // Enable VT Processing in the host console so "dir" colors/formatting look right
  var hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  var dwMode: DWORD;
  if GetConsoleMode(hOut, dwMode) then
    SetConsoleMode(hOut, dwMode or $0004); // ENABLE_VIRTUAL_TERMINAL_PROCESSING

  try
    RunTest;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;

  Writeln(#10'Press Enter to exit.');
  Readln;
end.
