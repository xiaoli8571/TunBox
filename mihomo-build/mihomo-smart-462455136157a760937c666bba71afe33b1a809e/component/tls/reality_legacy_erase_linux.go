//go:build linux

package tls

import (
	"net"
	"syscall"
	"time"
	"unsafe"
)

// linuxIoctlFionread is the number of bytes available to read (as FIONREAD).
const linuxIoctlFionread = 0x541B

// eraseRealityClientHelloLinux discards everything queued in the socket's
// receive queue, so a second ClientHello can be written on the same fd after
// the first one already reached the peer and was answered.
//
// It relies on two Linux-specific behaviours:
//
//   - MSG_PEEK|MSG_TRUNC makes recv() report the length of the whole queued
//     chunk (skb->len) without copying or consuming it. For a TCP socket that
//     is the number of bytes sitting in the receive queue.
//   - SIOCINQ (FIONREAD) reports the unread byte count, so we can wait until
//     the peer's reply has fully arrived before dropping it.
//
// Any error simply disables the fallback attempt: the caller propagates the
// original failure instead of risking a corrupted stream.
func eraseRealityClientHelloLinux(fd uintptr, conn *net.TCPConn) error {
	pending, err := socketBytesPending(fd)
	if err != nil {
		return err
	}
	if pending == 0 {
		// The peer replied with nothing (for example a bare FIN) or the queue
		// was already drained, either way there is nothing to throw away.
		return nil
	}

	var buf [4096]byte
	deadline := time.Now().Add(2 * time.Second)
	for pending > 0 && time.Now().Before(deadline) {
		n, _, err := syscall.Recvfrom(int(fd), buf[:], 0)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			return err
		}
		if n == 0 {
			// EOF: mark the conn as clean so a failed read does not poison it.
			_ = conn.SetReadDeadline(time.Unix(1, 0))
			_ = conn.SetReadDeadline(time.Time{})
			break
		}
		pending, err = socketBytesPending(fd)
		if err != nil {
			return err
		}
	}
	return nil
}

// socketBytesPending returns the number of bytes currently queued in the
// socket's receive buffer.
func socketBytesPending(fd uintptr) (int, error) {
	var pending int32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, linuxIoctlFionread, uintptr(unsafe.Pointer(&pending)))
	if errno != 0 {
		return 0, errno
	}
	if pending < 0 {
		pending = 0
	}
	return int(pending), nil
}
