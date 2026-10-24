//go:build !linux

package tls

import "net"

// eraseRealityClientHelloLinux is a no-op on platforms where the socket receive
// queue cannot be reaped from userspace (Windows, macOS, BSD). The REALITY
// version negotiation therefore cannot retry on the same connection there and
// reports the failure immediately.
func eraseRealityClientHelloLinux(fd uintptr, conn *net.TCPConn) error {
	return net.ErrClosed
}
