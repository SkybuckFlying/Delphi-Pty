program GeminiCliLike;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.StrUtils,
  System.Character;

const
  APP_NAME      = 'Gemini-CLI Simulator';
  VERSION       = '0.1.0';
  PROMPT_NORMAL = 'gemini> ';
  PROMPT_MULTI  = '      ..> ';
  COLOR_RESET   = #27'[0m';
  COLOR_CYAN    = #27'[36m';
  COLOR_GREEN   = #27'[32m';
  COLOR_RED     = #27'[31m';
  COLOR_GRAY    = #27'[90m';

type
  // FIX: PTY_HANDLE must be 8 bytes on 64-bit systems.
  PTY_HANDLE = NativeInt;

  // FIX: Win64 ignores stdcall (uses __fastcall).
  // We keep it for Win32 but remove it for Win64 to ensure stack stability.
  {$IFDEF WIN64}
  TPtyDataCallback = procedure(handle: PTY_HANDLE; data: PAnsiChar; len: Integer);
  TPtyExitCallback = procedure(handle: PTY_HANDLE; exitCode: Integer);
  TPtyErrorCallback = procedure(handle: PTY_HANDLE; errorCode: Integer; msg: PAnsiChar);
  {$ELSE}
  TPtyDataCallback = procedure(handle: PTY_HANDLE; data: PAnsiChar; len: Integer); stdcall;
  TPtyExitCallback = procedure(handle: PTY_HANDLE; exitCode: Integer); stdcall;
  TPtyErrorCallback = procedure(handle: PTY_HANDLE; errorCode: Integer; msg: PAnsiChar); stdcall;
  {$ENDIF}

// External declarations (standardize calling convention)
function Pty_Init: Integer; stdcall; external 'DelphiPty.dll';
function Pty_Create(command: PAnsiChar; args: PPAnsiChar; argCount: Integer;
  cwd: PAnsiChar; env: PPAnsiChar; cols, rows: Integer;
  onData: TPtyDataCallback; onExit: TPtyExitCallback; onError: TPtyErrorCallback;
  out outPid: Integer): PTY_HANDLE; stdcall; external 'DelphiPty.dll';

function Pty_Write(handle: PTY_HANDLE; data: PAnsiChar; len: Integer): Integer; stdcall; external 'DelphiPty.dll';
function Pty_Resize(handle: PTY_HANDLE; cols, rows: Integer): Integer; stdcall; external 'DelphiPty.dll';
function Pty_Close(handle: PTY_HANDLE): Integer; stdcall; external 'DelphiPty.dll';
function Pty_Kill(handle: PTY_HANDLE): Integer; stdcall; external 'DelphiPty.dll';
function Pty_IsAlive(handle: PTY_HANDLE): Integer; stdcall; external 'DelphiPty.dll';

var
  PtyHandle: PTY_HANDLE = 0;
  PtyPid: Integer = 0;
  IsRunning: Boolean = False;
  MultiLineInput: Boolean = False;
  CurrentInput: string = '';
  ScreenCols, ScreenRows: Integer;

// ──────────────────────────────────────────────────────────────────────────────
// Helper functions (Maintained)
// ──────────────────────────────────────────────────────────────────────────────
procedure GetConsoleSize(out cols, rows: Integer);
var
  csbi: TConsoleScreenBufferInfo;
  hOut: THandle;
begin
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  if GetConsoleScreenBufferInfo(hOut, csbi) then
  begin
    cols := csbi.srWindow.Right - csbi.srWindow.Left + 1;
    rows := csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
  end
  else
  begin
    cols := 120;
    rows := 40;
  end;
end;

procedure EnableVirtualTerminal;
var
  hOut: THandle;
  dwMode: DWORD;
begin
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  if GetConsoleMode(hOut, dwMode) then
    SetConsoleMode(hOut, dwMode or $0004); // ENABLE_VIRTUAL_TERMINAL_PROCESSING
end;

// ──────────────────────────────────────────────────────────────────────────────
// Callbacks (Updated for x64 calling convention compatibility)
// ──────────────────────────────────────────────────────────────────────────────
procedure OnPtyData(handle: PTY_HANDLE; data: PAnsiChar; len: Integer); {$IFNDEF WIN64}stdcall;{$ENDIF}
var
  s: RawByteString;
begin
  if len <= 0 then Exit;
  SetLength(s, len);
  Move(data^, s[1], len);
  Write(UTF8ToString(s));
end;

procedure OnPtyExit(handle: PTY_HANDLE; exitCode: Integer); {$IFNDEF WIN64}stdcall;{$ENDIF}
begin
  Writeln;
  Writeln(COLOR_GRAY + '┌─[pty exited with code ' + IntToStr(exitCode) + ']' + COLOR_RESET);
  IsRunning := False;
