// Package bridge exposes the Mihomo lifecycle used by the Android JNI wrapper.
package bridge

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	coreMu               sync.Mutex
	running              bool
	protectRead          *os.File
	protectWrite         *os.File
	protectSessionMu     sync.Mutex
	activeProtectSession *protectSession
	protectStopRequests  atomic.Int32
	protectRequired      atomic.Bool
	protectFailures      atomic.Uint64
	protectSuccesses     atomic.Uint64
	protectSequence      atomic.Uint32 // process-wide; never reset by InitProtect
	headlessBinderMu     sync.RWMutex
	headlessBinder       func(int) error
)

// protectSession 是内核出站 socket 的逐 fd protect 通道。
//
// 语义（v3, 2026-09）: 真机实证两条红线 ——
//  1. 顺序红线: 本机 protectProcessNet() 对 Go 线程创建的 socket 不生效(调用
//     "成功"但 socket 依然走 VPN 路由)。connect 抢在 protect 标记前发生 → SYN
//     回灌 TUN → 内核再拨同一地址 → 自激递归 → 53 秒打爆 fd 表(EMFILE)、core.log
//     涨 4MB, 全线节点瘫痪。所以必须"等 protect 回执再放行 connect"。
//  2. 活性红线: 旧实现"单请求串行 + 5s 超时 + 超时退役会话", 连接风暴下排队超
//     dial 预算(i/o timeout), 一次退役永久失联(protect monitor unavailable,
//     "连上但全部打不开")。因此使用并发等待 + 短超时，但失败必须拒绝该次拨号；
//     不再因为单条连接失败退役整个保护会话。
//
// 实现: 按唯一 seq 并发等回执，单次等待上限 800ms，只有正回执允许拨号。
type protectSession struct {
	done       chan struct{}
	cancelOnce sync.Once
	requestMu  sync.Mutex
	writer     *os.File
	writerFd   int
	warnedOnce bool

	waitMu  sync.Mutex
	waiters map[uint32]*protectWaiter // key: seq(回显), 不是 fd —— fd 号在 close 后会复用
}

type protectWaiter struct {
	ch chan bool // true is the only permission to dial
}

// protectWaitTimeout 是 protect 回执的最长等待。正常路径(ArkTS 10ms 轮询批量
// 排空 + protect IPC ~10-50ms, 并发处理)在几十毫秒内返回; 800ms 覆盖 ~1600/s
// 排空速率下的深队列；超过上限拒绝本次拨号，后续请求仍可正常保护。
const protectWaitTimeout = 800 * time.Millisecond

func newProtectSession() *protectSession {
	return &protectSession{
		done:     make(chan struct{}),
		writerFd: -1,
		waiters:  map[uint32]*protectWaiter{},
	}
}

// nextProtectSequence never reuses a receipt token, including across sessions.
// Saturation fails closed rather than allowing a stale ArkTS callback to match.
func nextProtectSequence() uint32 {
	for {
		previous := protectSequence.Load()
		if previous == ^uint32(0) {
			return 0
		}
		if protectSequence.CompareAndSwap(previous, previous+1) {
			return previous + 1
		}
	}
}

// registerWaiter 登记等待者并返回其 seq(8 字节记录 fd+seq 的协议: 回执按 seq
// 精确配对, 规避 fd 关闭复用后的错号唤醒)。
func (session *protectSession) registerWaiter() (*protectWaiter, uint32) {
	seq := nextProtectSequence()
	if seq == 0 {
		return nil, 0
	}
	entry := &protectWaiter{ch: make(chan bool, 1)}
	session.waitMu.Lock()
	session.waiters[seq] = entry
	session.waitMu.Unlock()
	return entry, seq
}

func (session *protectSession) removeWaiter(seq uint32) {
	session.waitMu.Lock()
	delete(session.waiters, seq)
	session.waitMu.Unlock()
}

// completeWaiter 先从表移除，再向有界通道发送结果；移除者独占该次回执。
// 未登记/已超时(回执晚到)的 seq 直接丢弃。
func (session *protectSession) completeWaiter(seq uint32, ok bool) {
	session.waitMu.Lock()
	entry := session.waiters[seq]
	if entry != nil {
		delete(session.waiters, seq)
	}
	session.waitMu.Unlock()
	if entry != nil {
		entry.ch <- ok
	}
}

func (session *protectSession) dropAllWaiters() {
	session.waitMu.Lock()
	waiters := session.waiters
	session.waiters = map[uint32]*protectWaiter{}
	session.waitMu.Unlock()
	for _, entry := range waiters {
		close(entry.ch)
	}
}

