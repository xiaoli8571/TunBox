package bridge

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"syscall"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type networkTracker struct {
	C.Connection
	id     string
	closed bool
	info   statistic.TrackerInfo
}

func (c *networkTracker) ID() string                   { return c.id }
func (c *networkTracker) Info() *statistic.TrackerInfo { return &c.info }
func (c *networkTracker) Close() error                 { c.closed = true; return nil }

func TestUpdateNetworkDoesNotRecreateTunOrCloseFlowsForDNSOnly(t *testing.T) {
	coreMu.Lock()
	previousRunning := running
	running = true
	coreMu.Unlock()
	defer func() { coreMu.Lock(); running = previousRunning; coreMu.Unlock() }()
	before := listener.LastTunConf
	tracker := &networkTracker{id: "network-update-fixture", info: statistic.TrackerInfo{Metadata: &C.Metadata{}}}
	statistic.DefaultManager.Join(tracker)
	defer statistic.DefaultManager.Leave(tracker)
	if err := UpdateNetwork([]string{"1.1.1.1"}, false); err != nil {
		t.Fatal(err)
	}
	if tracker.closed {
		t.Fatal("DNS-only update closed live flow")
	}
	if err := UpdateNetwork([]string{"9.9.9.9"}, true); err != nil {
		t.Fatal(err)
	}
	if !tracker.closed {
		t.Fatal("network replacement retained obsolete flow")
	}
	if listener.LastTunConf.Enable != before.Enable || listener.LastTunConf.FileDescriptor != before.FileDescriptor || listener.LastTunConf.MTU != before.MTU {
		t.Fatal("lightweight network update changed TUN configuration")
	}
	if !IsRunning() {
		t.Fatal("network update stopped Core")
	}
}

func TestUpdateNetworkRejectsStoppedCore(t *testing.T) {
	Stop()
	if err := UpdateNetwork([]string{"1.1.1.1"}, true); err == nil {
		t.Fatal("stopped core reported update success")
	}
}

type fixedRawConn uintptr

func (connection fixedRawConn) Control(control func(uintptr)) error {
	control(uintptr(connection))
	return nil
}

func (fixedRawConn) Read(func(uintptr) bool) error {
	return errors.New("unexpected RawConn.Read")
}

func (fixedRawConn) Write(func(uintptr) bool) error {
	return errors.New("unexpected RawConn.Write")
}

func TestProtectSocketHeadlessAndMissingVpnSession(t *testing.T) {
	replaceProtectSession(nil)
	previous := protectRequired.Load()
	defer protectRequired.Store(previous)
	protectRequired.Store(false)
	// 新语义: protect 通知只是兜底提示(进程级 protectProcessNet 才是主保障),
	// 没有会话时也必须放行拨号, 绝不能让 dial 失败。
	if err := protectSocket("tcp", "example.com:443", nil); err != nil {
		t.Fatalf("protect dispatcher blocked a socket without a monitor: %v", err)
	}
	protectRequired.Store(true)
	if err := protectSocket("tcp", "example.com:443", nil); !errors.Is(err, ErrSocketUnprotected) {
		t.Fatalf("missing VPN protector allowed outbound: %v", err)
	}
}

func TestStopCancelsProtectBeforeCoreLock(t *testing.T) {
	replaceProtectSession(nil)
	session := newProtectSession()
	if !installProtectSession(session) {
		t.Fatal("protect session was unexpectedly rejected")
	}

	coreMu.Lock()
	stopReturned := make(chan struct{})
	go func() {
		Stop()
		close(stopReturned)
	}()

	select {
	case <-session.done:
		// Cancellation must happen while Stop is still blocked on coreMu.
	case <-time.After(time.Second):
		coreMu.Unlock()
		t.Fatal("Stop waited for coreMu before canceling protect")
	}
	select {
	case <-stopReturned:
		coreMu.Unlock()
		t.Fatal("Stop returned while coreMu was held")
	default:
	}
	coreMu.Unlock()

	select {
	case <-stopReturned:
	case <-time.After(time.Second):
		t.Fatal("Stop did not return after coreMu was released")
	}
}

