#include <windows.h>

// Stage 0 intentionally has no engine hooks, background threads, configuration,
// or gameplay behavior. The export exists only for an isolated load/unload test.
extern "C" __declspec(dllexport) unsigned int DINativeSpectatorStage() noexcept
{
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) noexcept
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
