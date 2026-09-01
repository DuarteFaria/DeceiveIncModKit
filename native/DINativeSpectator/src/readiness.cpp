#include <windows.h>
#include <MinHook.h>

#include <cstdint>
#include <cstring>
#include <cwchar>

namespace {
// DeceiveIncServer-Win64-Shipping.exe, dedicatedserverpreview build 24975521.
// ADeceiveIncGameModeBase inherits AGameMode's compact readiness implementation.
constexpr uintptr_t kReadyToStartMatchImplementationRva = 0x2D999F0;
constexpr size_t kNumPlayersOffset = 0x2D0;
constexpr size_t kNumBotsOffset = 0x2D4;
constexpr unsigned char kExpectedReadyPrefix[] = {
    0xF6, 0x81, 0xC8, 0x02, 0x00, 0x00, 0x01, 0x75,
    0x23, 0x48, 0x8B, 0x05, 0x40, 0x71, 0x83, 0x02,
    0x48, 0x39, 0x81, 0xC0, 0x02, 0x00, 0x00, 0x75,
    0x13, 0x8B, 0x81, 0xD4, 0x02, 0x00, 0x00, 0x03,
    0x81, 0xD0, 0x02, 0x00, 0x00, 0x85, 0xC0, 0x7E,
    0x03, 0xB0, 0x01, 0xC3, 0x32, 0xC0, 0xC3,
};

using ReadyToStartMatchFn = bool(__fastcall*)(void* game_mode);
ReadyToStartMatchFn original_ready_to_start_match = nullptr;
wchar_t marker_path[MAX_PATH]{};
wchar_t log_path[MAX_PATH]{};

void write_log(const wchar_t* message)
{
    if (!message || !log_path[0]) return;
    HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME now{};
    GetLocalTime(&now);
    wchar_t line[1024]{};
    swprintf_s(line, L"[%04u-%02u-%02u %02u:%02u:%02u.%03u] %ls\r\n",
               now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
               now.wSecond, now.wMilliseconds, message);
    char utf8[2048]{};
    const int count = WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8,
                                           static_cast<int>(sizeof(utf8)),
                                           nullptr, nullptr);
    if (count > 1) {
        DWORD written = 0;
        WriteFile(file, utf8, static_cast<DWORD>(count - 1), &written, nullptr);
    }
    CloseHandle(file);
}

bool marker_is_armed()
{
    return GetFileAttributesW(marker_path) != INVALID_FILE_ATTRIBUTES;
}

bool __fastcall hooked_ready_to_start_match(void* game_mode)
{
    if (!game_mode || !marker_is_armed()) {
        return original_ready_to_start_match(game_mode);
    }

    auto* bytes = static_cast<unsigned char*>(game_mode);
    auto* num_players = reinterpret_cast<int32_t*>(bytes + kNumPlayersOffset);
    auto* num_bots = reinterpret_cast<int32_t*>(bytes + kNumBotsOffset);

    // Preserve every stock readiness guard. Only supply the single count that
    // a faction-210 connection intentionally does not contribute.
    if (*num_players + *num_bots > 0) {
        return original_ready_to_start_match(game_mode);
    }

    const int32_t saved_num_players = *num_players;
    *num_players = 1;
    const bool ready = original_ready_to_start_match(game_mode);

    if (ready) {
        // Keep the synthetic human count for this GameMode instance. The
        // dedicated-server abandonment watchdog sums human counters rather
        // than the replicated PlayerArray, so restoring zero makes it discard
        // a healthy bot match after 20 seconds. Map travel destroys this
        // GameMode and therefore clears the synthetic count naturally.
        DeleteFileW(marker_path); // one-shot; never survives map travel
        write_log(L"readiness override consumed: synthetic human count retained for watchdog accounting");
    } else {
        *num_players = saved_num_players;
    }
    return ready;
}

bool build_server_paths()
{
    wchar_t executable[MAX_PATH]{};
    if (!GetModuleFileNameW(nullptr, executable, MAX_PATH)) return false;
    wchar_t* slash = wcsrchr(executable, L'\\');
    if (!slash) return false;
    *(slash + 1) = L'\0';
    wcscpy_s(marker_path, executable);
    wcscat_s(marker_path, L"DINativeSpectator.readiness-override");
    wcscpy_s(log_path, executable);
    wcscat_s(log_path, L"DINativeSpectator-stage2.log");
    return true;
}

DWORD WINAPI initialize(LPVOID)
{
    if (!build_server_paths()) return 1;
    write_log(L"Stage 2 readiness hook initializing");

    HMODULE executable = GetModuleHandleW(nullptr);
    if (!executable) {
        write_log(L"ERROR: server executable module unavailable");
        return 2;
    }
    auto* image = reinterpret_cast<unsigned char*>(executable);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(image);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
        write_log(L"ERROR: invalid executable DOS header");
        return 3;
    }
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(
        image + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE ||
        kReadyToStartMatchImplementationRva + sizeof(kExpectedReadyPrefix) >
            nt->OptionalHeader.SizeOfImage) {
        write_log(L"ERROR: executable image is not the supported server build");
        return 3;
    }
    auto* target = image +
                   kReadyToStartMatchImplementationRva;
    if (memcmp(target, kExpectedReadyPrefix, sizeof(kExpectedReadyPrefix)) != 0) {
        write_log(L"ERROR: ReadyToStartMatch signature mismatch; hook refused");
        return 3;
    }
    if (MH_Initialize() != MH_OK) {
        write_log(L"ERROR: MH_Initialize failed");
        return 4;
    }
    const MH_STATUS created = MH_CreateHook(
        target, reinterpret_cast<void*>(&hooked_ready_to_start_match),
        reinterpret_cast<void**>(&original_ready_to_start_match));
    if (created != MH_OK) {
        write_log(L"ERROR: ReadyToStartMatch hook creation failed");
        return 5;
    }
    if (MH_EnableHook(target) != MH_OK) {
        write_log(L"ERROR: ReadyToStartMatch hook enable failed");
        return 6;
    }
    write_log(L"Stage 2 readiness hook enabled; dormant until faction-210 marker");
    return 0;
}
} // namespace

extern "C" __declspec(dllexport) unsigned int DINativeSpectatorStage() noexcept
{
    return 2;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) noexcept
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        HANDLE thread = CreateThread(nullptr, 0, initialize, nullptr, 0, nullptr);
        if (thread) CloseHandle(thread);
    }
    return TRUE;
}