func TestStopResetsTunConfigForRepeatedDescriptor(t *testing.T) {
	listener.LastTunConf = LC.Tun{
		Enable:         true,
		FileDescriptor: 128,
	}
	running = true

	Stop()

	if listener.LastTunConf.Enable {
		t.Fatal("TUN config remained enabled after Stop")
	}
	if listener.LastTunConf.FileDescriptor != 0 {
		t.Fatalf(
			"TUN descriptor after Stop = %d, want 0",
			listener.LastTunConf.FileDescriptor,
		)
	}
}

func TestInstallProtectSessionRejectsPendingStop(t *testing.T) {
	replaceProtectSession(nil)
	protectStopRequests.Add(1)
	defer protectStopRequests.Add(-1)

	session := newProtectSession()
	if installProtectSession(session) {
		t.Fatal("protect session was installed during a pending stop")
	}
	if session.active() {
		t.Fatal("rejected protect session remained active")
	}
	if currentProtectSession() != nil {
		t.Fatal("rejected protect session became globally visible")
	}
}

// TestProtectSocketWaitsForAckAndFailsOpenGrace 验证 v3 语义:
// 无回执时等待上限≈protectWaitTimeout 后放行(fail-open), 有按 fd 回执时快速放行。
func TestProtectSocketRequiresPositiveAck(t *testing.T) {
	previous := protectRequired.Load()
	protectRequired.Store(true)
	defer protectRequired.Store(previous)
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatalf("create protect pipe: %v", err)
	}
	t.Cleanup(func() {
		replaceProtectSession(nil)
		_ = writePipe.Close()
		_ = readPipe.Close()
	})

	session := newProtectSession()
	session.writer = writePipe
	writeFd := int(writePipe.Fd())
	if err := syscall.SetNonblock(writeFd, true); err != nil {
		t.Fatalf("set nonblock: %v", err)
	}
	session.writerFd = writeFd
	if !installProtectSession(session) {
		t.Fatal("protect session was unexpectedly rejected")
	}

	// 1) 无读者: 单次调用应在 grace 内返回 nil, 且 (fd, seq) 记录已写入管道。
	_ = readPipe.SetDeadline(time.Now().Add(30 * time.Second))
	started := time.Now()
	if err := protectSocket("tcp", "example.com:443", fixedRawConn(42)); !errors.Is(err, ErrSocketUnprotected) {
		t.Fatalf("unacknowledged VPN dial was not blocked: %v", err)
	}
	elapsed := time.Since(started)
	if elapsed < protectWaitTimeout/2 || elapsed > protectWaitTimeout+3*time.Second {
		t.Fatalf("fail-open elapsed = %v, want ≈%v", elapsed, protectWaitTimeout)
	}
	var encoded [8]byte
	if _, err := io.ReadFull(readPipe, encoded[:]); err != nil {
		t.Fatalf("read protect request: %v", err)
	}
	if fd := binary.LittleEndian.Uint32(encoded[0:4]); fd != 42 {
		t.Fatalf("protect fd = %d, want 42", fd)
	}
	if seq := binary.LittleEndian.Uint32(encoded[4:8]); seq == 0 {
		t.Fatal("protect seq must start from 1")
	}

	// 2) 带读者(模拟 ArkTS monitor): 按 seq 回执应并发唤醒各自的等待者。
	pumpDone := make(chan struct{})
	go func() {
		defer close(pumpDone)
		buf := make([]byte, 8)
		for i := 0; i < 8; i++ {
			if _, err := io.ReadFull(readPipe, buf); err != nil {
				return
			}
			SetProtectResultForFd(binary.LittleEndian.Uint32(buf[0:4]),
				binary.LittleEndian.Uint32(buf[4:8]), true)
		}
	}()
	results := make(chan time.Duration, 8)
	waitStart := time.Now()
	for i := 100; i < 108; i++ {
		go func(fd uintptr) {
			begin := time.Now()
			if err := protectSocket("tcp", "example.com:443", fixedRawConn(fd)); err != nil {
				t.Errorf("concurrent protect failed: %v", err)
			}
			results <- time.Since(begin)
		}(uintptr(i))
	}
	for i := 0; i < 8; i++ {
		select {
		case d := <-results:
			if d > protectWaitTimeout {
				t.Fatalf("acked protect took %v, want concurrent wake (< %v)", d, protectWaitTimeout)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("concurrent protect waiters were not woken by per-fd acks")
		}
	}
	if total := time.Since(waitStart); total > protectWaitTimeout {
		// 并发验证: 串行实现至少要 8×grace 的一半, 并发应远低于单次 grace。
		t.Logf("8 concurrent acked protects total %v (grace=%v)", total, protectWaitTimeout)
	}
	<-pumpDone

	// 3) 会话退役: 等待者立即放行(不挂 grace 时长), 管道 EOF。
	retireProtectSession(session)
	retireStarted := time.Now()
	if err := protectSocket("tcp", "example.com:443", fixedRawConn(7)); !errors.Is(err, ErrSocketUnprotected) {
		t.Fatalf("retired VPN protector allowed dial: %v", err)
	}
	if time.Since(retireStarted) > time.Second {
		t.Fatal("protect did not skip a retired session promptly")
	}
	var trailing [1]byte
	if _, err := readPipe.Read(trailing[:]); !errors.Is(err, io.EOF) {
		t.Fatalf("protect monitor pipe error = %v, want EOF", err)
	}
}

