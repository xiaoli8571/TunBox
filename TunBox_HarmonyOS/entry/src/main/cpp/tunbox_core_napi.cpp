#include "napi/native_api.h"
#include "hilog/log.h"
#include "libgojni.h"
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits>
#include <mutex>
#include <string>
#include <unistd.h>
#include <vector>

#ifndef NM_FLAG_NONE
#define NM_FLAG_NONE 0
#endif

static constexpr const char *CORE_LIB_PATH = "libgojni.so";
static constexpr const char *NAPI_LOG_TAG = "TunBoxCoreNapi";
static constexpr size_t MAX_CONFIG_PATH_BYTES = 4096;
static constexpr size_t MAX_PROFILE_BYTES = 8 * 1024 * 1024;

using InitFn = decltype(&TunBoxInit);
using StartFn = decltype(&TunBoxStart);
using InitProtectFn = decltype(&TunBoxInitProtect);
using SetProtectResultFn = decltype(&TunBoxSetProtectResult);
using SetProtectResultForFdFn = void (*)(long long, long long, int);
using StopFn = decltype(&TunBoxStop);
using AliveFn = decltype(&TunBoxIsRunning);
using VersionFn = decltype(&TunBoxVersion);
using LastErrorFn = decltype(&TunBoxLastError);

static std::mutex g_core_mutex;
static void *g_core_handle = nullptr;
static InitFn g_init = nullptr;
static StartFn g_start = nullptr;
static InitProtectFn g_init_protect = nullptr;
static SetProtectResultFn g_set_protect_result = nullptr;
static SetProtectResultForFdFn g_set_protect_result_for_fd = nullptr;
static StopFn g_stop = nullptr;
static AliveFn g_alive = nullptr;
static VersionFn g_version = nullptr;
static LastErrorFn g_last_error = nullptr;
static std::atomic<int> g_tun_fd{-1};
static std::atomic<int> g_protect_read_fd{-1};
static std::atomic<bool> g_running{false};

static void closeProtectReadFd()
{
    const int fd = g_protect_read_fd.exchange(-1);
    if (fd >= 0) {
        close(fd);
    }
}

// g_tun_fd owns a private CLOEXEC duplicate of the platform TUN descriptor.
// VpnConnection remains the sole owner of the original descriptor returned by create().
static void closeTunTemplateFd()
{
    const int fd = g_tun_fd.exchange(-1);
    if (fd >= 0) {
        close(fd);
    }
}

static bool loadCore()
{
    std::lock_guard<std::mutex> lock(g_core_mutex);
    if (g_core_handle != nullptr) {
        return g_init != nullptr && g_start != nullptr && g_init_protect != nullptr &&
            g_set_protect_result != nullptr && g_set_protect_result_for_fd != nullptr &&
            g_stop != nullptr && g_alive != nullptr &&
            g_version != nullptr && g_last_error != nullptr;
    }

    void *handle = dlopen(CORE_LIB_PATH, RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, NAPI_LOG_TAG, "core library load failed");
        return false;
    }

    InitFn init = reinterpret_cast<InitFn>(dlsym(handle, "TunBoxInit"));
    StartFn start = reinterpret_cast<StartFn>(dlsym(handle, "TunBoxStart"));
    InitProtectFn initProtect = reinterpret_cast<InitProtectFn>(dlsym(handle, "TunBoxInitProtect"));
    SetProtectResultFn setProtectResult =
        reinterpret_cast<SetProtectResultFn>(dlsym(handle, "TunBoxSetProtectResult"));
    SetProtectResultForFdFn setProtectResultForFd =
        reinterpret_cast<SetProtectResultForFdFn>(dlsym(handle, "TunBoxSetProtectResultForFd"));
    StopFn stop = reinterpret_cast<StopFn>(dlsym(handle, "TunBoxStop"));
    AliveFn alive = reinterpret_cast<AliveFn>(dlsym(handle, "TunBoxIsRunning"));
    VersionFn version = reinterpret_cast<VersionFn>(dlsym(handle, "TunBoxVersion"));
    LastErrorFn lastError = reinterpret_cast<LastErrorFn>(dlsym(handle, "TunBoxLastError"));

    if (init == nullptr || start == nullptr || initProtect == nullptr || setProtectResult == nullptr ||
        setProtectResultForFd == nullptr ||
        stop == nullptr || alive == nullptr || version == nullptr || lastError == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, NAPI_LOG_TAG, "core library ABI validation failed");
        dlclose(handle);
        return false;
    }

    init(const_cast<char *>("/data/storage/el2/base/haps/entry/cache"),
        const_cast<char *>("mihomo_config.yaml"));
    g_init = init;
    g_start = start;
    g_init_protect = initProtect;
    g_set_protect_result = setProtectResult;
    g_set_protect_result_for_fd = setProtectResultForFd;
    g_stop = stop;
    g_alive = alive;
    g_version = version;
    g_last_error = lastError;
    g_core_handle = handle;
    return true;
}

