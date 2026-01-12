unit PtyCore;

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs;

type
  PTY_HANDLE = Integer;

  TPtyDataCallback  = procedure(handle: PTY_HANDLE; data: PAnsiChar; len: Integer); stdcall;
  TPtyExitCallback  = procedure(handle: PTY_HANDLE; exitCode: Integer); stdcall;
  TPtyErrorCallback = procedure(handle: PTY_HANDLE; errorCode: Integer; msg: PAnsiChar); stdcall;

const
  PTY_OK                      = 0;
  PTY_ERR_NOT_FOUND           = -1;
  PTY_ERR_PIPE_CREATE          = -2;
  PTY_ERR_CONPTY_CREATE        = -3;
  PTY_ERR_PROC_CREATE          = -4;
  PTY_ERR_WRITE_FAILED         = -6;
  PTY_ERR_RESIZE_FAILED        = -7;
  PTY_ERR_INVALID_STATE        = -8;
  PTY_ERR_CONPTY_UNSUPPORTED   = -9;

type
  TPtyState = (psRunning, psClosing, psExited);

  TPtySession = class;

  TPtyReadThread = class(TThread)
  private
    FSession: TPtySession;
  protected
    procedure Execute; override;
  public
    constructor Create(ASession: TPtySession);
  end;

  TPtySession = class
  private
    FHandleId: PTY_HANDLE;
    FConPty: THandle;
    FProcHandle: THandle;
    FProcId: Cardinal;
    FInPipeWrite: THandle;
    FOutPipeRead: THandle;
    FReadThread: TPtyReadThread;
    FState: TPtyState;
    FExitCode: Integer;
    FOnData: TPtyDataCallback;
    FOnExit: TPtyExitCallback;
    FOnError: TPtyErrorCallback;
    FLock: TCriticalSection;
    procedure SetState(AState: TPtyState);
    procedure DoError(const Code: Integer; const Msg: string);
  public
    constructor Create(AHandleId: PTY_HANDLE);
    destructor Destroy; override;
    function Start(const CmdLine, Cwd: UnicodeString; const EnvBlock: PWideChar; Cols, Rows: Integer): Integer;
    function Write(const Data; Len: Integer): Integer;
    function Resize(Cols, Rows: Integer): Integer;
    function CloseGraceful: Integer;
    function KillHard: Integer;
    function IsAlive: Boolean;
    property HandleId: PTY_HANDLE read FHandleId;
    property ExitCode: Integer read FExitCode;
    property State: TPtyState read FState;
    property OnData: TPtyDataCallback read FOnData write FOnData;
    property OnExit: TPtyExitCallback read FOnExit write FOnExit;
    property OnError: TPtyErrorCallback read FOnError write FOnError;
  end;

function Pty_Init: Integer; stdcall;
function Pty_Create(command: PAnsiChar; args: PPAnsiChar; argCount: Integer; cwd: PAnsiChar; env: PPAnsiChar; cols, rows: Integer; onData: TPtyDataCallback; onExit: TPtyExitCallback; onError: TPtyErrorCallback; out outPid: Integer): PTY_HANDLE; stdcall;
function Pty_Write(handle: PTY_HANDLE; data: PAnsiChar; len: Integer): Integer; stdcall;
function Pty_Resize(handle: PTY_HANDLE; cols, rows: Integer): Integer; stdcall;
function Pty_Close(handle: PTY_HANDLE): Integer; stdcall;
function Pty_Kill(handle: PTY_HANDLE): Integer; stdcall;
function Pty_IsAlive(handle: PTY_HANDLE): Integer; stdcall;
function Pty_GetExitCode(handle: PTY_HANDLE; outExitCode: PInteger): Integer; stdcall;

implementation

uses
  System.AnsiStrings;

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = $00020016;
  EXTENDED_STARTUPINFO_PRESENT = $00080000;
  CREATE_UNICODE_ENVIRONMENT   = $00000400;

type
  PPROC_THREAD_ATTRIBUTE_LIST = Pointer;
  TStartupInfoExW = record
    StartupInfo: TStartupInfoW;
    lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST;
  end;
  PAnsiCharArray = ^TAnsiCharArray;
  TAnsiCharArray = array[0..1023] of PAnsiChar;

