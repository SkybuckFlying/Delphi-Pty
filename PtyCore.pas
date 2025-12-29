unit PtyCore;

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Generics.Collections;

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

  TPtySession = class; // Forward declaration

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
    FReadThread: TThread;
    FState: TPtyState;
    FExitCode: Integer;
    FOnData: TPtyDataCallback;
    FOnExit: TPtyExitCallback;
    FOnError: TPtyErrorCallback;
    FCrit: TRTLCriticalSection;
    procedure SetState(AState: TPtyState);
    procedure DoError(const Code: Integer; const Msg: string);
  public
    constructor Create(AHandleId: PTY_HANDLE);
    destructor Destroy; override;
    function Start(
      const CmdLine: UnicodeString;
      const Cwd: UnicodeString;
      const EnvBlock: PWideChar;
      Cols: Integer;
      Rows: Integer
    ): Integer;
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
): PTY_HANDLE; stdcall;
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

  TWinCoord = record
    X: SmallInt;
    Y: SmallInt;
  end;

  TStartupInfoW_Explicit = record
    cb: DWORD;
    lpReserved: PWideChar;
    lpDesktop: PWideChar;
    lpTitle: PWideChar;
    dwX: DWORD;
    dwY: DWORD;
    dwXSize: DWORD;
    dwYSize: DWORD;
    dwXCountChars: DWORD;
    dwYCountChars: DWORD;
    dwFillAttribute: DWORD;
    dwFlags: DWORD;
    wShowWindow: Word;
    cbReserved2: Word;
    lpReserved2: PByte;
    hStdInput: THandle;
    hStdOutput: THandle;
    hStdError: THandle;
  end;

  TStartupInfoExW_Custom = record
    StartupInfo: TStartupInfoW_Explicit;
    lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST;
  end;

  TPAnsiCharArray = array[0..$00FFFFFF] of PAnsiChar;
  PPAnsiCharArray = ^TPAnsiCharArray;

function CreatePseudoConsole(size: DWORD; hInput: THandle; hOutput: THandle; dwFlags: DWORD; out phPC: THandle): HRESULT; stdcall; external kernel32;
function ResizePseudoConsole(hPC: THandle; size: DWORD): HRESULT; stdcall; external kernel32;
procedure ClosePseudoConsole(hPC: THandle); stdcall; external kernel32;
function InitializeProcThreadAttributeList(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST; dwAttributeCount: DWORD; dwFlags: DWORD; var lpSize: SIZE_T): BOOL; stdcall; external kernel32;
function UpdateProcThreadAttribute(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST; dwFlags: DWORD; Attribute: DWORD_PTR; lpValue: Pointer; cbSize: SIZE_T; lpPreviousValue: Pointer; lpReturnSize: PSIZE_T): BOOL; stdcall; external kernel32;
procedure DeleteProcThreadAttributeList(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST); stdcall; external kernel32;

function MyCreateProcessW(
  lpApplicationName: PWideChar;
  lpCommandLine: PWideChar;
  lpProcessAttributes: Pointer;
  lpThreadAttributes: Pointer;
  bInheritHandles: BOOL;
  dwCreationFlags: DWORD;
  lpEnvironment: Pointer;
  lpCurrentDirectory: PWideChar;
  lpStartupInfo: Pointer;
  var lpProcessInformation: PROCESS_INFORMATION
): BOOL; stdcall; external kernel32 name 'CreateProcessW';

var
  GPtyLock: TRTLCriticalSection;
  GPtyNextHandle: PTY_HANDLE = 1;
  GPtySessions: TObjectDictionary<PTY_HANDLE, TPtySession>;
  GConPtyAvailable: Boolean = False;

procedure InitGlobals;
var
  HKernel: HMODULE;
begin
  InitializeCriticalSection(GPtyLock);
  GPtySessions := TObjectDictionary<PTY_HANDLE, TPtySession>.Create([doOwnsValues]);

  HKernel := GetModuleHandle('kernel32.dll');
  if HKernel <> 0 then
  begin
    GConPtyAvailable :=
      Assigned(GetProcAddress(HKernel, 'CreatePseudoConsole')) and
      Assigned(GetProcAddress(HKernel, 'ResizePseudoConsole')) and
      Assigned(GetProcAddress(HKernel, 'ClosePseudoConsole'));
  end;
end;

procedure DoneGlobals;
begin
  GPtySessions.Free;
  DeleteCriticalSection(GPtyLock);
end;

function AllocHandle: PTY_HANDLE;
begin
  EnterCriticalSection(GPtyLock);
  try
    Result := GPtyNextHandle;
    Inc(GPtyNextHandle);
  finally
    LeaveCriticalSection(GPtyLock);
  end;
end;

