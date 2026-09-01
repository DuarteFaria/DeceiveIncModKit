#include <windows.h>
#include <iostream>

using StageFn = unsigned int (*)();

int wmain(int argc, wchar_t** argv)
{
    if (argc != 2) {
        std::wcerr << L"usage: load_cycle.exe <DINativeSpectator.dll>\n";
        return 2;
    }
    for (int cycle = 1; cycle <= 3; ++cycle) {
        HMODULE module = LoadLibraryW(argv[1]);
        if (!module) return 10 + cycle;
        auto stage = reinterpret_cast<StageFn>(GetProcAddress(module, "DINativeSpectatorStage"));
        if (!stage || stage() != 0) return 20 + cycle;
        if (!FreeLibrary(module)) return 30 + cycle;
        std::wcout << L"load/unload cycle " << cycle << L" ok\n";
    }
    return 0;
}