end;

procedure OnPtyError(handle: PTY_HANDLE; errorCode: Integer; msg: PAnsiChar); {$IFNDEF WIN64}stdcall;{$ENDIF}
begin
  Writeln(COLOR_RED + 'PTY ERROR: ' + IntToStr(errorCode) + ' - ' + string(msg) + COLOR_RESET);
  IsRunning := False;
end;

// ──────────────────────────────────────────────────────────────────────────────
// UI / Interaction (Maintained)
// ──────────────────────────────────────────────────────────────────────────────
procedure ShowWelcome;
begin
  Writeln(COLOR_CYAN, '╔════════════════════════════════════════════════════╗', COLOR_RESET);
  Writeln(COLOR_CYAN, '║ ', APP_NAME, ' v', VERSION, '                       ║', COLOR_RESET);
  Writeln(COLOR_CYAN, '║  Local shell with Gemini-like prompt               ║', COLOR_RESET);
  Writeln(COLOR_CYAN, '║                                                    ║', COLOR_RESET);
  Writeln(COLOR_CYAN, '║  exit / quit / /bye      →  close session          ║', COLOR_RESET);
  Writeln(COLOR_CYAN, '║  clear                   →  clear screen           ║', COLOR_RESET);
  Writeln(COLOR_CYAN, '║  Ctrl+C                  →  interrupt current cmd  ║', COLOR_RESET);
  Writeln(COLOR_CYAN, '╚════════════════════════════════════════════════════╝', COLOR_RESET);
  Writeln;
end;

procedure MainLoop;
var
  line: string;
  cmd: AnsiString;
begin
  while True do
  begin
    if not IsRunning then Break;

    if MultiLineInput then
      Write(COLOR_GRAY, PROMPT_MULTI)
    else
      Write(COLOR_GREEN, PROMPT_NORMAL, COLOR_RESET);

    ReadLn(line);

    if line.EndsWith('\') then
    begin
      MultiLineInput := True;
      CurrentInput := CurrentInput + Copy(line, 1, Length(line)-1) + sLineBreak;
      Continue;
    end
    else if MultiLineInput then
    begin
      CurrentInput := CurrentInput + line;
      MultiLineInput := False;
      line := CurrentInput;
      CurrentInput := '';
    end;

    line := Trim(line);
    if line = '' then Continue;

    if SameText(line, 'exit') or SameText(line, 'quit') or SameText(line, '/bye') then
      Break;

    if SameText(line, 'clear') then
    begin
      Write(#27'[2J'#27'[H');
      Continue;
    end;

    if IsRunning then
    begin
      cmd := AnsiString(line + sLineBreak);
      Pty_Write(PtyHandle, PAnsiChar(cmd), Length(cmd));
      Sleep(50);
    end;
  end;
end;

// ──────────────────────────────────────────────────────────────────────────────
// Entry Point
// ──────────────────────────────────────────────────────────────────────────────
var
  ShellCommand: string;
begin
  try
    EnableVirtualTerminal;
    GetConsoleSize(ScreenCols, ScreenRows);
    ShowWelcome;

    Writeln(COLOR_GRAY, 'Starting local shell (64-bit compatible)...', COLOR_RESET);

    if Pty_Init <> 0 then
      raise Exception.Create('ConPTY not available on this system');

    ShellCommand := 'cmd.exe';

    PtyHandle := Pty_Create(
      PAnsiChar(AnsiString(ShellCommand)),
      nil, 0,
      nil, nil,
      ScreenCols, ScreenRows,
      @OnPtyData,
      @OnPtyExit,
      @OnPtyError,
      PtyPid
    );

    if PtyHandle <= 0 then
      raise Exception.Create('Failed to create PTY');

    IsRunning := True;
    Writeln(COLOR_GRAY, 'PTY created. PID: ', PtyPid, ' Handle: ', IntToHex(PtyHandle, 8), COLOR_RESET);
    Writeln;

    MainLoop;

  except
    on E: Exception do
      Writeln(COLOR_RED, 'Fatal error: ', E.ClassName, ': ', E.Message, COLOR_RESET);
  end;

  if PtyHandle > 0 then
  begin
    Pty_Close(PtyHandle);
    Sleep(200);
    Pty_Kill(PtyHandle);
  end;

  Writeln;
  Writeln(COLOR_CYAN, 'Goodbye from ', APP_NAME, COLOR_RESET);
  Writeln('Press ENTER to exit...');
  ReadLn;
end.
