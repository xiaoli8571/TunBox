//go:build aix || android || darwin || dragonfly || freebsd || illumos || ios || linux || netbsd || openbsd || solaris

package callback

import (
	"errors"
	"syscall"
)

// isICMPRefusal reports the ICMP answer of a peer whose udp port is closed.
// The unix kernels map it to ECONNREFUSED and a udp ECONNRESET is ICMP derived
// as well. They only deliver it on connected sockets (go leaves IP_RECVERR off),
// so this mostly guards connected relays and errors of wrapped carriers.
func isICMPRefusal(err error) bool {
	return errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ECONNRESET)
}
