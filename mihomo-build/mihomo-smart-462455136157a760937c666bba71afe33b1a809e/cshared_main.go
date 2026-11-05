//go:build !windows
// +build !windows

// Package main — TunBox HarmonyOS c-shared 包装层
// 对应 upstream Android 构建中 gomobile bind 的角色：把 bridge 包暴露为 C ABI。
// upstream: TunBox_Android/native/bridge/bridge.go (package bridge)
// 构建目标: GOOS=linux GOARCH=arm64 -buildmode=c-shared, CC = OHOS NDK musl clang
//
// 导出 ABI（与 entry/src/main/cpp/tunbox_core_napi.cpp 的 dlsym 对齐）:
//
//	TunBoxInit(homeDir, configFile)             初始化内核目录
//	TunBoxStart(configPath, tunFd) -> int       0=成功，1=失败（错误串经 TunBoxLastError 取）
//	TunBoxInitProtect() -> longlong             建立逐 fd protect 通道，返回读端 dup fd
//	TunBoxSetProtectResult(ok)                        兼容保留(无 seq 回执不唤醒)
//	TunBoxSetProtectResultForFd(fd, seq, ok)          按 seq 精确唤醒对应拨号等待者
//	TunBoxStop()
//	TunBoxIsRunning() -> int
//	TunBoxVersion() -> const char*
//	TunBoxLastError() -> const char*
//	TunBoxPrepareProfile(text)                  YAML 锚点展开 + 校验（App 侧预览解析用）
//	TunBoxValidateProfile(text, ageSecretKey, profilePath)
//	                                              字节→temp→age 解密→校验→转换回退→原生写 profile 文件（FlClash saveFile 等价物）
//	TunBoxGetProfileBase(path)                  mihomo 解析 profile -> JSON map（FlClash getConfig/getProfileBase）
//	TunBoxGetProfileOutbounds(path)             只投影 name/type+组名（FlClash handleGetProfileOutbounds，供影子节点）
//	TunBoxDecodeYaml(text)                      YAML -> JSON map（App map 级 patch 的解码器）
//	TunBoxFetchText(url, ua, auth)              utls 订阅取回（FlClash request 同构）
package main

/*
#include <stdlib.h>
#include <stdint.h>
static int tunbox_call_socket_binder(uintptr_t callback, int fd) {
    return ((int (*)(int))callback)(fd);
}
*/
import "C"

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/metacubex/mihomo/bridge"
	"github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
)

//export TunBoxPrepareProfile
func TunBoxPrepareProfile(text *C.char) *C.char {
	yaml, err := config.PrepareProfile([]byte(C.GoString(text)))
	reply := struct {
		YAML  string `json:"yaml"`
		Error string `json:"error"`
	}{YAML: string(yaml)}
	if err != nil {
		reply.Error = err.Error()
	}
	data, _ := json.Marshal(reply)
	return C.CString(string(data))
}

// TunBoxValidateProfile 是 FlClash Profile.saveFile + controller.validateProfile
// 的原生等价物：字节→temp→age 解密（armor 头+空 key → AgeSecretKeyRequired 原始错）
// → validateConfig → 失败走 convert.ConvertsV2Ray → 非空写 {'proxies':} 再 validate
// → 仍失败返首次 issue → 通过后原生写 profiles/<id>.yaml（调用方给目标路径），
// 不展开锚点。返回 JSON {"error":"..."}（空 = 成功），调用方用 TunBoxFreeString 释放。
//
//export TunBoxValidateProfile
func TunBoxValidateProfile(text *C.char, ageSecretKey *C.char, profilePath *C.char) *C.char {
	reply := struct {
		Error string `json:"error"`
	}{}
	if err := bridge.ValidateProfile([]byte(C.GoString(text)), C.GoString(ageSecretKey), C.GoString(profilePath)); err != nil {
		reply.Error = err.Error()
	}
	data, _ := json.Marshal(reply)
	return C.CString(string(data))
}

// TunBoxGetProfileOutbounds 是 FlClash `core/profile_base.go
// handleGetProfileOutbounds` 的移植：只投影 name/type+组名，供 ArkTS
// CoreNodeBridge 影子节点。返回 JSON：{"proxies":[{"name","type"}...],
// "proxyGroups":[...],"error":"..."}，调用方用 TunBoxFreeString 释放。
//
//export TunBoxGetProfileOutbounds
func TunBoxGetProfileOutbounds(path *C.char) *C.char {
	reply := struct {
		Proxies     []bridge.ProfileOutbound `json:"proxies"`
		ProxyGroups []bridge.ProfileOutbound `json:"proxy-groups"`
		Error       string                   `json:"error"`
	}{Proxies: []bridge.ProfileOutbound{}, ProxyGroups: []bridge.ProfileOutbound{}}
	out, err := bridge.GetProfileOutbounds(C.GoString(path))
	if err != nil {
		reply.Error = err.Error()
	} else {
		reply.Proxies = out.Proxies
		reply.ProxyGroups = out.ProxyGroups
	}
	data, _ := json.Marshal(reply)
	return C.CString(string(data))
}

