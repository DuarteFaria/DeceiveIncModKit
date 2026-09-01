// DINativeSpectator Stage 3: game-thread UFunction invoker + spectate tracer.
//
// Why this exists (Gate A, docs/08-native-spectator-plan.md):
//   The death-path spectator camera is client-driven and pawn-less, so the
//   game's own free<->follow toggle (ADISpectatorPawn::CheatSpectateFreeMoveSrv,
//   ADIFreeSpectator::ServerReturnToPlayer) is the only code that can rebuild the
//   client's follow-camera context. Those are server RPCs and take no parameters.
//   UE4SS reflected calls have been unreliable at the marshaling boundary, and
//   engine calls MUST run on the game thread. Hooking UObject::ProcessEvent gives
//   both: the trampoline is the exact game-thread entry the engine uses to
//   dispatch a UFunction, so re-invoking it with our own (target, func) executes
//   the RPC server-side with no marshaling and no thread hazard.
//
// The DLL is inert until UE4SS Lua drops a one-shot marker next to the server
// executable. Lua already resolves the live object and UFunction addresses with
// GetAddress(); this module only consumes them on the game thread. It never
// suppresses process exits and validates every pointer before dereferencing.

#include <windows.h>
#include <MinHook.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>

namespace {

// DeceiveIncServer-Win64-Shipping.exe, dedicatedserverpreview build 24975521.
// UObject::ProcessEvent(UFunction* Function, void* Parms). Identified as the sole
// candidate present in 2227 vtables; body saves Function in rsi and tests
// Function->FunctionFlags at [rsi+0xB0] for the RPC/net routing bit.
//
// UE4SS already hooks ProcessEvent (its Lua RegisterHook system depends on it),
// hot-patching the first 6 bytes into an `FF 25` absolute jump. We therefore
// validate identity on the STABLE tail (bytes 6..31, a distinctive prologue that
// UE4SS leaves untouched) and chain-hook in front of UE4SS via MinHook, which
// relocates the existing detour into our trampoline. kProcessEventTailSkip skips
// the region a 6-byte hot-patch overwrites.
constexpr uintptr_t kProcessEventRva = 0x191D970;
constexpr size_t kProcessEventTailSkip = 6;
constexpr unsigned char kExpectedProcessEventPrefix[] = {
    0x40, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55,
    0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xEC, 0xF0,
    0x00, 0x00, 0x00, 0x48, 0x8D, 0x6C, 0x24, 0x30,
    0x48, 0x89, 0x9D, 0x18, 0x01, 0x00, 0x00, 0x48,
};

using ProcessEventFn = void(__fastcall*)(void* self, void* function, void* parms);
ProcessEventFn original_process_event = nullptr;

wchar_t invoke_path[MAX_PATH]{};   // one-shot: request one UFunction dispatch
wchar_t trace_path[MAX_PATH]{};    // set/replace the trace watch-set
wchar_t log_path[MAX_PATH]{};

// A single queued dispatch. Filled by the watcher thread (plain integer parse,
// no engine access), drained by the ProcessEvent hook on the game thread.
struct PendingInvoke {
    uintptr_t target = 0;
    uintptr_t function = 0;
};
std::atomic<bool> invoke_pending{false};
std::atomic<bool> trace_active{false};
PendingInvoke queued_invoke;  // published before invoke_pending flips true

// The hot path (every ProcessEvent call) checks this before doing any work.
// While disarmed the hook is two relaxed atomic loads plus the tail call.
inline bool armed()
{
    return invoke_pending.load(std::memory_order_relaxed) ||
           trace_active.load(std::memory_order_relaxed);
}

// Trace watch-set: up to 8 UFunction addresses to log when they pass through
// ProcessEvent, plus an object byte-range to snapshot on each hit. Published by
// the watcher thread; read by the game-thread hook. Writes are word-aligned and
// gated by trace_generation so the hook always sees a coherent set.
constexpr int kMaxWatch = 8;
struct TraceConfig {
    uintptr_t functions[kMaxWatch]{};
    int count = 0;
    uint32_t dump_offset = 0;
    uint32_t dump_length = 0;  // 0 disables the object hexdump
};
TraceConfig trace_config;
std::atomic<uint32_t> trace_generation{0};

thread_local bool in_dispatch = false;  // reentrancy guard for our own call

void write_log(const wchar_t* message)
{
    if (!message || !log_path[0]) return;
    HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME now{};
    GetLocalTime(&now);
    wchar_t line[1200]{};
    swprintf_s(line, L"[%04u-%02u-%02u %02u:%02u:%02u.%03u] %ls\r\n",
               now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
               now.wSecond, now.wMilliseconds, message);
    char utf8[2400]{};
    const int count = WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8,
                                          static_cast<int>(sizeof(utf8)),
                                          nullptr, nullptr);
    if (count > 1) {
        DWORD written = 0;
        WriteFile(file, utf8, static_cast<DWORD>(count - 1), &written, nullptr);
    }
    CloseHandle(file);
}