static bool getConfigPath(napi_env env, napi_value value, std::string &path)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok ||
        length == 0 || length > MAX_CONFIG_PATH_BYTES) {
        return false;
    }
    std::vector<char> buffer(length + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied) != napi_ok ||
        copied != length || std::strlen(buffer.data()) != length) {
        return false;
    }
    path.assign(buffer.data(), length);
    return true;
}

struct StartCoreWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string configPath;
    int tunFd = -1;
    bool ok = false;
};

struct ProfileWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string text;
    std::string result;
};

static void ExecuteProfile(napi_env env, void *data)
{
    auto *work = static_cast<ProfileWork *>(data);
    if (!loadCore()) { return; }
    auto prepare = reinterpret_cast<char *(*)(char *)>(dlsym(g_core_handle, "TunBoxPrepareProfile"));
    auto release = reinterpret_cast<void (*)(char *)>(dlsym(g_core_handle, "TunBoxFreeString"));
    if (prepare == nullptr || release == nullptr) { return; }
    char *result = prepare(const_cast<char *>(work->text.c_str()));
    if (result != nullptr) { work->result = result; release(result); }
}

static void CompleteProfile(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<ProfileWork *>(data);
    napi_value result;
    napi_create_string_utf8(env, work->result.c_str(), work->result.size(), &result);
    napi_resolve_deferred(env, work->deferred, result);
    napi_delete_async_work(env, work->work);
    delete work;
}

static napi_value PrepareProfile(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    size_t length = 0;
    if (argc != 1 || napi_get_value_string_utf8(env, argv[0], nullptr, 0, &length) != napi_ok ||
        length == 0 || length > MAX_PROFILE_BYTES) {
        napi_throw_error(env, nullptr, "Profile size out of range");
        return nullptr;
    }
    auto *work = new ProfileWork();
    std::vector<char> buffer(length + 1);
    napi_get_value_string_utf8(env, argv[0], buffer.data(), buffer.size(), &length);
    work->text.assign(buffer.data(), length);
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "PrepareProfile", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, ExecuteProfile, CompleteProfile, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        napi_value message;
        napi_create_string_utf8(env, "Profile worker unavailable", NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, work->deferred, message);
        if (work->work != nullptr) { napi_delete_async_work(env, work->work); }
        delete work;
    }
    return promise;
}

static void ExecuteStartCore(napi_env env, void *data)
{
    (void)env;
    auto *work = static_cast<StartCoreWork *>(data);
    if (work == nullptr || !loadCore() || g_start == nullptr) {
        return;
    }
    const int rc = g_start(const_cast<char *>(work->configPath.c_str()),
        static_cast<long long>(work->tunFd));
    work->ok = rc == 0;
    g_running.store(work->ok);
    OH_LOG_Print(LOG_APP, work->ok ? LOG_INFO : LOG_ERROR, 0, NAPI_LOG_TAG,
        "core start completed, result=%d", rc);
}

static void CompleteStartCore(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<StartCoreWork *>(data);
    if (work == nullptr) {
        return;
    }
    napi_value result;
    napi_get_boolean(env, status == napi_ok && work->ok, &result);
    napi_resolve_deferred(env, work->deferred, result);
    if (work->work != nullptr) {
        napi_delete_async_work(env, work->work);
    }
    delete work;
}