//export TunBoxFreeString
func TunBoxFreeString(text *C.char) { C.free(unsafe.Pointer(text)) }

// TunBoxGetProfileBase 是 FlClash `core/hub.go handleGetConfig` +
// `core/profile_base.go handleGetProfileBase` 的合并等价物：
//
//   - `config.UnmarshalRawConfig(buf)` —— mihomo 自己的解析器（锚点/合并键/类型
//     与最终加载完全一致），错误原样带回（FlClash validateConfig 同款语义）；
//   - RawConfig 经 encoding/json 序列化后把 `rule` 重命名为 `rules`
//     （mihomo RawConfig.Rule 的 json tag 是 `rule`，FlClash Dart 侧按 `rules` 读）；
//   - 附 sha256 digest 与 proxies/proxyGroups/rules/matchRules 计数
//     （FlClash ProfileBase{Digest, MatchRules, Proxies, ProxyGroups, Rules}）。
//
// 返回 JSON：{"config":{...},"digest":"...","proxies":N,"proxyGroups":N,"rules":N,
// "matchRules":[...],"error":"..."}，调用方用 TunBoxFreeString 释放。
//
//export TunBoxGetProfileBase
func TunBoxGetProfileBase(path *C.char) *C.char {
	reply := struct {
		Config      map[string]any `json:"config"`
		Digest      string         `json:"digest"`
		Proxies     int            `json:"proxies"`
		ProxyGroups int            `json:"proxyGroups"`
		Rules       int            `json:"rules"`
		MatchRules  []string       `json:"matchRules"`
		Error       string         `json:"error"`
	}{MatchRules: []string{}}
	buf, err := os.ReadFile(C.GoString(path))
	if err != nil {
		reply.Error = err.Error()
		data, _ := json.Marshal(reply)
		return C.CString(string(data))
	}
	digest := sha256.Sum256(buf)
	reply.Digest = hex.EncodeToString(digest[:])
	raw, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		reply.Error = err.Error()
		data, _ := json.Marshal(reply)
		return C.CString(string(data))
	}
	reply.Proxies = len(raw.Proxy)
	reply.ProxyGroups = len(raw.ProxyGroup)
	reply.Rules = len(raw.Rule)
	for _, rule := range raw.Rule {
		kind, _, _ := strings.Cut(rule, ",")
		if strings.EqualFold(strings.TrimSpace(kind), "MATCH") {
			reply.MatchRules = append(reply.MatchRules, rule)
		}
	}
	encoded, err := json.Marshal(raw)
	if err == nil {
		var m map[string]any
		if err := json.Unmarshal(encoded, &m); err == nil {
			// mihomo RawConfig.Rule 的 json tag 是 "rule"（yaml tag 是 "rules"）。
			// App 侧与 FlClash Dart 一致按 `rules` 读，这里统一改口。
			if v, ok := m["rule"]; ok {
				m["rules"] = v
				delete(m, "rule")
			}
			reply.Config = m
		}
	}
	if reply.Config == nil {
		reply.Error = "config marshal failed"
	}
	data, _ := json.Marshal(reply)
	return C.CString(string(data))
}

// TunBoxDecodeYaml 把 YAML 文本解成 JSON map（mihomo 同一 yaml 库口径）。
// FlClash 在 Dart 里用 loadYaml 完成 map 级 patch；ArkTS 没有 YAML 解析器，
// 由内核提供同一方言的解码（`common/yaml` 就是 go.yaml.in/yaml/v3 原样透出）。
// 返回 JSON：{"map":{...},"error":"..."}，调用方用 TunBoxFreeString 释放。
//
//export TunBoxDecodeYaml
func TunBoxDecodeYaml(text *C.char) *C.char {
	reply := struct {
		Map   map[string]any `json:"map"`
		Error string         `json:"error"`
	}{}
	var m map[string]any
	if err := yaml.Unmarshal([]byte(C.GoString(text)), &m); err != nil {
		reply.Error = err.Error()
	} else {
		reply.Map = m
	}
	data, _ := json.Marshal(reply)
	return C.CString(string(data))
}

// TunBoxFetchText 用浏览器级 TLS 指纹（utls Chrome）拉取订阅 / provider 文本。
// 与 FlClash 的下载语义一致：单一 UA，不做 UA 轮换。
// 返回 JSON：{"body":"...","error":"..."}，调用方用 TunBoxFreeString 释放。
//
//export TunBoxFetchText
func TunBoxFetchText(rawURL *C.char, userAgent *C.char, authHeader *C.char, proxyPort C.int) *C.char {
	proxy := ""
	if proxyPort > 0 && proxyPort <= 65535 {
		proxy = fmt.Sprintf("http://127.0.0.1:%d", int(proxyPort))
	}
	result, err := bridge.FetchWithProxy(C.GoString(rawURL), C.GoString(userAgent),
		C.GoString(authHeader), 0, proxy, proxy != "")
	reply := struct {
		bridge.FetchResult
		Error string `json:"error"`
	}{FetchResult: result}
	if err != nil {
		reply.Error = err.Error()
	}
	data, _ := json.Marshal(reply)
	return C.CString(string(data))
}