// Committed, readable, and large enough to hold `size` bytes from `address`.
bool readable(uintptr_t address, size_t size)
{
    if (address == 0 || (address & 0x7) != 0) return false;  // require 8-align
    MEMORY_BASIC_INFORMATION mbi{};
    if (VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return false;
    }
    if (mbi.State != MEM_COMMIT) return false;
    const DWORD readable_flags = PAGE_READONLY | PAGE_READWRITE | PAGE_EXECUTE_READ |
                                 PAGE_EXECUTE_READWRITE | PAGE_WRITECOPY |
                                 PAGE_EXECUTE_WRITECOPY;
    if ((mbi.Protect & readable_flags) == 0) return false;
    if (mbi.Protect & PAGE_GUARD) return false;
    const auto region_end = reinterpret_cast<uintptr_t>(mbi.BaseAddress) +
                            mbi.RegionSize;
    return address + size <= region_end;
}

// A live UObject begins with a readable vtable pointer that itself points into
// committed code. This rejects stale or bogus addresses before ProcessEvent.
bool looks_like_uobject(uintptr_t address)
{
    if (!readable(address, sizeof(void*))) return false;
    const auto vtable = *reinterpret_cast<uintptr_t*>(address);
    return readable(vtable, sizeof(void*));
}

void snapshot_object(uintptr_t function, uintptr_t self)
{
    const uint32_t generation = trace_generation.load(std::memory_order_acquire);
    if (generation == 0) return;
    const TraceConfig config = trace_config;  // copied under a stable generation
    if (trace_generation.load(std::memory_order_acquire) != generation) return;

    bool watched = false;
    for (int i = 0; i < config.count; ++i) {
        if (config.functions[i] == function) { watched = true; break; }
    }
    if (!watched) return;

    wchar_t line[1600]{};
    int written = swprintf_s(line, L"trace func=0x%llX self=0x%llX",
                             static_cast<unsigned long long>(function),
                             static_cast<unsigned long long>(self));
    if (config.dump_length > 0 && config.dump_length <= 256 &&
        readable(self + config.dump_offset, config.dump_length)) {
        const auto* bytes =
            reinterpret_cast<const unsigned char*>(self + config.dump_offset);
        written += swprintf_s(line + written, 64, L" dump@0x%X:", config.dump_offset);
        for (uint32_t i = 0; i < config.dump_length && written < 1500; ++i) {
            written += swprintf_s(line + written, 4, L"%02X", bytes[i]);
        }
    }
    write_log(line);
}

