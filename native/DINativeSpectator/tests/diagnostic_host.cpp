#include <windows.h>

#include <iostream>

int wmain(int argc, wchar_t** argv)
{
    if (argc != 2) {
        std::wcerr << L"usage: diagnostic_host.exe <DINativeSpectatorStage1.dll>\n";
        return 2;
    }
    HMODULE module = LoadLibraryW(argv[1]);
    if (!module) return 3;
    Sleep(500);
    HANDLE sink = CreateFileW(L"DINativeSpectator-diagnostic-sink.txt", GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    const char message[] = "FPlatformMisc::RequestExitWithStatus(1, 3)\r\n";
    DWORD written = 0;
    if (sink != INVALID_HANDLE_VALUE) {
        WriteFile(sink, message, sizeof(message) - 1, &written, nullptr);
        CloseHandle(sink);
    }
    Sleep(500);
    // Stage 1 hooks are deliberately process-lifetime scoped; do not FreeLibrary.
    ExitProcess(0);
}