var (
	lastErrMu   sync.Mutex
	lastErrStr  string
	coreLogOnce sync.Once
)

func setLastErr(s string) {
	lastErrMu.Lock()
	lastErrStr = s
	lastErrMu.Unlock()
}

// redirectCoreLogs 把 Go 进程的 stdout/stderr 重定向到 homeDir/core.log。
// OHOS 应用进程的 stdout 不落任何可见位置, mihomo 全部运行日志(拨号失败原因/
// DNS/TUN)只有落盘才能被 hdc 拉取排查(对齐 Hey/NekoBox 的内核日志文件方案)。
func redirectCoreLogs(homeDir string) {
	if len(homeDir) == 0 {
		return
	}
	coreLogOnce.Do(func() {
		reader, writer, err := os.Pipe()
		if err != nil {
			return
		}
		if unix.Dup3(int(writer.Fd()), 1, 0) != nil || unix.Dup3(int(writer.Fd()), 2, 0) != nil {
			_ = reader.Close()
			_ = writer.Close()
			return
		}
		_ = writer.Close() // fd 1/2 now own their own references
		go func() {
			defer reader.Close()
			_, _ = io.CopyBuffer(bridge.BestEffortLog{Writer: &bridge.RotatingLog{Path: filepath.Join(homeDir, "core.log"), MaxBytes: 2 * 1024 * 1024, Backups: 3}}, reader, make([]byte, 32*1024))
		}()
	})
}

//export TunBoxInit
func TunBoxInit(homeDir *C.char, configFile *C.char) {
	redirectCoreLogs(C.GoString(homeDir))
	bridge.Init(C.GoString(homeDir), C.GoString(configFile))
}

//export TunBoxStart
func TunBoxStart(configPath *C.char, tunFd C.longlong) C.int {
	path := C.GoString(configPath)
	// Init is not called by the NAPI start path. Establish logging before parsing;
	// bridge.Start initializes the home/config under its lifecycle mutex.
	redirectCoreLogs(filepath.Dir(path))
	if _, err := os.Stat(path); err != nil {
		setLastErr(fmt.Sprintf("config file missing: %v", err))
		return 1
	}
	fd := int64(tunFd)
	result := bridge.Start(path, fd)
	if result != "" {
		setLastErr(result)
		return 1
	}
	setLastErr("")
	return 0
}

//export TunBoxSetSocketBinder
func TunBoxSetSocketBinder(callback C.uintptr_t) {
	if callback == 0 {
		bridge.SetHeadlessSocketBinder(nil)
		return
	}
	bridge.SetHeadlessSocketBinder(func(fd int) error {
		if code := C.tunbox_call_socket_binder(callback, C.int(fd)); code != 0 {
			return fmt.Errorf("physical network socket bind failed: %d", int(code))
		}
		return nil
	})
}

//export TunBoxInitProtect
func TunBoxInitProtect() C.longlong {
	return C.longlong(bridge.InitProtect())
}

//export TunBoxSetProtectResult
func TunBoxSetProtectResult(ok C.int) {
	bridge.SetProtectResult(ok != 0)
}

//export TunBoxSetProtectResultForFd
func TunBoxSetProtectResultForFd(fd C.longlong, seq C.longlong, ok C.int) {
	bridge.SetProtectResultForFd(uint32(fd), uint32(seq), ok != 0)
}

//export TunBoxUpdateNetwork
func TunBoxUpdateNetwork(payload *C.char, resetFlows C.int) C.int {
	var addresses []string
	if err := json.Unmarshal([]byte(C.GoString(payload)), &addresses); err != nil {
		return 0
	}
	if len(addresses) > 16 {
		return 0
	}
	if err := bridge.UpdateNetwork(addresses, resetFlows != 0); err != nil {
		return 0
	}
	return 1
}

//export TunBoxStop
func TunBoxStop() {
	bridge.Stop()
}

//export TunBoxIsRunning
func TunBoxIsRunning() C.int {
	if bridge.IsRunning() {
		return 1
	}
	return 0
}

//export TunBoxVersion
func TunBoxVersion() *C.char {
	// 报告内嵌 mihomo 内核的真实版本，而不是一个静态产品串：诊断弹窗靠它区分
	// 用户实际跑的是哪一版内核。constant.Version 由 mihomo 自己维护。
	return C.CString("tunbox-ohos-mihomo-" + constant.Version)
}

//export TunBoxLastError
func TunBoxLastError() *C.char {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	return C.CString(lastErrStr)
}

// main() is provided by mihomo's main.go in the same package; with
// -buildmode=c-shared it is never executed, but must exist exactly once.