void drain_invoke()
{
    if (!invoke_pending.exchange(false, std::memory_order_acquire)) return;
    const PendingInvoke request = queued_invoke;

    if (!looks_like_uobject(request.target) ||
        !readable(request.function, sizeof(void*))) {
        wchar_t line[256]{};
        swprintf_s(line, L"invoke REFUSED: unreadable target=0x%llX func=0x%llX",
                   static_cast<unsigned long long>(request.target),
                   static_cast<unsigned long long>(request.function));
        write_log(line);
        return;
    }

    // All three Gate A targets are parameterless; a zeroed buffer safely covers
    // ProcessEvent copying ParmsSize bytes for any no-parameter UFunction.
    alignas(16) unsigned char parms[256]{};
    wchar_t line[256]{};
    swprintf_s(line, L"invoke dispatch target=0x%llX func=0x%llX (game thread tid=%lu)",
               static_cast<unsigned long long>(request.target),
               static_cast<unsigned long long>(request.function),
               GetCurrentThreadId());
    write_log(line);

    in_dispatch = true;
    original_process_event(reinterpret_cast<void*>(request.target),
                           reinterpret_cast<void*>(request.function), parms);
    in_dispatch = false;

    write_log(L"invoke complete");
}

void __fastcall hooked_process_event(void* self, void* function, void* parms)
{
    // Fast disarmed path: this is the engine's hottest function, so do nothing
    // but forward until an invoke/trace is actually armed.
    if (in_dispatch || !armed()) {
        original_process_event(self, function, parms);
        return;
    }

    snapshot_object(reinterpret_cast<uintptr_t>(function),
                    reinterpret_cast<uintptr_t>(self));
    original_process_event(self, function, parms);

    // Pump queued work AFTER the real call returns, so a queued dispatch never
    // nests inside an unrelated engine call frame.
    if (invoke_pending.load(std::memory_order_relaxed)) {
        drain_invoke();
    }
}

// -- watcher thread: plain file/integer parsing only, never touches the engine --

bool read_small_file(const wchar_t* path, char* buffer, DWORD capacity)
{
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD read = 0;
    const BOOL ok = ReadFile(file, buffer, capacity - 1, &read, nullptr);
    CloseHandle(file);
    if (!ok) return false;
    buffer[read] = '\0';
    return true;
}

// Parse "key=0x..." (hex, 0x optional) following the first occurrence of key.
bool parse_hex_field(const char* text, const char* key, uintptr_t* out)
{
    const char* at = strstr(text, key);
    if (!at) return false;
    at += strlen(key);
    if (*at == '=') ++at;
    return sscanf_s(at, "%llx", reinterpret_cast<unsigned long long*>(out)) == 1;
}

void poll_invoke()
{
    if (GetFileAttributesW(invoke_path) == INVALID_FILE_ATTRIBUTES) return;
    char text[512]{};
    const bool read = read_small_file(invoke_path, text, sizeof(text));
    DeleteFileW(invoke_path);  // strictly one-shot
    if (!read) {
        write_log(L"invoke marker unreadable; discarded");
        return;
    }
    PendingInvoke request;
    if (!parse_hex_field(text, "target", &request.target) ||
        !parse_hex_field(text, "func", &request.function)) {
        write_log(L"invoke marker missing target/func; discarded");
        return;
    }
    queued_invoke = request;
    invoke_pending.store(true, std::memory_order_release);
    wchar_t line[256]{};
    swprintf_s(line, L"invoke queued target=0x%llX func=0x%llX",
               static_cast<unsigned long long>(request.target),
               static_cast<unsigned long long>(request.function));
    write_log(line);
}

void poll_trace()
{
    if (GetFileAttributesW(trace_path) == INVALID_FILE_ATTRIBUTES) return;
    char text[2048]{};
    const bool read = read_small_file(trace_path, text, sizeof(text));
    DeleteFileW(trace_path);
    if (!read) return;

    TraceConfig config;
    parse_hex_field(text, "dumpoff", reinterpret_cast<uintptr_t*>(&config.dump_offset));
    uintptr_t dump_length = 0;
    if (parse_hex_field(text, "dumplen", &dump_length)) {
        config.dump_length = static_cast<uint32_t>(dump_length > 256 ? 256 : dump_length);
    }
    // Collect every "func=0x..." occurrence, up to kMaxWatch.
    const char* cursor = text;
    while (config.count < kMaxWatch) {
        const char* at = strstr(cursor, "func");
        if (!at) break;
        uintptr_t value = 0;
        if (parse_hex_field(at, "func", &value) && value != 0) {
            config.functions[config.count++] = value;
        }
        cursor = at + 4;
    }

    trace_generation.fetch_add(1, std::memory_order_acq_rel);  // block readers
    trace_config = config;
    trace_generation.fetch_add(1, std::memory_order_release);  // republish (even)
    trace_active.store(config.count > 0, std::memory_order_release);
    wchar_t line[128]{};
    swprintf_s(line, L"trace watch-set updated functions=%d dump@0x%X len=%u",
               config.count, config.dump_offset, config.dump_length);
    write_log(line);
}