func TestTunStartGateRejectsSessionClearedByCompletedStop(t *testing.T) {
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		t.Fatalf("create protect pipe: %v", err)
	}

	coreMu.Lock()
	releaseProtectLocked()
	protectRead = readPipe
	protectWrite = writePipe
	session := newProtectSession()
	session.writer = writePipe
	if !installProtectSession(session) {
		coreMu.Unlock()
		t.Fatal("protect session was unexpectedly rejected")
	}

	stopReturned := make(chan struct{})
	go func() {
		Stop()
		close(stopReturned)
	}()
	select {
	case <-session.done:
	case <-time.After(time.Second):
		coreMu.Unlock()
		t.Fatal("Stop did not cancel protect before waiting for coreMu")
	}
	coreMu.Unlock()
	select {
	case <-stopReturned:
	case <-time.After(time.Second):
		t.Fatal("Stop did not complete")
	}

	if protectReadyForStart(42) {
		t.Fatal("TUN start remained allowed after Stop cleared its protect session")
	}
}

func TestConcurrentStopsRejectSessionInstallUntilBothReturn(t *testing.T) {
	replaceProtectSession(nil)
	if count := protectStopRequests.Load(); count != 0 {
		t.Fatalf("pending stop count = %d, want 0", count)
	}

	coreMu.Lock()
	coreLocked := true
	defer func() {
		if coreLocked {
			coreMu.Unlock()
		}
	}()

	stopReturned := make(chan struct{}, 2)
	for i := 0; i < 2; i++ {
		go func() {
			Stop()
			stopReturned <- struct{}{}
		}()
	}
	deadline := time.Now().Add(time.Second)
	for protectStopRequests.Load() != 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if count := protectStopRequests.Load(); count != 2 {
		t.Fatalf("pending stop count = %d, want 2", count)
	}

	candidate := newProtectSession()
	if installProtectSession(candidate) {
		t.Fatal("protect session was installed while concurrent Stops were pending")
	}
	if candidate.active() {
		t.Fatal("rejected protect session remained active")
	}

	coreMu.Unlock()
	coreLocked = false
	for i := 0; i < 2; i++ {
		select {
		case <-stopReturned:
		case <-time.After(time.Second):
			t.Fatal("concurrent Stop did not return")
		}
	}
	if count := protectStopRequests.Load(); count != 0 {
		t.Fatalf("pending stop count = %d after return, want 0", count)
	}
}