function CreatePseudoConsole(size: COORD; hInput, hOutput: THandle; dwFlags: DWORD; out phPC: THandle): HRESULT; stdcall; external kernel32;
function ResizePseudoConsole(hPC: THandle; size: COORD): HRESULT; stdcall; external kernel32;
procedure ClosePseudoConsole(hPC: THandle); stdcall; external kernel32;
function InitializeProcThreadAttributeList(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST; dwAttributeCount: DWORD; dwFlags: DWORD; var lpSize: NativeUInt): BOOL; stdcall; external kernel32;
function UpdateProcThreadAttribute(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST; dwFlags: DWORD; Attribute: NativeUInt; lpValue: Pointer; cbSize: NativeUInt; lpPreviousValue: Pointer; lpReturnSize: PNativeUInt): BOOL; stdcall; external kernel32;
procedure DeleteProcThreadAttributeList(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST); stdcall; external kernel32;

var
  GPtyLock: TCriticalSection;
  GPtyNextHandle: PTY_HANDLE = 1;
  GPtySessions: TObjectDictionary<PTY_HANDLE, TPtySession>;
  GConPtyAvailable: Boolean = False;

function SafeUtf8ToUnicode(const AAnsiPtr: PAnsiChar): UnicodeString;
var
  LStr: RawByteString;
  Len: Integer;