static napi_value StartCore(napi_env env, napi_callback_info info)
{
    napi_value promise;
    napi_deferred deferred;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        return nullptr;
    }

    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string configPath;
    int tunFd = -1;
    // Headless latency testing intentionally starts mihomo without a TUN fd and
    // passes -1. Reject values below -1, while preserving validation for both
    // normal VPN startup (fd >= 0) and headless startup (fd == -1).
    if (argc < 2 || !getConfigPath(env, args[0], configPath) ||
        napi_get_value_int32(env, args[1], &tunFd) != napi_ok || tunFd < -1) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        napi_resolve_deferred(env, deferred, result);
        return promise;
    }

    auto *work = new StartCoreWork();
    work->deferred = deferred;
    work->configPath = configPath;
    if (tunFd >= 0) {
        // Never pass either the platform-owned descriptor or our reusable template
        // directly to Go/mihomo. Each start receives a fresh CLOEXEC duplicate whose
        // ownership is transferred to the core listener for that Core generation.
        const int templateFd = g_tun_fd.load();
        if (templateFd < 0) {
            delete work;
            napi_value result;
            napi_get_boolean(env, false, &result);
            napi_resolve_deferred(env, deferred, result);
            return promise;
        }
        work->tunFd = fcntl(templateFd, F_DUPFD_CLOEXEC, 0);
        if (work->tunFd < 0) {
            delete work;
            napi_value result;
            napi_get_boolean(env, false, &result);
            napi_resolve_deferred(env, deferred, result);
            return promise;
        }
    } else {
        work->tunFd = -1;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "TunBoxStartCore", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(env, nullptr, resourceName, ExecuteStartCore,
        CompleteStartCore, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        // 异步任务尚未交给 Go/mihomo，startCore 为本次启动创建的 TUN 副本
        // 仍归 NAPI 所有，必须在入队失败时关闭，避免每次失败泄漏一个 fd。
        if (work->tunFd >= 0) {
            close(work->tunFd);
            work->tunFd = -1;
        }
        delete work;
        napi_value result;
        napi_get_boolean(env, false, &result);
        napi_resolve_deferred(env, deferred, result);
    }
    return promise;
}

static napi_value InitProtect(napi_env env, napi_callback_info info)
{
    int fd = -1;
    if (loadCore() && g_init_protect != nullptr) {
        closeProtectReadFd();
        const long long rawFd = g_init_protect();
        if (rawFd >= 0 && rawFd <= std::numeric_limits<int>::max()) {
            fd = static_cast<int>(rawFd);
            const int flags = fcntl(fd, F_GETFL, 0);
            if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
                close(fd);
                fd = -1;
            } else {
                g_protect_read_fd.store(fd);
            }
        }
    }
    napi_value result;
    napi_create_int32(env, fd, &result);
    return result;
}

static napi_value ReadProtectSocketFd(napi_env env, napi_callback_info info)
{
    int socketFd = -1;
    long long seq = -1;
    const int pipeFd = g_protect_read_fd.load();
    if (pipeFd >= 0) {
        // 8-byte record: fd(u32 LE) + seq(u32 LE)
        uint8_t encoded[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        const ssize_t count = read(pipeFd, encoded, sizeof(encoded));
        if (count == static_cast<ssize_t>(sizeof(encoded))) {
            const uint32_t value = static_cast<uint32_t>(encoded[0]) |
                (static_cast<uint32_t>(encoded[1]) << 8U) |
                (static_cast<uint32_t>(encoded[2]) << 16U) |
                (static_cast<uint32_t>(encoded[3]) << 24U);
            seq = static_cast<long long>(encoded[4]) |
                (static_cast<long long>(encoded[5]) << 8LL) |
                (static_cast<long long>(encoded[6]) << 16LL) |
                (static_cast<long long>(encoded[7]) << 24LL);
            if (value <= static_cast<uint32_t>(std::numeric_limits<int>::max())) {
                socketFd = static_cast<int>(value);
            }
        } else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            closeProtectReadFd();
        }
    }
    napi_value result;
    napi_create_array_with_length(env, 2, &result);
    napi_value fdValue;
    napi_create_int32(env, socketFd, &fdValue);
    napi_set_element(env, result, 0, fdValue);
    napi_value seqValue;
    napi_create_int64(env, seq, &seqValue);
    napi_set_element(env, result, 1, seqValue);
    return result;
}

