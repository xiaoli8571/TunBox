package bridge

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
)

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

func TestProtectSocketFailsOpenWithoutSession(t *testing.T) {
	replaceProtectSession(nil)
	// 新语义: protect 通知只是兜底提示(进程级 protectProcessNet 才是主保障),
	// 没有会话时也必须放行拨号, 绝不能让 dial 失败。
	if err := protectSocket("tcp", "example.com:443", nil); err != nil {
		t.Fatalf("protect dispatcher blocked a socket without a monitor: %v", err)
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
func TestProtectSocketWaitsForAckAndFailsOpenGrace(t *testing.T) {
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
	if err := protectSocket("tcp", "example.com:443", fixedRawConn(42)); err != nil {
		t.Fatalf("protect socket blocked the dial with an error: %v", err)
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
	if err := protectSocket("tcp", "example.com:443", fixedRawConn(7)); err != nil {
		t.Fatalf("protect after retire: %v", err)
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