DWORD WINAPI watcher(LPVOID)
{
    for (;;) {
        poll_invoke();
        poll_trace();
        Sleep(150);
    }
}

bool build_server_paths()
{
    wchar_t executable[MAX_PATH]{};
    if (!GetModuleFileNameW(nullptr, executable, MAX_PATH)) return false;
    wchar_t* slash = wcsrchr(executable, L'\\');
    if (!slash) return false;
    *(slash + 1) = L'\0';
    auto build = [&](wchar_t* dest, const wchar_t* leaf) {
        wcscpy_s(dest, MAX_PATH, executable);
        wcscat_s(dest, MAX_PATH, leaf);
    };
    build(invoke_path, L"DINativeSpectator.invoke");
    build(trace_path, L"DINativeSpectator.trace");
    build(log_path, L"DINativeSpectator-stage3.log");
    return true;
}

DWORD WINAPI initialize(LPVOID)
{
    if (!build_server_paths()) return 1;
    write_log(L"Stage 3 invoker initializing");

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
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(image + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE ||
        kProcessEventRva + sizeof(kExpectedProcessEventPrefix) >
            nt->OptionalHeader.SizeOfImage) {
        write_log(L"ERROR: executable image is not the supported server build");
        return 3;
    }
    auto* target = image + kProcessEventRva;
    // Validate identity on the stable tail only. UE4SS hot-patches the first
    // bytes into an `FF 25` jump, so the head legitimately differs at runtime;
    // the tail (a distinctive prologue) is left intact and uniquely identifies
    // ProcessEvent for this build.
    if (memcmp(target + kProcessEventTailSkip,
               kExpectedProcessEventPrefix + kProcessEventTailSkip,
               sizeof(kExpectedProcessEventPrefix) - kProcessEventTailSkip) != 0) {
        write_log(L"ERROR: ProcessEvent tail signature mismatch; hook refused");
        return 3;
    }
    if (target[0] == 0xFF && target[1] == 0x25) {
        write_log(L"ProcessEvent already detoured (expected: UE4SS); chain-hooking");
    } else if (memcmp(target, kExpectedProcessEventPrefix,
                      kProcessEventTailSkip) == 0) {
        write_log(L"ProcessEvent prologue intact; hooking");
    } else {
        write_log(L"ProcessEvent head differs from a known detour; chain-hooking anyway");
    }
    if (MH_Initialize() != MH_OK) {
        write_log(L"ERROR: MH_Initialize failed");
        return 4;
    }
    if (MH_CreateHook(target, reinterpret_cast<void*>(&hooked_process_event),
                      reinterpret_cast<void**>(&original_process_event)) != MH_OK) {
        write_log(L"ERROR: ProcessEvent hook creation failed");
        return 5;
    }
    if (MH_EnableHook(target) != MH_OK) {
        write_log(L"ERROR: ProcessEvent hook enable failed");
        return 6;
    }

    HANDLE thread = CreateThread(nullptr, 0, watcher, nullptr, 0, nullptr);
    if (thread) CloseHandle(thread);
    write_log(L"Stage 3 invoker enabled; dormant until invoke/trace marker");
    return 0;
}

}  // namespace

extern "C" __declspec(dllexport) unsigned int DINativeSpectatorStage() noexcept
{
    return 3;
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