function FindSession(handle: PTY_HANDLE): TPtySession;
begin
  EnterCriticalSection(GPtyLock);
  try
    if not GPtySessions.TryGetValue(handle, Result) then
      Result := nil;
  finally
    LeaveCriticalSection(GPtyLock);
  end;
end;

procedure RegisterSession(S: TPtySession);
begin
  EnterCriticalSection(GPtyLock);
  try
    GPtySessions.Add(S.HandleId, S);
  finally
    LeaveCriticalSection(GPtyLock);
  end;
end;

function BuildEnvBlock(env: PPAnsiChar): PWideChar;
var
  Blocks: TStringBuilder;
  P: PPAnsiCharArray;
  I: Integer;
  Utf8: UTF8String;
begin
  Result := nil;
  if env = nil then
    Exit;

  Blocks := TStringBuilder.Create;
  try
    P := PPAnsiCharArray(env);
    I := 0;
    while (P^[I] <> nil) do
    begin
      Utf8 := UTF8String(P^[I]);
      Blocks.Append(UTF8ToUnicodeString(Utf8));
      Blocks.Append(#0);
      Inc(I);
    end;
    Blocks.Append(#0);

    var SStr: string;
    SStr := Blocks.ToString;
    Result := AllocMem((SStr.Length + 1) * SizeOf(WideChar));
    Move(PWideChar(SStr)^, Result^, SStr.Length * SizeOf(WideChar));
  finally
    Blocks.Free;
  end;
end;

{ TPtyReadThread }

constructor TPtyReadThread.Create(ASession: TPtySession);
begin
  inherited Create(True);
  FSession := ASession;
  FreeOnTerminate := False;
end;

procedure TPtyReadThread.Execute;
const
  BUF_SIZE = 4096;
var
  Buffer: array[0..BUF_SIZE - 1] of AnsiChar;
  BytesRead: DWORD;
  LExitCode: DWORD;
begin
  while not Terminated do
  begin
    BytesRead := 0;
    
    // Direct blocking read - no PeekNamedPipe
    if not ReadFile(FSession.FOutPipeRead, Buffer, BUF_SIZE, BytesRead, nil) then
    begin
      var Err := GetLastError;
      if Err = ERROR_BROKEN_PIPE then
        Break;
      Sleep(50);
      Continue;
    end;
    
    if BytesRead = 0 then
    begin
      Sleep(50);
      Continue;
    end;
    
    if BytesRead > 0 then
    begin
      if Assigned(FSession.FOnData) then
        FSession.FOnData(FSession.HandleId, @Buffer[0], BytesRead);
    end;
  end;

  if FSession.FProcHandle <> 0 then
  begin
    WaitForSingleObject(FSession.FProcHandle, 2000);
    if GetExitCodeProcess(FSession.FProcHandle, LExitCode) then
      FSession.FExitCode := Integer(LExitCode)
    else
      FSession.FExitCode := -1;
  end;

  FSession.SetState(psExited);

  if Assigned(FSession.FOnExit) then
    FSession.FOnExit(FSession.HandleId, FSession.FExitCode);
end;

{ TPtySession }

constructor TPtySession.Create(AHandleId: PTY_HANDLE);
begin
  inherited Create;
  FHandleId := AHandleId;
  FConPty := 0;
  FProcHandle := 0;
  FInPipeWrite := 0;
  FOutPipeRead := 0;
  FReadThread := nil;
  FState := psRunning;
  FExitCode := -1;
  InitializeCriticalSection(FCrit);
end;

destructor TPtySession.Destroy;
begin
  if FConPty <> 0 then ClosePseudoConsole(FConPty);
  if FOutPipeRead <> 0 then CloseHandle(FOutPipeRead);
  if FInPipeWrite <> 0 then CloseHandle(FInPipeWrite);
  if FProcHandle <> 0 then CloseHandle(FProcHandle);

  if FReadThread <> nil then
  begin
    FReadThread.Terminate;
    WaitForSingleObject(FReadThread.Handle, 2000);
    FReadThread.Free;
  end;

  DeleteCriticalSection(FCrit);
  inherited;
end;

procedure TPtySession.DoError(const Code: Integer; const Msg: string);
var
  Ansi: AnsiString;
begin
  if Assigned(FOnError) then
  begin
    Ansi := AnsiString(UTF8Encode(Msg));
    FOnError(FHandleId, Code, PAnsiChar(Ansi));
  end;
end;

procedure TPtySession.SetState(AState: TPtyState);
begin
  EnterCriticalSection(FCrit);
  try
    FState := AState;
  finally
    LeaveCriticalSection(FCrit);
  end;
end;

function TPtySession.Start(
  const CmdLine: UnicodeString;
  const Cwd: UnicodeString;
  const EnvBlock: PWideChar;
  Cols: Integer;
  Rows: Integer
): Integer;
var
  InPipeRead, OutPipeWrite: THandle;
  Sec: SECURITY_ATTRIBUTES;
  Startup: TStartupInfoExW_Custom;
  ProcInfo: PROCESS_INFORMATION;
  AttrListSize: SIZE_T;
  AttrList: PPROC_THREAD_ATTRIBUTE_LIST;
  Flags: DWORD;
  CmdLineMutable: UnicodeString;
  PCwd: PWideChar;
begin
  Result := PTY_OK;
  if not GConPtyAvailable then
    Exit(PTY_ERR_CONPTY_UNSUPPORTED);


  ZeroMemory(@Sec, SizeOf(Sec));
  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True;

  InPipeRead := 0;
  OutPipeWrite := 0;
  AttrList := nil;
  ZeroMemory(@Startup, SizeOf(Startup));
  ZeroMemory(@ProcInfo, SizeOf(ProcInfo));

  try
    if not CreatePipe(FOutPipeRead, OutPipeWrite, @Sec, 0) then Exit(PTY_ERR_PIPE_CREATE);
    if not CreatePipe(InPipeRead, FInPipeWrite, @Sec, 0) then Exit(PTY_ERR_PIPE_CREATE);
    
    // Ensure the parent's pipe ends are not inherited by the child
    SetHandleInformation(FOutPipeRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(FInPipeWrite, HANDLE_FLAG_INHERIT, 0);

    var dwSize: DWORD;
    dwSize := (Word(Rows) shl 16) or Word(Cols);

    if Failed(CreatePseudoConsole(dwSize, InPipeRead, OutPipeWrite, 0, FConPty)) then
    begin
        Exit(PTY_ERR_CONPTY_CREATE);
    end;

    Startup.StartupInfo.cb := SizeOf(TStartupInfoExW_Custom);
    Startup.StartupInfo.dwFlags := STARTF_USESHOWWINDOW;
    Startup.StartupInfo.wShowWindow := SW_HIDE;
    // CRITICAL: Set standard handles to NULL for ConPTY
    Startup.StartupInfo.hStdInput := 0;
    Startup.StartupInfo.hStdOutput := 0;
    Startup.StartupInfo.hStdError := 0;

    AttrListSize := 0;
    InitializeProcThreadAttributeList(nil, 1, 0, AttrListSize);
    if AttrListSize > 0 then
    begin
        AttrList := PPROC_THREAD_ATTRIBUTE_LIST(AllocMem(AttrListSize));
        if not InitializeProcThreadAttributeList(AttrList, 1, 0, AttrListSize) then
          Exit(PTY_ERR_CONPTY_CREATE);

        if not UpdateProcThreadAttribute(AttrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                       Pointer(FConPty), SizeOf(THandle), nil, nil) then
          Exit(PTY_ERR_CONPTY_CREATE);

        Startup.lpAttributeList := AttrList;
    end;

    Flags := EXTENDED_STARTUPINFO_PRESENT or CREATE_UNICODE_ENVIRONMENT;

    CmdLineMutable := CmdLine;
    UniqueString(CmdLineMutable);

    if Cwd <> '' then PCwd := PWideChar(Cwd) else PCwd := nil;

    // CRITICAL: bInheritHandles must be FALSE for ConPTY
    if not MyCreateProcessW(nil, PWideChar(CmdLineMutable), nil, nil, False,
                          Flags, EnvBlock, PCwd,
                          @Startup.StartupInfo, ProcInfo) then
    begin
      DoError(GetLastError, 'CreateProcess failed for: ' + CmdLine);
      Exit(PTY_ERR_PROC_CREATE);
    end;
    FProcHandle := ProcInfo.hProcess;
    FProcId := ProcInfo.dwProcessId;
    CloseHandle(ProcInfo.hThread);

    FReadThread := TPtyReadThread.Create(Self);
    FReadThread.Start;

    // Now safe to close child pipe ends
    if InPipeRead <> 0 then begin CloseHandle(InPipeRead); InPipeRead := 0; end;
    if OutPipeWrite <> 0 then begin CloseHandle(OutPipeWrite); OutPipeWrite := 0; end;
  finally
    if AttrList <> nil then
    begin
      DeleteProcThreadAttributeList(AttrList);
      FreeMem(AttrList);
    end;
    if InPipeRead <> 0 then CloseHandle(InPipeRead);
    if OutPipeWrite <> 0 then CloseHandle(OutPipeWrite);
  end;
end;

function TPtySession.Write(const Data; Len: Integer): Integer;
var
  Written: DWORD;
begin
  if not IsAlive then Exit(PTY_ERR_INVALID_STATE);
  if not WriteFile(FInPipeWrite, Data, Len, Written, nil) then
  begin
    Result := PTY_ERR_WRITE_FAILED;
  end
  else
    Result := Integer(Written);
end;

function TPtySession.Resize(Cols, Rows: Integer): Integer;
var
  dwSize: DWORD;
begin
  if not IsAlive then Exit(PTY_ERR_INVALID_STATE);
  dwSize := (Word(Rows) shl 16) or Word(Cols);
  if Failed(ResizePseudoConsole(FConPty, dwSize)) then
    Result := PTY_ERR_RESIZE_FAILED
  else
    Result := PTY_OK;
end;

function TPtySession.CloseGraceful: Integer;
begin
  if FState <> psRunning then Exit(PTY_ERR_ALREADY_CLOSING);
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
  Result := PTY_OK;
  if FConPty <> 0 then
  begin
    ClosePseudoConsole(FConPty);
    FConPty := 0;
  end;
  if FProcHandle <> 0 then
  begin
    if not TerminateProcess(FProcHandle, 1) then Result := PTY_ERR_INVALID_STATE;
  end;
end;

function TPtySession.IsAlive: Boolean;
begin
  EnterCriticalSection(FCrit);
  try
    Result := FState = psRunning;
  finally
    LeaveCriticalSection(FCrit);
  end;
end;

{ Exported functions }

function Pty_Init: Integer; stdcall;
begin
  if not GConPtyAvailable then Result := PTY_ERR_CONPTY_UNSUPPORTED
  else Result := PTY_OK;
end;

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
): PTY_HANDLE; stdcall;
var
  Handle: PTY_HANDLE;
  Session: TPtySession;
  CmdLine: UnicodeString;
  CwdW: UnicodeString;
  I: Integer;
  ArgUtf8: UTF8String;
  EnvBlock: PWideChar;
begin
  if not GConPtyAvailable then Exit(PTY_ERR_CONPTY_UNSUPPORTED);

  Handle := AllocHandle;
  Session := TPtySession.Create(Handle);
  Session.OnData := onData;
  Session.OnExit := onExit;
  Session.OnError := onError;

  CmdLine := UTF8ToUnicodeString(UTF8String(command));
  if (args <> nil) and (argCount > 0) then
  begin
    for I := 0 to argCount - 1 do
    begin
      ArgUtf8 := UTF8String(PPAnsiCharArray(args)^[I]);
      CmdLine := CmdLine + ' "' + UTF8ToUnicodeString(ArgUtf8) + '"';
    end;
  end;

  if cwd <> nil then CwdW := UTF8ToUnicodeString(UTF8String(cwd)) else CwdW := '';

  EnvBlock := BuildEnvBlock(env);
  try
    if Session.Start(CmdLine, CwdW, EnvBlock, cols, rows) <> PTY_OK then
    begin
      Session.Free;
      Exit(PTY_ERR_PROC_CREATE);
    end;
  finally
    if EnvBlock <> nil then FreeMem(EnvBlock);
  end;

  RegisterSession(Session);
  Result := Handle;
end;

function Pty_Write(handle: PTY_HANDLE; data: PAnsiChar; len: Integer): Integer; stdcall;
var Session: TPtySession;
begin
  Session := FindSession(handle);
  if Session = nil then Exit(PTY_ERR_NOT_FOUND);
  Result := Session.Write(data^, len);
end;

function Pty_Resize(handle: PTY_HANDLE; cols, rows: Integer): Integer; stdcall;
var Session: TPtySession;
begin
  Session := FindSession(handle);
  if Session = nil then Exit(PTY_ERR_NOT_FOUND);
  Result := Session.Resize(cols, rows);
end;

function Pty_Close(handle: PTY_HANDLE): Integer; stdcall;
var Session: TPtySession;
begin
  Session := FindSession(handle);
  if Session = nil then Exit(PTY_ERR_NOT_FOUND);
  Result := Session.CloseGraceful;
end;

function Pty_Kill(handle: PTY_HANDLE): Integer; stdcall;
var Session: TPtySession;
begin
  Session := FindSession(handle);
  if Session = nil then Exit(PTY_ERR_NOT_FOUND);
  Result := Session.KillHard;
end;

function Pty_IsAlive(handle: PTY_HANDLE): Integer; stdcall;
var Session: TPtySession;
begin
  Session := FindSession(handle);
  if Session = nil then Exit(PTY_ERR_NOT_FOUND);
  if Session.IsAlive then Result := 1 else Result := 0;
end;

function Pty_GetExitCode(handle: PTY_HANDLE; outExitCode: PInteger): Integer; stdcall;
var Session: TPtySession;
begin
  Session := FindSession(handle);
  if Session = nil then Exit(PTY_ERR_NOT_FOUND);
  outExitCode^ := Session.ExitCode;
  Result := PTY_OK;
end;

initialization
  InitGlobals;

finalization
  DoneGlobals;

end.
