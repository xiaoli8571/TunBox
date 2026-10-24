cmake_minimum_required(VERSION 3.5.0)
project(tunbox_core_napi)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
add_definitions(-DOHOS_PLATFORM)

add_library(tunbox_core_napi SHARED tunbox_core_napi.cpp)

target_include_directories(tunbox_core_napi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})

# Register libgojni.so as an imported HAP library. IMPORTED_NO_SONAME forces
# a basename-only DT_NEEDED entry (libgojni.so), avoiding the invalid Windows
# build path that HarmonyOS cannot resolve inside the VPN extension process.
add_library(gojni SHARED IMPORTED)
set_target_properties(gojni PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libgojni.so"
    IMPORTED_NO_SONAME TRUE)

find_library(hilog-lib hilog_ndk.z)
find_library(libnapi-lib libace_napi.z.so)

target_link_options(tunbox_core_napi PRIVATE -Wl,--no-as-needed)
target_link_libraries(tunbox_core_napi PUBLIC ${hilog-lib} ${libnapi-lib} gojni)
