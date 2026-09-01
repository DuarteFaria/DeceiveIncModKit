#include <windows.h>
#include <MinHook.h>

#include <cstdint>
#include <cstring>
#include <cwchar>
#include <string>

namespace {
using WriteFileFn = BOOL(WINAPI*)(HANDLE, LPCVOID, DWORD, LPDWORD, LPOVERLAPPED);
using WriteConsoleWFn = BOOL(WINAPI*)(HANDLE, const VOID*, DWORD, LPDWORD, LPVOID);
using OutputDebugStringWFn = VOID(WINAPI*)(LPCWSTR);
using TerminateProcessFn = BOOL(WINAPI*)(HANDLE, UINT);
using ExitProcessFn = VOID(WINAPI*)(UINT);

WriteFileFn original_write_file = nullptr;
WriteConsoleWFn original_write_console = nullptr;
OutputDebugStringWFn original_output_debug = nullptr;
TerminateProcessFn original_terminate_process = nullptr;
ExitProcessFn original_exit_process = nullptr;
HANDLE log_file = INVALID_HANDLE_VALUE;
thread_local bool logging = false;

bool contains_bytes(const void* data, DWORD size, const void* needle, size_t needle_size)
{
    if (!data || needle_size == 0 || size < needle_size) return false;
    const auto* bytes = static_cast<const unsigned char*>(data);
    const auto* match = static_cast<const unsigned char*>(needle);
    for (DWORD i = 0; i <= size - needle_size; ++i) {
        if (memcmp(bytes + i, match, needle_size) == 0) return true;
    }
    return false;
}

void raw_write(const wchar_t* text)
{
    if (log_file == INVALID_HANDLE_VALUE || !text) return;
    char utf8[4096]{};
    const int count = WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8,
                                           static_cast<int>(sizeof(utf8)), nullptr, nullptr);
    if (count <= 1) return;
    DWORD written = 0;
    auto writer = original_write_file ? original_write_file : &WriteFile;
    writer(log_file, utf8, static_cast<DWORD>(count - 1), &written, nullptr);
}

void log_stack(const wchar_t* reason, UINT status)
{
    if (logging) return;
    logging = true;
    SYSTEMTIME now{};
    GetLocalTime(&now);
    wchar_t line[1024]{};
    swprintf_s(line, L"\r\n[%04u-%02u-%02u %02u:%02u:%02u.%03u] %ls status=%u pid=%lu tid=%lu\r\n",
               now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
               now.wSecond, now.wMilliseconds, reason, status,
               GetCurrentProcessId(), GetCurrentThreadId());
    raw_write(line);

    void* frames[48]{};
    const USHORT count = CaptureStackBackTrace(1, 48, frames, nullptr);
    for (USHORT i = 0; i < count; ++i) {
        MEMORY_BASIC_INFORMATION memory{};
        wchar_t module_path[MAX_PATH] = L"<unknown>";
        uintptr_t base = 0;
        if (VirtualQuery(frames[i], &memory, sizeof(memory))) {
            base = reinterpret_cast<uintptr_t>(memory.AllocationBase);
            GetModuleFileNameW(static_cast<HMODULE>(memory.AllocationBase),
                               module_path, MAX_PATH);
        }
        const wchar_t* module = wcsrchr(module_path, L'\\');
        module = module ? module + 1 : module_path;
        const auto address = reinterpret_cast<uintptr_t>(frames[i]);
        swprintf_s(line, L"  #%02u %ls+0x%llX [0x%llX]\r\n", i, module,
                   static_cast<unsigned long long>(address - base),
                   static_cast<unsigned long long>(address));
        raw_write(line);
    }
    FlushFileBuffers(log_file);
    logging = false;
}