func TestInitProtectTransfersDuplicateReaderAcrossStop(t *testing.T) {
	Stop()
	transferFd := InitProtect()
	if transferFd <= 0 {
		t.Fatalf("InitProtect fd = %d, want a transferred descriptor", transferFd)
	}
	transferRead := os.NewFile(uintptr(transferFd), "protect-transfer-read")
	if transferRead == nil {
		t.Fatal("could not adopt transferred protect descriptor")
	}
	defer func() {
		if err := transferRead.Close(); err != nil {
			t.Errorf("close transferred protect descriptor: %v", err)
		}
	}()

	Stop()
	var trailing [1]byte
	if count, err := transferRead.Read(trailing[:]); count != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("transferred reader after Stop = (%d, %v), want (0, EOF)", count, err)
	}
}

func TestHeadlessPhysicalBinderFailsClosedAndDoesNotReplaceVPNProtection(t *testing.T) {
	previousRequired := protectRequired.Swap(false)
	previous := currentProtectSession()
	replaceProtectSession(nil)
	defer func() {
		SetHeadlessSocketBinder(nil)
		protectRequired.Store(previousRequired)
		replaceProtectSession(previous)
	}()
	calls := 0
	bindError := errors.New("physical network disappeared")
	SetHeadlessSocketBinder(func(fd int) error {
		calls++
		if fd != 42 {
			t.Fatalf("wrong fd: %d", fd)
		}
		return bindError
	})
	if err := protectSocket("tcp", "example.com:443", fixedRawConn(42)); !errors.Is(err, bindError) {
		t.Fatalf("headless dial must fail closed: %v", err)
	}
	if calls != 1 {
		t.Fatalf("binder not called: %d", calls)
	}
	protectRequired.Store(true)
	if err := protectSocket("tcp", "example.com:443", fixedRawConn(42)); !errors.Is(err, ErrSocketUnprotected) {
		t.Fatalf("VPN must still require its own protection receipt: %v", err)
	}
	if calls != 1 {
		t.Fatal("headless binder bypassed VPN protect gate")
	}
	SetHeadlessSocketBinder(nil)
	if err := protectSocket("udp", "dns.example:53", fixedRawConn(42)); !errors.Is(err, ErrSocketUnprotected) {
		t.Fatalf("clearing the headless binder must not bypass VPN protection: %v", err)
	}
	protectRequired.Store(false)
	if err := protectSocket("udp", "dns.example:53", fixedRawConn(42)); err != nil {
		t.Fatalf("subscription DNS after headless cleanup must use the ordinary route: %v", err)
	}
	if calls != 1 {
		t.Fatal("subscription DNS reused the retired headless binder")
	}
}

// A completed protect(fd) Promise may outlive its monitor and InitProtect.
func TestProtectReceiptCannotCrossSessionRestart(t *testing.T) {
	old := newProtectSession()
	_, oldSeq := old.registerWaiter()
	old.cancel()
	next := newProtectSession()
	replaceProtectSession(next)
	t.Cleanup(func() { replaceProtectSession(nil) })
	entry, nextSeq := next.registerWaiter()
	if oldSeq == nextSeq || nextSeq == 0 {
		t.Fatal("protect receipt reused across sessions")
	}
	// Even reuse of the same OS fd must not let the old callback authorize it.
	SetProtectResultForFd(42, oldSeq, true)
	select {
	case <-entry.ch:
		t.Fatal("late callback authorized a new session's socket")
	default:
	}
	SetProtectResultForFd(42, nextSeq, true)
	select {
	case ok := <-entry.ch:
		if !ok {
			t.Fatal("current callback rejected")
		}
	default:
		t.Fatal("current callback not delivered")
	}
}

func TestProtectReceiptSequenceExhaustionFailsClosed(t *testing.T) {
	previous := protectSequence.Load()
	t.Cleanup(func() { protectSequence.Store(previous) })
	protectSequence.Store(^uint32(0) - 1)
	session := newProtectSession()
	entry, seq := session.registerWaiter()
	if entry == nil || seq != ^uint32(0) {
		t.Fatal("last unique token was lost")
	}
	for i := 0; i < 3; i++ {
		entry, seq = newProtectSession().registerWaiter()
		if entry != nil || seq != 0 {
			t.Fatal("sequence wrapped and reused an old token")
		}
	}
}
