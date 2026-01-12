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
  PTY_ERR_PIPE_CREATE         = -2;
  PTY_ERR_CONPTY_CREATE       = -3;
  PTY_ERR_PROC_CREATE         = -4;
  PTY_ERR_ALREADY_CLOSING     = -5;
  PTY_ERR_WRITE_FAILED        = -6;
  PTY_ERR_RESIZE_FAILED       = -7;
  PTY_ERR_INVALID_STATE       = -8;
  PTY_ERR_CONPTY_UNSUPPORTED  = -9;

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
    property OnData: TPtyDataCallback read FOnData write FOnData;
    property OnExit: TPtyExitCallback read FOnExit write FOnExit;
    property OnError: TPtyErrorCallback read FOnError write FOnError;
  end;

function Pty_Init: Integer; stdcall;
function Pty_Create(command: PAnsiChar; args: PPAnsiChar; argCount: Integer; cwd: PAnsiChar; env: PPAnsiChar; cols, rows: Integer; onData: TPtyDataCallback; onExit: TPtyExitCallback; onError: TPtyErrorCallback): PTY_HANDLE; stdcall;
function Pty_Write(handle: PTY_HANDLE; data: PAnsiChar; len: Integer): Integer; stdcall;
function Pty_Resize(handle: PTY_HANDLE; cols, rows: Integer): Integer; stdcall;
function Pty_Close(handle: PTY_HANDLE): Integer; stdcall;
function Pty_Kill(handle: PTY_HANDLE): Integer; stdcall;
function Pty_IsAlive(handle: PTY_HANDLE): Integer; stdcall;
function Pty_GetExitCode(handle: PTY_HANDLE; outExitCode: PInteger): Integer; stdcall;

implementation

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
    S := UTF8ToString(P^[I]);
    Combined := Combined + S + #0;
    Inc(I);
  end;
  Combined := Combined + #0;
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
    if not ReadFile(FSession.FOutPipeRead, Buffer, BUF_SIZE, BytesRead, nil) then
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
    FOnData := nil;
    FOnExit := nil;
    FOnError := nil;
  finally
    FLock.Leave;
  end;

  if Assigned(FReadThread) then
  begin
    FReadThread.Terminate;
    CancelSynchronousIo(FReadThread.Handle);
    FReadThread.WaitFor;
    FReadThread.Free;
  end;

  if FConPty <> 0 then ClosePseudoConsole(FConPty);
  if FOutPipeRead <> 0 then CloseHandle(FOutPipeRead);
  if FInPipeWrite <> 0 then CloseHandle(FInPipeWrite);
  if FProcHandle <> 0 then CloseHandle(FProcHandle);

  FLock.Free;
  inherited;
end;