static napi_value SetProtectResult(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool ok = false;
    if (argc >= 1 && napi_get_value_bool(env, args[0], &ok) == napi_ok &&
        loadCore() && g_set_protect_result != nullptr) {
        g_set_protect_result(ok ? 1 : 0);
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value SetProtectResultForFd(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int fd = -1;
    int64_t seq = -1;
    bool ok = false;
    if (argc >= 3 && napi_get_value_int32(env, args[0], &fd) == napi_ok &&
        napi_get_value_int64(env, args[1], &seq) == napi_ok &&
        napi_get_value_bool(env, args[2], &ok) == napi_ok &&
        loadCore() && g_set_protect_result_for_fd != nullptr) {
        g_set_protect_result_for_fd(static_cast<long long>(fd), static_cast<long long>(seq), ok ? 1 : 0);
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static void ExecuteStopCore(napi_env env, void *data)
{
    closeProtectReadFd();
    if (loadCore() && g_stop != nullptr) {
        g_stop();
    }
    // Keep the private template descriptor across a Core-only restart. recoverCore()
    // calls stopCore() followed by startCore() without re-attaching the platform TUN;
    // clearing it here would make every in-place recovery fail. It is replaced and
    // closed by the next attachTunFd call, or released with the process at final exit.
    g_running.store(false);
}

static void CompleteStopCore(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<StartCoreWork *>(data);
    napi_value value;
    napi_get_undefined(env, &value);
    napi_resolve_deferred(env, work->deferred, value);
    napi_delete_async_work(env, work->work);
    delete work;
}

static napi_value StopCore(napi_env env, napi_callback_info info)
{
    auto *work = new StartCoreWork();
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "StopCore", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, ExecuteStopCore, CompleteStopCore, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        napi_value message;
        napi_create_string_utf8(env, "Stop worker unavailable", NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, work->deferred, message);
        if (work->work != nullptr) { napi_delete_async_work(env, work->work); }
        delete work;
    }
    return promise;
}

static napi_value IsCoreAlive(napi_env env, napi_callback_info info)
{
    // 2026-10-20 自动断开整改：**热路径不再同步调用 Go 侧的 g_alive()**。
    //
    // g_alive() → bridge.IsRunning() → coreMu.Lock()。而 Start()/Stop() 全程持有
    // coreMu（内含 hub.ApplyConfig 与 executor.Shutdown，可达秒级），于是 ArkTS
    // 线程上的 isCoreAlive() 会被阻塞到内核操作结束 —— 扩展进程的定时器链因此
    // 停摆 → 跨进程存活租约停更 → UI 侧 15s 陈旧窗口判死 → 拆隧道重连。
    // 真机表现为 27~36s 一轮的"自己把自己断掉"。
    //
    // g_running 是 Start/Stop 在 C++ 侧维护的原子量，与 Go 侧 running 标志在稳态下
    // 等价（Go 侧 running 同样不会在内核意外死亡时自动复位，两者都只反映
    // "启动成功且尚未停止"），但读取是纳秒级且**绝不与任何写者互斥**。
    const bool alive = loadCore() && g_running.load();
    napi_value result;
    napi_get_boolean(env, alive, &result);
    return result;
}

static napi_value CoreVersion(napi_env env, napi_callback_info info)
{
    const char *value = "unknown";
    if (loadCore() && g_version != nullptr) {
        const char *candidate = g_version();
        if (candidate != nullptr) {
            value = candidate;
        }
    }
    napi_value result;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value LastError(napi_env env, napi_callback_info info)
{
    const char *value = "";
    if (loadCore() && g_last_error != nullptr) {
        const char *candidate = g_last_error();
        if (candidate != nullptr) {
            value = candidate;
        }
    }
    napi_value result;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value AttachTunFd(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int fd = -1;
    int mtu = 0;
    bool ok = argc >= 2 && napi_get_value_int32(env, args[0], &fd) == napi_ok &&
        napi_get_value_int32(env, args[1], &mtu) == napi_ok && fd >= 0 && mtu > 0 && mtu <= 65535;
    if (ok) {
        // Keep a private template descriptor. The original remains owned exclusively
        // by VpnConnection, while startCore creates a separate duplicate for Go/mihomo.
        const int duplicated = fcntl(fd, F_DUPFD_CLOEXEC, 0);
        if (duplicated < 0) {
            ok = false;
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0, NAPI_LOG_TAG,
                "TUN descriptor duplication failed, errno=%d", errno);
        } else {
            const int previous = g_tun_fd.exchange(duplicated);
            if (previous >= 0) {
                close(previous);
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, 0, NAPI_LOG_TAG,
                "TUN descriptor duplicated and attached");
        }
    }
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startCore", nullptr, StartCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prepareProfile", nullptr, PrepareProfile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initProtect", nullptr, InitProtect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readProtectSocketFd", nullptr, ReadProtectSocketFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProtectResult", nullptr, SetProtectResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProtectResultForFd", nullptr, SetProtectResultForFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCore", nullptr, StopCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isCoreAlive", nullptr, IsCoreAlive, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreVersion", nullptr, CoreVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, LastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"attachTunFd", nullptr, AttachTunFd, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module tunboxCoreModule = {
    .nm_version = 1,
    .nm_flags = NM_FLAG_NONE,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tunbox_core_napi",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTunBoxCoreModule(void)
{
    napi_module_register(&tunboxCoreModule);
}