begin
  if (AAnsiPtr = nil) or (AAnsiPtr^ = #0) then Exit('');
  Len := System.AnsiStrings.StrLen(AAnsiPtr);
  SetLength(LStr, Len);
  if Len > 0 then Move(AAnsiPtr^, LStr[1], Len);
  SetCodePage(LStr, CP_UTF8, False);
  Result := UnicodeString(LStr);
end;

function EscapeArg(const S: string): string;
var
  i: Integer;
  c: Char;
  needQuotes: Boolean;
begin
  if S = '' then Exit('""');
  needQuotes := False;
  for c in S do
    if CharInSet(c, [' ', #9, '"', '&', '^', '|', '(', ')', '<', '>', ';', '%']) then
    begin
      needQuotes := True;
      Break;
    end;
  if not needQuotes then Exit(S);
  Result := '"';
  for i := 1 to Length(S) do
  begin
    if S[i] = '"' then Result := Result + '""' else Result := Result + S[i];
  end;
  Result := Result + '"';
end;

function BuildEnvBlock(env: PPAnsiChar): PWideChar;
var
  P: PAnsiCharArray;
  I: Integer;
  S, Combined: UnicodeString;
begin
  Result := nil;
  if env = nil then Exit;
  P := PAnsiCharArray(env);
  Combined := '';
  I := 0;
  while P^[I] <> nil do
  begin
    S := SafeUtf8ToUnicode(P^[I]);
    Combined := Combined + S + #0;
    Inc(I);
  end;
  if Combined = '' then Exit;
  Combined := Combined + #0#0;
  Result := AllocMem(Length(Combined) * SizeOf(WideChar));
  Move(PWideChar(Combined)^, Result^, Length(Combined) * SizeOf(WideChar));
end;

{ TPtyReadThread }
constructor TPtyReadThread.Create(ASession: TPtySession);
begin
  inherited Create(True);
  FSession := ASession;
end;

procedure TPtyReadThread.Execute;
const BUF_SIZE = 8192;
var
  Buffer: array[0..BUF_SIZE - 1] of AnsiChar;
  BytesRead, LExitCode: DWORD;
begin
  while not Terminated do
  begin
    if (FSession.FOutPipeRead = 0) or (not ReadFile(FSession.FOutPipeRead, Buffer, BUF_SIZE, BytesRead, nil)) then
      Break;

    if (BytesRead > 0) then
    begin
      FSession.FLock.Enter;
      try
        if Assigned(FSession.FOnData) then
          FSession.FOnData(FSession.HandleId, @Buffer[0], BytesRead);
      finally
        FSession.FLock.Leave;
      end;
    end;
  end;

  if FSession.FProcHandle <> 0 then
  begin
    WaitForSingleObject(FSession.FProcHandle, 2000);
    if GetExitCodeProcess(FSession.FProcHandle, LExitCode) then
      FSession.FExitCode := Integer(LExitCode);
  end;

  FSession.SetState(psExited);
  FSession.FLock.Enter;
  try
    if Assigned(FSession.FOnExit) then
      FSession.FOnExit(FSession.HandleId, FSession.FExitCode);
  finally
    FSession.FLock.Leave;
  end;
end;

{ TPtySession }
constructor TPtySession.Create(AHandleId: PTY_HANDLE);
begin
  FHandleId := AHandleId;
  FLock := TCriticalSection.Create;
  FState := psRunning;
end;

destructor TPtySession.Destroy;
begin
  FLock.Enter;
  try
    FOnData := nil; FOnExit := nil; FOnError := nil;
  finally
    FLock.Leave;
  end;

  if FInPipeWrite <> 0 then
  begin
    CloseHandle(FInPipeWrite);
    FInPipeWrite := 0;
  end;

  if Assigned(FReadThread) then
  begin
    FReadThread.Terminate;
    if FOutPipeRead <> 0 then CancelIoEx(FOutPipeRead, nil);
    FReadThread.WaitFor;
    FreeAndNil(FReadThread);
  end;

  if FConPty <> 0 then
  begin
    ClosePseudoConsole(FConPty);
    FConPty := 0;
  end;

  if FOutPipeRead <> 0 then
  begin
    CloseHandle(FOutPipeRead);
    FOutPipeRead := 0;
  end;

  if FProcHandle <> 0 then
  begin
    CloseHandle(FProcHandle);
    FProcHandle := 0;
  end;

  FLock.Free;
  inherited;
end;

procedure TPtySession.DoError(const Code: Integer; const Msg: string);
var
  A: AnsiString;
begin
  FLock.Enter;
  try
    if Assigned(FOnError) then
    begin
      A := AnsiString(Format('%s (Win32: %d - %s)', [Msg, Code, SysErrorMessage(Code)]));
      FOnError(FHandleId, Code, PAnsiChar(A));
    end;
  finally
    FLock.Leave;
  end;
end;

function TPtySession.Start(const CmdLine, Cwd: UnicodeString; const EnvBlock: PWideChar; Cols, Rows: Integer): Integer;
var
  InPipeRead, OutPipeWrite: THandle;
  Sec: TSecurityAttributes;
  StartupEx: TStartupInfoExW;
  ProcInfo: TProcessInformation;
  AttrListSize: NativeUInt;
  ConsoleSize: COORD;
  Res: HRESULT;
  MutableCmdLine: UnicodeString;
  pWorkDir: PWideChar;
begin
  Result := PTY_OK;
  MutableCmdLine := CmdLine;
  UniqueString(MutableCmdLine);

  if Cwd = '' then pWorkDir := nil else pWorkDir := PWideChar(Cwd);

  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True;
  Sec.lpSecurityDescriptor := nil;

  InPipeRead := 0; OutPipeWrite := 0;
  if not CreatePipe(InPipeRead, FInPipeWrite, @Sec, 0) then Exit(PTY_ERR_PIPE_CREATE);
  if not CreatePipe(FOutPipeRead, OutPipeWrite, @Sec, 0) then
  begin
    CloseHandle(InPipeRead);
    Exit(PTY_ERR_PIPE_CREATE);
  end;

  try
    SetHandleInformation(FInPipeWrite, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(FOutPipeRead, HANDLE_FLAG_INHERIT, 0);

    ConsoleSize.X := Cols; ConsoleSize.Y := Rows;
    Res := CreatePseudoConsole(ConsoleSize, InPipeRead, OutPipeWrite, 0, FConPty);
    if Res < 0 then Exit(PTY_ERR_CONPTY_CREATE);

    CloseHandle(InPipeRead); InPipeRead := 0;
    CloseHandle(OutPipeWrite); OutPipeWrite := 0;

    FillChar(StartupEx, SizeOf(StartupEx), 0);
    StartupEx.StartupInfo.cb := SizeOf(TStartupInfoExW);

    AttrListSize := 0;
    InitializeProcThreadAttributeList(nil, 1, 0, AttrListSize);
    StartupEx.lpAttributeList := AllocMem(AttrListSize);
    try
      InitializeProcThreadAttributeList(StartupEx.lpAttributeList, 1, 0, AttrListSize);
      UpdateProcThreadAttribute(StartupEx.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, @FConPty, SizeOf(THandle), nil, nil);

      if not CreateProcessW(nil, PWideChar(MutableCmdLine), nil, nil, False,
                EXTENDED_STARTUPINFO_PRESENT or CREATE_UNICODE_ENVIRONMENT,
                EnvBlock, pWorkDir, StartupEx.StartupInfo, ProcInfo) then
      begin
        DoError(GetLastError, 'CreateProcessW failed. Cmd: ' + CmdLine);
        Exit(PTY_ERR_PROC_CREATE);
      end;

      FProcHandle := ProcInfo.hProcess;
      FProcId := ProcInfo.dwProcessId;
      CloseHandle(ProcInfo.hThread);
      FReadThread := TPtyReadThread.Create(Self);
      FReadThread.Start;
    finally
      DeleteProcThreadAttributeList(StartupEx.lpAttributeList);
      FreeMem(StartupEx.lpAttributeList);
    end;
  finally
    if InPipeRead <> 0 then CloseHandle(InPipeRead);
    if OutPipeWrite <> 0 then CloseHandle(OutPipeWrite);
  end;
end;

function TPtySession.Write(const Data; Len: Integer): Integer;
var Written: DWORD;
begin
  if (FState <> psRunning) or (FInPipeWrite = 0) then Exit(PTY_ERR_INVALID_STATE);
  if not WriteFile(FInPipeWrite, Data, Len, Written, nil) then Exit(PTY_ERR_WRITE_FAILED);
  Result := Integer(Written);
end;

function TPtySession.Resize(Cols, Rows: Integer): Integer;
var Size: COORD;
begin
  if (FConPty = 0) or (FState <> psRunning) then Exit(PTY_ERR_INVALID_STATE);
  Size.X := Cols; Size.Y := Rows;
  if ResizePseudoConsole(FConPty, Size) >= 0 then Result := PTY_OK else Result := PTY_ERR_RESIZE_FAILED;
end;

function TPtySession.IsAlive: Boolean;
begin
  Result := (FState = psRunning);
end;

procedure TPtySession.SetState(AState: TPtyState);
begin
  FLock.Enter;
  try
    FState := AState;
  finally
    FLock.Leave;
  end;
end;

function TPtySession.CloseGraceful: Integer;
begin
  SetState(psClosing);
  if FProcId <> 0 then
  begin
    if FInPipeWrite <> 0 then
    begin
      CloseHandle(FInPipeWrite);
      FInPipeWrite := 0;
    end;
    if WaitForSingleObject(FProcHandle, 1500) = WAIT_TIMEOUT then
       TerminateProcess(FProcHandle, 1);
  end;
  Result := PTY_OK;
end;

function TPtySession.KillHard: Integer;
begin
  SetState(psClosing);
  if FProcHandle <> 0 then TerminateProcess(FProcHandle, 1);
  Result := PTY_OK;
end;

{ API Logic }
function Pty_Init: Integer; stdcall;
begin
  if GConPtyAvailable then Result := PTY_OK else Result := PTY_ERR_CONPTY_UNSUPPORTED;
end;

function Pty_Create(command: PAnsiChar; args: PPAnsiChar; argCount: Integer; cwd: PAnsiChar; env: PPAnsiChar; cols, rows: Integer; onData: TPtyDataCallback; onExit: TPtyExitCallback; onError: TPtyErrorCallback; out outPid: Integer): PTY_HANDLE; stdcall;
var
  S: TPtySession;
  CmdLine, WorkDir: UnicodeString;
  PArgs: PAnsiCharArray;
  I: Integer;
  EnvBlock: PWideChar;
  HID: PTY_HANDLE;
begin
  GPtyLock.Enter;
  try
    HID := GPtyNextHandle;
    Inc(GPtyNextHandle);
  finally
    GPtyLock.Leave;
  end;

  S := TPtySession.Create(HID);
  S.OnData := onData; S.OnExit := onExit; S.OnError := onError;

  CmdLine := SafeUtf8ToUnicode(command);
  if Pos(' ', CmdLine) > 0 then CmdLine := '"' + CmdLine + '"';

  if (args <> nil) and (argCount > 0) then
  begin
    PArgs := PAnsiCharArray(args);
    for I := 0 to argCount - 1 do
      CmdLine := CmdLine + ' ' + EscapeArg(SafeUtf8ToUnicode(PArgs^[I]));
  end;

  WorkDir := SafeUtf8ToUnicode(cwd);
  EnvBlock := BuildEnvBlock(env);
  try
    if S.Start(CmdLine, WorkDir, EnvBlock, cols, rows) <> PTY_OK then
    begin
      S.Free;
      outPid := 0;
      Exit(PTY_ERR_PROC_CREATE);
    end;
    outPid := Integer(S.FProcId);
  finally
    if EnvBlock <> nil then FreeMem(EnvBlock);
  end;

  GPtyLock.Enter;
  try
    GPtySessions.Add(HID, S);
  finally
    GPtyLock.Leave;
  end;
  Result := HID;
end;

function Pty_Write(handle: PTY_HANDLE; data: PAnsiChar; len: Integer): Integer; stdcall;
var S: TPtySession;
begin
  GPtyLock.Enter;
  try
    if not GPtySessions.TryGetValue(handle, S) then Exit(PTY_ERR_NOT_FOUND);
    Result := S.Write(data^, len);
  finally
    GPtyLock.Leave;
  end;
end;

function Pty_Resize(handle: PTY_HANDLE; cols, rows: Integer): Integer; stdcall;
var S: TPtySession;
begin
  GPtyLock.Enter;
  try
    if not GPtySessions.TryGetValue(handle, S) then Exit(PTY_ERR_NOT_FOUND);
    Result := S.Resize(cols, rows);
  finally
    GPtyLock.Leave;
  end;
end;

function Pty_Close(handle: PTY_HANDLE): Integer; stdcall;
var S: TPtySession;
begin
  GPtyLock.Enter;
  try
    if not GPtySessions.TryGetValue(handle, S) then Exit(PTY_ERR_NOT_FOUND);
    if S.IsAlive then S.CloseGraceful;
    GPtySessions.Remove(handle);
    Result := PTY_OK;
  finally
    GPtyLock.Leave;
  end;
end;

function Pty_Kill(handle: PTY_HANDLE): Integer; stdcall;
var S: TPtySession;
begin
  GPtyLock.Enter;
  try
    if not GPtySessions.TryGetValue(handle, S) then Exit(PTY_ERR_NOT_FOUND);
    Result := S.KillHard;
  finally
    GPtyLock.Leave;
  end;
end;

function Pty_IsAlive(handle: PTY_HANDLE): Integer; stdcall;
var S: TPtySession;
begin
  GPtyLock.Enter;
  try
    if not GPtySessions.TryGetValue(handle, S) then Exit(0);
    if S.IsAlive then Result := 1 else Result := 0;
  finally
    GPtyLock.Leave;
  end;
end;

function Pty_GetExitCode(handle: PTY_HANDLE; outExitCode: PInteger): Integer; stdcall;
var S: TPtySession;
begin
  GPtyLock.Enter;
  try
    if not GPtySessions.TryGetValue(handle, S) then Exit(PTY_ERR_NOT_FOUND);
    outExitCode^ := S.ExitCode;
    Result := PTY_OK;
  finally
    GPtyLock.Leave;
  end;
end;

initialization
  GPtyLock := TCriticalSection.Create;
  GPtySessions := TObjectDictionary<PTY_HANDLE, TPtySession>.Create([doOwnsValues]);
  GConPtyAvailable := Assigned(GetProcAddress(GetModuleHandle(kernel32), 'CreatePseudoConsole'));

finalization
  GPtySessions.Free;
  GPtyLock.Free;

end.