// closeWriter 安全关闭管道写端: 与 protectSocket 的裸 syscall.Write 共用
// requestMu 串行化, 并先把 writerFd 置 -1 —— 杜绝"关闭后 fd 号被其他文件复用,
// 迟到的写入落到无关文件"的经典 fd 复用竞态。
func (session *protectSession) closeWriter() {
	session.requestMu.Lock()
	session.writerFd = -1
	if session.writer != nil {
		_ = session.writer.Close()
		session.writer = nil
	}
	session.requestMu.Unlock()
}

func (session *protectSession) active() bool {
	select {
	case <-session.done:
		return false
	default:
		return true
	}
}

func (session *protectSession) cancel() {
	session.cancelOnce.Do(func() { close(session.done) })
}

func replaceProtectSession(next *protectSession) {
	protectSessionMu.Lock()
	previous := activeProtectSession
	activeProtectSession = next
	protectSessionMu.Unlock()
	if previous != nil && previous != next {
		previous.cancel()
	}
}

func installProtectSession(next *protectSession) bool {
	protectSessionMu.Lock()
	if protectStopRequests.Load() > 0 {
		protectSessionMu.Unlock()
		next.cancel()
		return false
	}
	previous := activeProtectSession
	activeProtectSession = next
	protectSessionMu.Unlock()
	if previous != nil && previous != next {
		previous.cancel()
	}
	return true
}

func currentProtectSession() *protectSession {
	protectSessionMu.Lock()
	defer protectSessionMu.Unlock()
	return activeProtectSession
}

func retireProtectSession(session *protectSession) {
	protectSessionMu.Lock()
	if activeProtectSession == session {
		activeProtectSession = nil
	}
	protectSessionMu.Unlock()
	session.cancel()
	session.dropAllWaiters()
	session.closeWriter()
}

func protectReadyForStart(tunFd int64) bool {
	if tunFd <= 0 {
		return true
	}
	if protectWrite == nil || protectRead == nil {
		return false
	}
	session := currentProtectSession()
	return session != nil && session.writer == protectWrite && session.active()
}

// SetHeadlessSocketBinder affects this process only. The UI test core binds to
// the physical network; the separate VPN process keeps its protect receipt path.
func SetHeadlessSocketBinder(bind func(int) error) {
	headlessBinderMu.Lock()
	headlessBinder = bind
	headlessBinderMu.Unlock()
}

// protectSocket 在 connect() 之前把 (fd, seq) 记录交给 ArkTS 去 protect, 并按
// seq 精确等待自己的回执(上限 protectWaitTimeout)。不同拨号并发等待互不排队;
// 真实 VPN 只允许成功回执；拒绝、超时和通道失效一律阻止 connect，避免回流 TUN。
func protectSocket(_ string, _ string, connection syscall.RawConn) error {
	session := currentProtectSession()
	if session == nil {
		if protectRequired.Load() {
			protectFailures.Add(1)
			return ErrSocketUnprotected
		}
		headlessBinderMu.RLock()
		bind := headlessBinder
		headlessBinderMu.RUnlock()
		if bind != nil {
			var bindErr error
			if err := connection.Control(func(fd uintptr) { bindErr = bind(int(fd)) }); err != nil {
				return err
			}
			return bindErr
		}
		return nil
	}

	var entry *protectWaiter
	var waitFd uint32
	var waitSeq uint32
	controlErr := connection.Control(func(fd uintptr) {
		session.requestMu.Lock()
		notified := session.active() && session.writerFd >= 0
		var writeErr error
		if notified {
			waitFd = uint32(fd)
			// 先登记再写管道: 回执只可能在写入之后到达。requestMu 保证
			// 单条 8 字节记录原子写入, 不会被拆散。
			entry, waitSeq = session.registerWaiter()
			if entry == nil {
				session.requestMu.Unlock()
				return // exhausted token space: reject without writing a reusable seq
			}
			var encoded [8]byte
			binary.LittleEndian.PutUint32(encoded[0:4], waitFd)
			binary.LittleEndian.PutUint32(encoded[4:8], waitSeq)
			for {
				_, writeErr = syscall.Write(session.writerFd, encoded[:])
				if writeErr == nil || !errors.Is(writeErr, syscall.EINTR) {
					break
				}
			}
			if writeErr != nil {
				session.removeWaiter(waitSeq)
				entry = nil
				if !session.warnedOnce {
					session.warnedOnce = true
					log.Warnln("Bridge: protect notify dropped fd %d: %v (further drops silent)", fd, writeErr)
				}
			}
		}
		session.requestMu.Unlock()
	})
	if controlErr != nil {
		if entry != nil {
			session.removeWaiter(waitSeq)
		}
		protectFailures.Add(1)
		log.Warnln("Bridge: protect control error: %v", controlErr)
		return ErrSocketUnprotected
	}
	if entry == nil {
		protectFailures.Add(1)
		return ErrSocketUnprotected
	}
	err := awaitProtectResult(session.done, entry.ch, protectWaitTimeout)
	session.removeWaiter(waitSeq)
	if err != nil {
		failures := protectFailures.Add(1)
		// Bounded evidence even during a connection storm.
		if failures == 1 || failures%100 == 0 {
			log.Warnln("Bridge: unprotected outbound blocked fd=%d seq=%d total=%d", waitFd, waitSeq, failures)
		}
		return err
	}
	protectSuccesses.Add(1)
	return nil
}

