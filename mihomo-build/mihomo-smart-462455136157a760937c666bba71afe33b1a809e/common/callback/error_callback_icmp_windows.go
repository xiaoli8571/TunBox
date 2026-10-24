//go:build windows

package callback

import (
	"errors"
	"syscall"
)

// isICMPRefusal reports the ICMP answer of a peer whose udp port is closed.
// Windows delivers it on connected sockets as WSAECONNRESET (10054) or
// WSAECONNREFUSED (10061, not exported by the syscall package); the posix style
// constants are kept for errors surfaced by wrapped transports. Note go turns
// the port/net unreachable reporting of unconnected sockets off, so only
// connected sockets can raise it here.
func isICMPRefusal(err error) bool {
	return errors.Is(err, syscall.WSAECONNRESET) ||
		errors.Is(err, syscall.Errno(10061)) ||
		errors.Is(err, syscall.ECONNREFUSED) ||
		errors.Is(err, syscall.ECONNRESET)
}
