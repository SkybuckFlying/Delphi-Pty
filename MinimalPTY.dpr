program MinimalPTY;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils;

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = $00020016;
  EXTENDED_STARTUPINFO_PRESENT = $00080000;
  CREATE_UNICODE_ENVIRONMENT = $00000400;

type
  PPROC_THREAD_ATTRIBUTE_LIST = Pointer;
  
  TStartupInfoExW = record
    StartupInfo: TStartupInfoW;
    lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST;
  end;

function CreatePseudoConsole(size: DWORD; hInput: THandle; hOutput: THandle; dwFlags: DWORD; out phPC: THandle): HRESULT; stdcall; external kernel32;
procedure ClosePseudoConsole(hPC: THandle); stdcall; external kernel32;
function InitializeProcThreadAttributeList(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST; dwAttributeCount: DWORD; dwFlags: DWORD; var lpSize: SIZE_T): BOOL; stdcall; external kernel32;
function UpdateProcThreadAttribute(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST; dwFlags: DWORD; Attribute: DWORD_PTR; lpValue: Pointer; cbSize: SIZE_T; lpPreviousValue: Pointer; lpReturnSize: PSIZE_T): BOOL; stdcall; external kernel32;
procedure DeleteProcThreadAttributeList(lpAttributeList: PPROC_THREAD_ATTRIBUTE_LIST); stdcall; external kernel32;
function CreateProcessW(
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
  hPipeIn, hPipePtyIn: THandle;
  hPipePtyOut, hPipeOut: THandle;
  hPC: THandle;
  Sec: SECURITY_ATTRIBUTES;
  Size: DWORD;
  Startup: TStartupInfoExW;
  ProcInfo: PROCESS_INFORMATION;
  AttrListSize: SIZE_T;
  AttrList: PPROC_THREAD_ATTRIBUTE_LIST;
  CmdLine: UnicodeString;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead, TotalBytes: DWORD;
  Loops: Integer;
  ExitCode: DWORD;
  
begin
  try
    Writeln('=== MINIMAL CONPTY TEST ===');
    
    // Create pipes
    ZeroMemory(@Sec, SizeOf(Sec));
    Sec.nLength := SizeOf(Sec);
    Sec.bInheritHandle := True;
    
    // Pipe 1 (Parent Write -> ConPTY Read)
    // CreatePipe(Read, Write, ...)
    if not CreatePipe(hPipePtyIn, hPipeIn, @Sec, 0) then
    begin
      Writeln('CreatePipe(in) failed: ', GetLastError);
      Exit;
    end;
    Writeln('Input pipe: ParentWrite=', hPipeIn, ' ConPtyRead=', hPipePtyIn);
    
    // Pipe 2 (ConPTY Write -> Parent Read)
    if not CreatePipe(hPipeOut, hPipePtyOut, @Sec, 0) then
    begin
      Writeln('CreatePipe(out) failed: ', GetLastError);
      Exit;
    end;
    Writeln('Output pipe: ParentRead=', hPipeOut, ' ConPtyWrite=', hPipePtyOut);
    
    // Parent handles must not be inherited
    SetHandleInformation(hPipeOut, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hPipeIn, HANDLE_FLAG_INHERIT, 0);
    
    // Create ConPTY (80 cols, 25 rows)
    Size := (25 shl 16) or 80;
    Writeln('Creating ConPTY (size=', IntToHex(Size, 8), ')...');
    
    // CreatePseudoConsole(Size, hInput, hOutput, Flags, out phPC)
    // hInput: Read end of pipe
    // hOutput: Write end of pipe
    if Failed(CreatePseudoConsole(Size, hPipePtyIn, hPipePtyOut, 0, hPC)) then
    begin
      Writeln('CreatePseudoConsole failed: ', GetLastError);
      Exit;
    end;
    Writeln('ConPTY created: ', hPC);
    
    // NOTE: Handles closure delayed until after CreateProcess
    
    // Setup process creation
    ZeroMemory(@Startup, SizeOf(Startup));
    ZeroMemory(@ProcInfo, SizeOf(ProcInfo));
    
    Startup.StartupInfo.cb := SizeOf(TStartupInfoExW);
    
    AttrListSize := 0;
    InitializeProcThreadAttributeList(nil, 1, 0, AttrListSize);
    AttrList := AllocMem(AttrListSize);
    InitializeProcThreadAttributeList(AttrList, 1, 0, AttrListSize);
    UpdateProcThreadAttribute(AttrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, Pointer(hPC), SizeOf(THandle), nil, nil);
    Startup.lpAttributeList := AttrList;
    
    // Create process
    CmdLine := 'cmd.exe /c echo Hello from ConPTY!';
    UniqueString(CmdLine);
    
    Writeln('Creating process: ', CmdLine);
    
    // CRITICAL: bInheritHandles must be FALSE
    if not CreateProcessW(nil, PWideChar(CmdLine), nil, nil, False,
                         EXTENDED_STARTUPINFO_PRESENT or CREATE_UNICODE_ENVIRONMENT,
                         nil, nil, @Startup.StartupInfo, ProcInfo) then
    begin
      Writeln('CreateProcess failed: ', GetLastError);
      DeleteProcThreadAttributeList(AttrList);
      FreeMem(AttrList);
      Exit;
    end;
    
    Writeln('Process created. PID=', ProcInfo.dwProcessId);
    CloseHandle(ProcInfo.hThread);
    
    // Close child-side handles now
    CloseHandle(hPipePtyIn);
    CloseHandle(hPipePtyOut);
    
    // Read output
    Writeln;
    Writeln('=== OUTPUT START ===');
    Loops := 0;
    
    while Loops < 100 do
    begin
      // Direct ReadFile - PeekNamedPipe returns ACCESS_DENIED
      if not ReadFile(hPipeOut, Buffer, SizeOf(Buffer)-1, BytesRead, nil) then
      begin
        var Err: DWORD;
        Err := GetLastError;
        if Err = ERROR_BROKEN_PIPE then
        begin
          Writeln('[Pipe broken]');
          Break;
        end;
        Writeln('[ReadFile error: ', Err, ']');
        Break;
      end;
      
      if BytesRead > 0 then
      begin
        Writeln('[', BytesRead, ' bytes read]');
        Buffer[BytesRead] := #0;
        Write(string(Buffer));
      end;
      
      // Check if process exited
      if GetExitCodeProcess(ProcInfo.hProcess, ExitCode) and (ExitCode <> STILL_ACTIVE) then
      begin
        Writeln('[Process exited: ', ExitCode, ']');
        // Attempt one last read to clear buffer
        Break;
      end;
      
      Sleep(50);
      Inc(Loops);
    end;
    
    Writeln('=== OUTPUT END ===');
    Writeln('Loops: ', Loops);
    
    // Cleanup
    WaitForSingleObject(ProcInfo.hProcess, 2000);
    CloseHandle(ProcInfo.hProcess);
    ClosePseudoConsole(hPC);
    CloseHandle(hPipeOut);
    CloseHandle(hPipePtyIn);
    DeleteProcThreadAttributeList(AttrList);
    FreeMem(AttrList);
    
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
  
  Writeln;
  Writeln('Press Enter to exit.');
  Readln;
end.