// releaseProtectLocked must be called while coreMu is held.
func releaseProtectLocked() {
	session := currentProtectSession()
	replaceProtectSession(nil)
	if session != nil {
		session.dropAllWaiters()
		session.closeWriter()
	}
	if protectRead != nil {
		_ = protectRead.Close()
		protectRead = nil
	}
	protectWrite = nil
}

func Init(homeDir, configFile string) {
	resourceHome = homeDir
	C.SetHomeDir(homeDir)
	C.SetConfig(configFile)
	log.Infoln("Bridge: init homeDir=%s configFile=%s", homeDir, configFile)
}

func Start(configPath string, tunFd int64) (result string) {
	coreMu.Lock()
	defer coreMu.Unlock()
	defer func() {
		if recovered := recover(); recovered != nil {
			result = fmt.Sprintf("panic: %v", recovered)
			log.Errorln("Bridge: recovered from panic: %v", recovered)
		}
		if result != "" && !running {
			stopResourceSampler()
			releaseProtectLocked()
		}
	}()

	if running {
		return "already running"
	}
	// Headless testing has no VPN route. Real TUN startup must fail closed,
	// including provider/DNS downloads performed while parsing configuration.
	protectRequired.Store(tunFd > 0)
	Init(filepath.Dir(configPath), configPath)
	startResourceSampler() // include configuration/provider startup, not just connected time

	log.Infoln("Bridge: reading config %s", configPath)
	configBytes, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Sprintf("read config: %v", err)
	}
	log.Infoln("Bridge: read %d bytes of config", len(configBytes))

	cfg, err := config.Parse(configBytes)
	if err != nil {
		return fmt.Sprintf("parse config: %v", err)
	}
	log.Infoln(
		"Bridge: config parsed, %d proxies, external-controller=%s",
		len(cfg.Proxies),
		cfg.Controller.ExternalController,
	)
	if cfg.Controller.ExternalController == "" {
		cfg.Controller.ExternalController = "127.0.0.1:9090"
		log.Infoln("Bridge: set external-controller to 127.0.0.1:9090")
	}

	if tunFd > 0 {
		// Preserve the TUN network parameters generated by ClashConfigGenerator.
		// VpnExtensionAbility and the YAML are the source of truth for the
		// 172.19.0.1/30, optional IPv6, and shared MTU configuration. Only inject
		// the descriptor and settings that are specific to the native bridge.
		cfg.General.Tun.Enable = true
		// Honor the validated YAML stack (mips by default); never silently replace it.
		cfg.General.Tun.FileDescriptor = int(tunFd)
		cfg.General.Tun.DNSHijack = []string{"any:53"}
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		log.Infoln("Bridge: TUN descriptor attached; effective stack=%s mtu=%d congestion=%s", cfg.General.Tun.Stack.String(), cfg.General.Tun.MTU, cfg.General.Tun.CongestionController)
	} else {
		log.Infoln("Bridge: running without TUN")
	}

	if !protectReadyForStart(tunFd) {
		return "protect monitor is unavailable"
	}
	if tunFd > 0 {
		log.Infoln("Bridge: socket protect acknowledgement required (fail-closed)")
	}

	hub.ApplyConfig(cfg)

	// ApplyConfig may return before the REST controller has finished binding.
	// Do not report the core as running until the controller socket is actually
	// accepting connections; otherwise ArkTS can observe IsRunning=true while
	// every /version probe still races with controller startup.
	controllerAddress := cfg.Controller.ExternalController
	controllerDeadline := time.Now().Add(10 * time.Second)
	var controllerErr error
	for time.Now().Before(controllerDeadline) {
		conn, err := net.DialTimeout("tcp", controllerAddress, 300*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			controllerErr = nil
			break
		}
		controllerErr = err
		time.Sleep(100 * time.Millisecond)
	}
	if controllerErr != nil {
		executor.Shutdown()
		return fmt.Sprintf("controller %s not ready: %v", controllerAddress, controllerErr)
	}

	running = true
	log.Infoln("Bridge: started successfully, API on %s", controllerAddress)
	return ""
}