procedure TPtySession.DoError(const Code: Integer; const Msg: string);
var A: AnsiString;
begin
  if Assigned(FOnError) then
  begin
    A := AnsiString(Msg);
    FOnError(FHandleId, Code, PAnsiChar(A));
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
begin
  Result := PTY_OK;
  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True;
  Sec.lpSecurityDescriptor := nil;

  if not CreatePipe(InPipeRead, FInPipeWrite, @Sec, 0) then Exit(PTY_ERR_PIPE_CREATE);
  if not CreatePipe(FOutPipeRead, OutPipeWrite, @Sec, 0) then
  begin
    CloseHandle(InPipeRead);
    Exit(PTY_ERR_PIPE_CREATE);
  end;

  SetHandleInformation(FInPipeWrite, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(FOutPipeRead, HANDLE_FLAG_INHERIT, 0);

  ConsoleSize.X := Cols;
  ConsoleSize.Y := Rows;

  Res := CreatePseudoConsole(ConsoleSize, InPipeRead, OutPipeWrite, 0, FConPty);
  if Res >= 0 then
  begin
    CloseHandle(InPipeRead);
    CloseHandle(OutPipeWrite);

    FillChar(StartupEx, SizeOf(StartupEx), 0);
    StartupEx.StartupInfo.cb := SizeOf(StartupEx);

    AttrListSize := 0;
    InitializeProcThreadAttributeList(nil, 1, 0, AttrListSize);
    StartupEx.lpAttributeList := AllocMem(AttrListSize);

    if InitializeProcThreadAttributeList(StartupEx.lpAttributeList, 1, 0, AttrListSize) then
    begin
      if UpdateProcThreadAttribute(StartupEx.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                     Pointer(FConPty), SizeOf(THandle), nil, nil) then
      begin
        if CreateProcessW(nil, PWideChar(CmdLine), nil, nil, False,
                              EXTENDED_STARTUPINFO_PRESENT or CREATE_UNICODE_ENVIRONMENT,
                              EnvBlock, PWideChar(Cwd), StartupEx.StartupInfo, ProcInfo) then
        begin
          FProcHandle := ProcInfo.hProcess;
          FProcId := ProcInfo.dwProcessId;
          CloseHandle(ProcInfo.hThread);
          FReadThread := TPtyReadThread.Create(Self);
          FReadThread.Start;
        end
        else
        begin
          DoError(GetLastError, 'Process creation failed');
          Result := PTY_ERR_PROC_CREATE;
        end;
      end;
      DeleteProcThreadAttributeList(StartupEx.lpAttributeList);
    end;
    FreeMem(StartupEx.lpAttributeList);
  end
  else
    Result := PTY_ERR_CONPTY_CREATE;
end;

function TPtySession.Write(const Data; Len: Integer): Integer;
var Written: DWORD;
begin
  if not IsAlive then Exit(PTY_ERR_INVALID_STATE);
  if not WriteFile(FInPipeWrite, Data, Len, Written, nil) then Exit(PTY_ERR_WRITE_FAILED);
  Result := Integer(Written);
end;

function TPtySession.Resize(Cols, Rows: Integer): Integer;
var Size: COORD;
begin
  Size.X := Cols; Size.Y := Rows;
  if ResizePseudoConsole(FConPty, Size) >= 0 then Result := PTY_OK else Result := PTY_ERR_RESIZE_FAILED;
end;

function TPtySession.IsAlive: Boolean;
begin
  FLock.Enter;
  try
    Result := (FState = psRunning);
  finally
    FLock.Leave;
  end;
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
  if FInPipeWrite <> 0 then
  begin
    CloseHandle(FInPipeWrite);
    FInPipeWrite := 0;
  end;
  Result := PTY_OK;
end;

function TPtySession.KillHard: Integer;
begin
  if FProcHandle <> 0 then TerminateProcess(FProcHandle, 1);
  Result := PTY_OK;
end;

{ Exports }

function Pty_Init: Integer; stdcall;
begin
  if GConPtyAvailable then Result := PTY_OK else Result := PTY_ERR_CONPTY_UNSUPPORTED;
end;

function Pty_Create(command: PAnsiChar; args: PPAnsiChar; argCount: Integer; cwd: PAnsiChar; env: PPAnsiChar; cols, rows: Integer; onData: TPtyDataCallback; onExit: TPtyExitCallback; onError: TPtyErrorCallback): PTY_HANDLE; stdcall;
var
  S: TPtySession;
  CmdLine: UnicodeString;
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
  S.OnData := onData;
  S.OnExit := onExit;
  S.OnError := onError;

  CmdLine := '"' + UTF8ToString(command) + '"';
  if (args <> nil) and (argCount > 0) then
  begin
    PArgs := PAnsiCharArray(args);
    for I := 0 to argCount - 1 do
      CmdLine := CmdLine + ' "' + UTF8ToString(PArgs^[I]) + '"';
  end;

  EnvBlock := BuildEnvBlock(env);
  try
    if S.Start(CmdLine, UTF8ToString(cwd), EnvBlock, cols, rows) <> PTY_OK then
    begin
      S.Free;
      Exit(PTY_ERR_PROC_CREATE);
    end;
  finally
    FreeMem(EnvBlock);
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
begin
  GPtyLock.Enter;
  try
    if GPtySessions.ContainsKey(handle) then
    begin
      GPtySessions.Remove(handle);
      Result := PTY_OK;
    end
    else
      Result := PTY_ERR_NOT_FOUND;
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
