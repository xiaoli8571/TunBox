package bridge

import (
	"errors"
	"time"
)

var ErrSocketUnprotected = errors.New("VPN socket protection failed; outbound blocked")

// Only a positive acknowledgement may release a VPN socket to connect().
// A closed/cancelled channel is not a successful acknowledgement.
func awaitProtectResult(done <-chan struct{}, ack <-chan bool, timeout time.Duration) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case ok := <-ack:
		if ok {
			select {
			case <-done:
				return ErrSocketUnprotected
			default:
				return nil
			}
		}
	case <-done:
	case <-timer.C:
	}
	return ErrSocketUnprotected
}