// UpdateNetwork refreshes only physical DNS and obsolete tracked flows, never TUN/config.
// coreMu serializes this operation with Start/Stop; callers run it off the ArkTS thread.
func UpdateNetwork(addresses []string, resetFlows bool) error {
	coreMu.Lock()
	defer coreMu.Unlock()
	if !running {
		return errors.New("core is not running")
	}
	if err := dns.UpdatePlatformSystemDNS(addresses); err != nil {
		return err
	}
	resolver.ClearCache()
	resolver.ResetConnection()
	if resetFlows {
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
			_ = c.Close()
			return true
		})
	}
	log.Infoln("Bridge: physical network updated (DNS=%d, resetFlows=%v)", len(addresses), resetFlows)
	return nil
}

func Stop() {
	// Start holds coreMu while ApplyConfig may itself be waiting for a protect
	// response. Cancel that wait before attempting to take coreMu.
	protectStopRequests.Add(1)
	if session := currentProtectSession(); session != nil {
		session.cancel() // wake waiters now; keep ownership until releaseProtectLocked closes writer
	}
	defer protectStopRequests.Add(-1)

	coreMu.Lock()
	defer coreMu.Unlock()

	stopResourceSampler()
	releaseProtectLocked()
	if running {
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool { _ = c.Close(); return true })
		listener.ReCreateMixed(0, nil)
		listener.ReCreateSocks(0, nil)
		// Cleanup closes the active TUN listener but retains LastTunConf. Reset
		// it through the listener lock so a later start that reuses the same
		// numeric Android fd cannot be mistaken for an unchanged configuration.
		listener.ReCreateTun(LC.Tun{}, tunnel.Tunnel)
		executor.Shutdown()
		running = false
	}
	log.Infoln("Bridge: stopped")
}

func IsRunning() bool {
	coreMu.Lock()
	defer coreMu.Unlock()
	return running
}

func InitProtect() int64 {
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		log.Errorln("Bridge: pipe error: %v", err)
		return -1
	}

	coreMu.Lock()
	releaseProtectLocked()
	session := newProtectSession()
	session.writer = writePipe
	// Fd() 把写端切到 raw 模式并显式置 O_NONBLOCK: protectSocket 的裸 syscall.Write
	// 在队列满时立即 EAGAIN 返回, 绝不阻塞拨号协程。
	writeFd := int(writePipe.Fd())
	if err := syscall.SetNonblock(writeFd, true); err != nil {
		log.Warnln("Bridge: protect write pipe nonblock failed: %v", err)
	} else {
		session.writerFd = writeFd
	}
	if !installProtectSession(session) {
		_ = readPipe.Close()
		_ = writePipe.Close()
		coreMu.Unlock()
		log.Errorln("Bridge: protect pipe rejected while stop is pending")
		return -1
	}
	protectRead = readPipe
	protectWrite = writePipe
	readFd := int(readPipe.Fd())
	transferFd, err := syscall.Dup(readFd)
	if err != nil || transferFd <= 0 {
		if err == nil {
			err = fmt.Errorf("invalid duplicated descriptor %d", transferFd)
			_ = syscall.Close(transferFd)
		}
		releaseProtectLocked()
		coreMu.Unlock()
		log.Errorln("Bridge: duplicate protect pipe error: %v", err)
		return -1
	}
	syscall.CloseOnExec(transferFd)
	coreMu.Unlock()

	// The raw duplicate is transferred to Kotlin. Go keeps and closes only the
	// original readPipe; Kotlin must adopt and eventually close transferFd.
	log.Infoln("Bridge: protect pipe ready, readFd=%d transferFd=%d", readFd, transferFd)
	return int64(transferFd)
}

// SetProtectResultForFd 由 ArkTS 在 connection.protect(fd) 落定后回调, 回显
// 管道记录里的 seq，精确唤醒对应拨号协程。ok=false 唤醒并拒绝拨号。
// seq 在进程内跨会话唯一，旧 protect Promise 迟到也不能唤醒新会话。
// fd 仅作日志/诊断用 —— 配对必须用 seq, fd 号会在 socket 关闭后被复用。
func SetProtectResultForFd(fd uint32, seq uint32, ok bool) {
	if seq == 0 {
		return
	}
	if session := currentProtectSession(); session != nil {
		session.completeWaiter(seq, ok)
	}
}

// SetProtectResult 兼容旧导出符号(napi dlsym 依赖存在该符号)。
// v3 语义下必须携带 fd 才能精确配对, 旧无 fd 回执无法唤醒任何等待者, 仅保留符号。
func SetProtectResult(_ bool) {}

func init() {
	dialer.DefaultSocketHook = protectSocket
	runtime.GOMAXPROCS(runtime.NumCPU())
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			dialer := net.Dialer{Control: protectSocket}
			return dialer.DialContext(ctx, network, address)
		},
	}
}
