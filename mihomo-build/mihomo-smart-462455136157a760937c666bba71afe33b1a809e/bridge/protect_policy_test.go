package bridge

import (
	"errors"
	"testing"
	"time"
)

func TestProtectPolicyRequiresPositiveAck(t *testing.T) {
	for _, ok := range []bool{true, false} {
		ack := make(chan bool, 1)
		ack <- ok
		err := awaitProtectResult(make(chan struct{}), ack, time.Second)
		if (err == nil) != ok {
			t.Fatalf("ack=%v err=%v", ok, err)
		}
	}
}

func TestProtectPolicyRejectsTimeoutCancellationAndClosedAck(t *testing.T) {
	done := make(chan struct{})
	close(done)
	closed := make(chan bool)
	close(closed)
	positive := make(chan bool, 1)
	positive <- true
	for _, err := range []error{
		awaitProtectResult(done, positive, time.Second),
		awaitProtectResult(done, make(chan bool), time.Second),
		awaitProtectResult(make(chan struct{}), closed, time.Second),
		awaitProtectResult(make(chan struct{}), make(chan bool), time.Millisecond),
	} {
		if !errors.Is(err, ErrSocketUnprotected) {
			t.Fatalf("unsafe release: %v", err)
		}
	}
}
