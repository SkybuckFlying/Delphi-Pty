// Minimal ConPTY test - Microsoft reference implementation
#include <windows.h>
#include <stdio.h>

int main() {
    HRESULT hr;
    HANDLE hPipeIn, hPipeOut;
    HANDLE hPipePtyIn, hPipePtyOut;
    HANDLE hPC = 0;
    
    // Create pipes
    SECURITY_ATTRIBUTES sa = { sizeof(SECURITY_ATTRIBUTES), NULL, TRUE };
    
    // Pipe 1 (Parent Write -> ConPTY Read)
    if (!CreatePipe(&hPipePtyIn, &hPipeIn, &sa, 0)) {
        printf("CreatePipe(in) failed: %d\n", GetLastError());
        return 1;
    }
    
    // Pipe 2 (ConPTY Write -> Parent Read)
    if (!CreatePipe(&hPipeOut, &hPipePtyOut, &sa, 0)) {
        printf("CreatePipe(out) failed: %d\n", GetLastError());
        return 1;
    }
    
    printf("Pipes created:\n");
    printf("  hPipeIn (ParentWrite)=%p hPipePtyIn (ConPtyRead)=%p\n", hPipeIn, hPipePtyIn);
    printf("  hPipePtyOut (ConPtyWrite)=%p hPipeOut (ParentRead)=%p\n", hPipePtyOut, hPipeOut);
    
    // Make sure parent handles are not inherited
    SetHandleInformation(hPipeOut, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hPipeIn, HANDLE_FLAG_INHERIT, 0);
    
    // Create ConPTY
    COORD size = { 80, 25 };
    HRESULT hRes = CreatePseudoConsole(size, hPipePtyIn, hPipePtyOut, 0, &hPC);
    if (FAILED(hRes)) {
        printf("CreatePseudoConsole failed: 0x%08X\n", hRes);
        return 1;
    }
    
    printf("ConPTY created: %p\n", hPC);
    
    // Close the PTY-side handles (child will inherit via ConPTY)
    CloseHandle(hPipeIn);
    CloseHandle(hPipePtyOut);
    
    // Setup startup info
    STARTUPINFOEXW siEx = {};
    siEx.StartupInfo.cb = sizeof(STARTUPINFOEXW);
    siEx.StartupInfo.dwFlags = STARTF_USESHOWWINDOW;
    siEx.StartupInfo.wShowWindow = SW_HIDE;
    
    // Allocate attribute list
    SIZE_T attrSize = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attrSize);
    siEx.lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)malloc(attrSize);
    InitializeProcThreadAttributeList(siEx.lpAttributeList, 1, 0, &attrSize);
    UpdateProcThreadAttribute(siEx.lpAttributeList, 0, 
                             PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                             hPC, sizeof(HPCON), NULL, NULL);
    
    // Create process
    PROCESS_INFORMATION pi = {};
    wchar_t cmd[] = L"cmd.exe /c echo Hello from ConPTY!";
    
    printf("Creating process: %ls\n", cmd);
    
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE,
                       EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                       NULL, NULL, &siEx.StartupInfo, &pi)) {
        printf("CreateProcess failed: %d\n", GetLastError());
        return 1;
    }
    
    printf("Process created. PID=%d\n", pi.dwProcessId);
    CloseHandle(pi.hThread);
    
    // Read output
    printf("\n=== OUTPUT START ===\n");
    char buffer[4096];
    DWORD bytesRead;
    DWORD totalBytes;
    int loops = 0;
    
    while (loops < 100) {  // Max 100 iterations
        // Check if data available
        if (!PeekNamedPipe(hPipeOut, NULL, 0, NULL, &totalBytes, NULL)) {
            DWORD err = GetLastError();
            if (err == ERROR_BROKEN_PIPE) {
                printf("[Pipe broken]\n");
                break;
            }
            printf("[PeekNamedPipe error: %d]\n", err);
            break;
        }
        
        if (totalBytes > 0) {
            printf("[%d bytes available]\n", totalBytes);
            if (ReadFile(hPipeOut, buffer, sizeof(buffer)-1, &bytesRead, NULL)) {
                buffer[bytesRead] = 0;
                printf("%s", buffer);
                fflush(stdout);
            }
        }
        
        // Check if process exited
        DWORD exitCode;
        if (GetExitCodeProcess(pi.hProcess, &exitCode) && exitCode != STILL_ACTIVE) {
            printf("[Process exited with code %d]\n", exitCode);
            // Continue reading until pipe is empty
            if (totalBytes == 0) break;
        }
        
        Sleep(50);
        loops++;
    }
    
    printf("=== OUTPUT END ===\n");
    printf("Loops: %d\n", loops);
    
    // Cleanup
    WaitForSingleObject(pi.hProcess, 2000);
    CloseHandle(pi.hProcess);
    ClosePseudoConsole(hPC);
    CloseHandle(hPipeOut);
    CloseHandle(hPipePtyIn);
    DeleteProcThreadAttributeList(siEx.lpAttributeList);
    free(siEx.lpAttributeList);
    
    printf("\nPress Enter to exit...");
    getchar();
    return 0;
}