BOOL WINAPI hooked_write_file(HANDLE file, LPCVOID buffer, DWORD bytes,
                              LPDWORD written, LPOVERLAPPED overlapped)
{
    static constexpr char ascii[] = "RequestExitWithStatus";
    static constexpr wchar_t wide[] = L"RequestExitWithStatus";
    if (contains_bytes(buffer, bytes, ascii, sizeof(ascii) - 1) ||
        contains_bytes(buffer, bytes, wide, sizeof(wide) - sizeof(wchar_t))) {
        log_stack(L"WriteFile observed RequestExitWithStatus", 3);
    }
    return original_write_file(file, buffer, bytes, written, overlapped);
}

BOOL WINAPI hooked_write_console(HANDLE output, const VOID* buffer, DWORD chars,
                                 LPDWORD written, LPVOID reserved)
{
    static constexpr wchar_t needle[] = L"RequestExitWithStatus";
    if (contains_bytes(buffer, chars * sizeof(wchar_t), needle,
                       sizeof(needle) - sizeof(wchar_t))) {
        log_stack(L"WriteConsoleW observed RequestExitWithStatus", 3);
    }
    return original_write_console(output, buffer, chars, written, reserved);
}

VOID WINAPI hooked_output_debug(LPCWSTR text)
{
    if (text && wcsstr(text, L"RequestExitWithStatus")) {
        log_stack(L"OutputDebugStringW observed RequestExitWithStatus", 3);
    }
    original_output_debug(text);
}

BOOL WINAPI hooked_terminate_process(HANDLE process, UINT code)
{
    if (code == 3) log_stack(L"TerminateProcess", code);
    return original_terminate_process(process, code);
}

VOID WINAPI hooked_exit_process(UINT code)
{
    if (code == 3) log_stack(L"ExitProcess", code);
    original_exit_process(code);
}

template<typename T>
bool hook_api(const char* name, void* replacement, T* original)
{
    return MH_CreateHookApi(L"kernel32.dll", name, replacement,
                            reinterpret_cast<void**>(original)) == MH_OK;
}

DWORD WINAPI initialize(LPVOID module_parameter)
{
    const auto module = static_cast<HMODULE>(module_parameter);
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(module, path, MAX_PATH);
    wchar_t* slash = wcsrchr(path, L'\\');
    if (slash) *(slash + 1) = L'\0';
    wcscat_s(path, L"DINativeSpectator-stage1.log");
    log_file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    raw_write(L"DINativeSpectator Stage 1 diagnostic initialized\r\n"
              L"Hooks observe logging/termination only; exit behavior is not suppressed.\r\n");

    if (MH_Initialize() != MH_OK) {
        raw_write(L"ERROR: MH_Initialize failed\r\n");
        return 1;
    }
    bool ok = true;
    ok &= hook_api("WriteFile", reinterpret_cast<void*>(&hooked_write_file), &original_write_file);
    ok &= hook_api("WriteConsoleW", reinterpret_cast<void*>(&hooked_write_console), &original_write_console);
    ok &= hook_api("OutputDebugStringW", reinterpret_cast<void*>(&hooked_output_debug), &original_output_debug);
    ok &= hook_api("TerminateProcess", reinterpret_cast<void*>(&hooked_terminate_process), &original_terminate_process);
    ok &= hook_api("ExitProcess", reinterpret_cast<void*>(&hooked_exit_process), &original_exit_process);
    if (!ok || MH_EnableHook(MH_ALL_HOOKS) != MH_OK) {
        raw_write(L"ERROR: one or more diagnostic hooks failed\r\n");
        return 2;
    }
    raw_write(L"All Stage 1 diagnostic hooks enabled\r\n");
    FlushFileBuffers(log_file);
    return 0;
}
} // namespace

extern "C" __declspec(dllexport) unsigned int DINativeSpectatorStage() noexcept
{
    return 1;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) noexcept
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        HANDLE thread = CreateThread(nullptr, 0, initialize, instance, 0, nullptr);
        if (thread) CloseHandle(thread);
    }
    return TRUE;
}
