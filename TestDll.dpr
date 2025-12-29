program TestDll;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes;

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
  Writeln('[PTY OUTPUT]: ', S);
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
begin
  Writeln('Testing Pty_Init...');
  if Pty_Init <> 0 then
  begin
    Writeln('Pty_Init failed. ConPTY likely unsupported.');
    Exit;
  end;

  Writeln('Creating PTY (cmd /c echo Hello)...');
  Cmd := 'cmd /c echo Hello from ConPTY!';
  Handle := Pty_Create(PAnsiChar(Cmd), nil, 0, nil, nil, 80, 25, @OnData, @OnExit, @OnError);
  
  if Handle <= 0 then
  begin
    Writeln('Pty_Create failed: ', Handle);
    Exit;
  end;

  Writeln('PTY Created. Handle: ', Handle);
  
  Sleep(500);
  Writeln('Sending "dir"...');
  Cmd := 'dir'#13#10;
  Pty_Write(Handle, PAnsiChar(Cmd), Length(Cmd));

  Sleep(1000);
  Writeln('Resizing to 100x30...');
  Pty_Resize(Handle, 100, 30);

  Sleep(500);
  Writeln('Sending "exit"...');
  Cmd := 'exit'#13#10;
  Pty_Write(Handle, PAnsiChar(Cmd), Length(Cmd));

  // Wait for finish or timeout
  Writeln('Waiting for exit...');
  while not GFinished do
  begin
    Sleep(100);
  end;

  Writeln('Test finished. Exit Code: ', GExitCode);
end;

begin
  try
    RunTest;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
  Writeln('Press Enter to exit.');
  Readln;
end.
