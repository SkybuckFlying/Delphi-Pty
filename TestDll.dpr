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

function Pty_Init: Integer; stdcall; external 'DelphiPty.dll';
function Pty_Create(
  command: PAnsiChar;
  args: PPAnsiChar;
  argCount: Integer;
  cwd: PAnsiChar;
  env: PPAnsiChar;
  cols: Integer;
  rows: Integer;
  onData: TPtyDataCallback;
  onExit: TPtyExitCallback;
  onError: TPtyErrorCallback
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

procedure OnData(handle: PTY_HANDLE; data: PAnsiChar; len: Integer); stdcall;
var
  S: string;
begin
  SetString(S, data, len);
  Write(S);
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
  Cmd: AnsiString;
  hOut: THandle;
  csbi: TConsoleScreenBufferInfo;
  Cols, Rows: Integer;
begin
  if Pty_Init <> 0 then
  begin
    Writeln('Pty_Init failed. ConPTY likely unsupported.');
    Exit;
  end;

  // Query current host console size
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  if not GetConsoleScreenBufferInfo(hOut, csbi) then
  begin
    Cols := 80;
    Rows := 25;
  end
  else
  begin
    Cols := csbi.srWindow.Right - csbi.srWindow.Left + 1;
    Rows := csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
  end;

  Writeln(Format('Creating PTY to match host size: %dx%d...', [Cols, Rows]));
  Handle := Pty_Create('cmd.exe', nil, 0, nil, nil, Cols, Rows, @OnData, @OnExit, @OnError);
  
  if Handle <= 0 then
  begin
    Writeln('Pty_Create failed: ', Handle);
    Exit;
  end;

  Writeln('PTY Created. Handle: ', Handle);
  
  Writeln(#10'Wait 2s for prompt...');
  Sleep(2000);

  Writeln(#10'Checking console mode (should match host size)...');
  Cmd := 'mode con'#13#10;
  Pty_Write(Handle, PAnsiChar(Cmd), Length(Cmd));
  Sleep(2000);

  Writeln(#10'Closing gracefully (sending exit)...');
  Cmd := 'exit'#13#10;
  Pty_Write(Handle, PAnsiChar(Cmd), Length(Cmd));
  
  // Wait for finish or timeout
  Writeln('Waiting for exit...');
  var StartTime: TDateTime;
  StartTime := Now;
  while not GFinished do
  begin
    Sleep(100);
    if SecondSpan(Now, StartTime) > 5 then
    begin
      Writeln('Timeout, killing (this causes negative STATUS_CONTROL_C_EXIT)...');
      Pty_Kill(Handle);
      Break;
    end;
  end;

  Writeln('Test finished. Exit Code: ', GExitCode);
end;

var
  hOut: THandle;
  dwMode: DWORD;
begin
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  if GetConsoleMode(hOut, dwMode) then
    SetConsoleMode(hOut, dwMode or $0004); // ENABLE_VIRTUAL_TERMINAL_PROCESSING

  try
    RunTest;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
  Writeln('Press Enter to exit.');
  Readln;
end.
