// Execute the unmodified production NAPI lifecycle with only OS/NAPI boundaries
// substituted. The runner inserts the source from tunbox_core_napi.cpp below.
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <sys/socket.h>
#include <unistd.h>

using napi_env = void*;
using napi_value = intptr_t;
using napi_callback_info = int32_t*;
constexpr int napi_ok = 0;
static bool coreAvailable = true;
static bool symbolAvailable = true;
static bool validArgument = true;
static uintptr_t installedBinder = 0;
static int bindingResult = 0;
static int32_t lastBoundNetwork = -1;
static void* g_core_handle = nullptr;
struct NetConn_NetHandle { int32_t netId; };
static int OH_NetConn_BindSocket(int fd, NetConn_NetHandle* handle) {
    assert(fd >= 0);
    lastBoundNetwork = handle->netId;
    return bindingResult;
}
static bool loadCore() { return coreAvailable; }
static void recordBinder(uintptr_t callback) { installedBinder = callback; }
static void* dlsym(void*, const char* name) {
    assert(std::strcmp(name, "TunBoxSetSocketBinder") == 0);
    return symbolAvailable ? reinterpret_cast<void*>(&recordBinder) : nullptr;
}
static int napi_get_cb_info(napi_env, napi_callback_info info, size_t* count,
                           napi_value* args, void*, void*) {
    *count = 1;
    args[0] = *info;
    return napi_ok;
}
static int napi_get_value_int32(napi_env, napi_value value, int32_t* result) {
    *result = static_cast<int32_t>(value);
    return validArgument ? napi_ok : 1;
}
static int napi_get_boolean(napi_env, bool value, napi_value* result) {
    *result = value ? 1 : 0;
    return napi_ok;
}

/*PRODUCTION*/

static bool setNetwork(int32_t id) { return SetPhysicalNetId(nullptr, &id) == 1; }
// Go's headless protectSocket path invokes the installed callback if present;
// otherwise the ordinary DNS/download socket can use its default route.
static int dial() {
    return installedBinder ? reinterpret_cast<int (*)(int)>(installedBinder)(42) : 0;
}
int main() {
    assert(dial() == 0);
    for (int32_t id : {7, 8}) {
        assert(setNetwork(id));
        assert(installedBinder != 0 && dial() == 0);
        assert(lastBoundNetwork == id);
        bindingResult = -50; // network lost during an active isolated batch
        assert(dial() == -50); // fail closed, never silently use the VPN route
        assert(setNetwork(-1)); // cleanup must not need a working network
        assert(installedBinder == 0);
        assert(g_physical_net_id.load() == -1);
        assert(dial() == 0); // subscriptions can resolve DNS after cleanup
        assert(setNetwork(-1) && dial() == 0); // idempotent close
        assert(!setNetwork(id)); // preflight rejection installs no callback
        assert(installedBinder == 0 && dial() == 0);
        bindingResult = 0;
    }
    assert(setNetwork(9));
    const auto previous = installedBinder;
    bindingResult = -12;
    assert(!setNetwork(10));
    assert(installedBinder == previous && g_physical_net_id.load() == 9);
    assert(dial() == -12); // rejected rebind must not disable active isolation
    assert(setNetwork(0) && installedBinder == 0 && dial() == 0);
    bindingResult = 0;
    coreAvailable = false;
    assert(!setNetwork(10) && installedBinder == 0);
    coreAvailable = true;
    symbolAvailable = false;
    assert(!setNetwork(10) && installedBinder == 0);
    symbolAvailable = true;
    validArgument = false;
    assert(!setNetwork(10) && installedBinder == 0);
}
