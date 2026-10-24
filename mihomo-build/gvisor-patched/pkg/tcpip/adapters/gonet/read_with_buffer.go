// Copyright 2026 The gVisor Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package gonet

import (
	"io"
	"net"
	"net/netip"
	"syscall"

	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/waiter"
)

// ReadWithBuffer reads from the connection, obtaining the destination buffer
// lazily from getBuffer.
//
// getBuffer is called at most once, and only after the endpoint has become
// readable. The callback receives an advisory size hint and is called without
// an endpoint lock held. The callback must return promptly and must not call a
// read method on the connection. The caller owns the returned slice, including
// when this method returns an error after invoking the callback.
//
// A nil callback is rejected with EINVAL. This method is experimental and is
// not covered by the package's stability guarantees.
func (c *TCPConn) ReadWithBuffer(getBuffer func(sizeHint int) []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	n, err := commonReadWithBuffer(getBuffer, c.ep, c.wq, c.readCancel(), nil, c)
	if n != 0 {
		c.ep.ModerateRecvBuf(n)
	}
	return n, err
}

// ReadWithBuffer reads from a UDP endpoint, obtaining the
// destination buffer lazily from getBuffer.
//
// getBuffer is called at most once, and only after a datagram has become
// readable. The callback receives the complete datagram length as an advisory
// size hint and is called without an endpoint lock held. The callback must
// return promptly and must not call a read method on the connection. The
// caller owns the returned slice, including when this method returns an error
// after invoking the callback.
//
// A nil callback is rejected with EINVAL. A short returned slice has the same
// truncation behavior as Read. This method is experimental and is not covered
// by the package's stability guarantees.
func (c *UDPConn) ReadWithBuffer(getBuffer func(sizeHint int) []byte) (int, error) {
	return commonReadWithBuffer(getBuffer, c.ep, c.wq, c.readCancel(), nil, c)
}

// ReadFromWithBuffer reads from a UDP endpoint, obtaining the destination
// buffer lazily from getBuffer and returning the source address.
//
// getBuffer is called at most once, and only after a datagram has become
// readable. The callback receives the complete datagram length as an advisory
// size hint and is called without an endpoint lock held. The callback must
// return promptly and must not call a read method on the connection. The
// caller owns the returned slice, including when this method returns an error
// after invoking the callback.
//
// A nil callback is rejected with EINVAL. A short returned slice has the same
// truncation behavior as ReadFrom. This method is experimental and is not
// covered by the package's stability guarantees.
func (c *UDPConn) ReadFromWithBuffer(getBuffer func(sizeHint int) []byte) (int, net.Addr, error) {
	var address tcpip.FullAddress
	n, err := commonReadWithBuffer(getBuffer, c.ep, c.wq, c.readCancel(), &address, c)
	if err != nil {
		return 0, nil, err
	}
	return n, fullToUDPAddr(address), nil
}

// ReadFromUDPAddrPortWithBuffer is the netip.AddrPort form of
// ReadFromWithBuffer.
//
// It has the same callback, buffer ownership, truncation, and nil-callback
// semantics as ReadFromWithBuffer. This method is experimental and is not
// covered by the package's stability guarantees.
func (c *UDPConn) ReadFromUDPAddrPortWithBuffer(getBuffer func(sizeHint int) []byte) (int, netip.AddrPort, error) {
	var address tcpip.FullAddress
	n, err := commonReadWithBuffer(getBuffer, c.ep, c.wq, c.readCancel(), &address, c)
	if err != nil {
		return 0, netip.AddrPort{}, err
	}
	return n, fullToUDPAddrPort(address), nil
}

const readWithBufferEvents = waiter.ReadableEvents | waiter.EventErr | waiter.EventHUp | waiter.EventRdHUp

// readWithBufferReady reports whether an endpoint can be read and returns an
// advisory size hint. ReceiveQueueSizeOption is only a hint: it may be
// unsupported or zero for a zero-length datagram. A peek distinguishes those
// cases from terminal readiness without consuming endpoint data.
func readWithBufferReady(ep tcpip.Endpoint) (int, bool, tcpip.Error) {
	if size, err := ep.GetSockOptInt(tcpip.ReceiveQueueSizeOption); err == nil && size > 0 {
		return size, true, nil
	}

	result, readErr := ep.Read(io.Discard, tcpip.ReadOptions{Peek: true})
	if readErr == nil {
		return int(result.Total), true, nil
	}
	if _, wouldBlock := readErr.(*tcpip.ErrWouldBlock); wouldBlock {
		return 0, false, nil
	}
	return 0, false, readErr
}

func readWithBufferError(err tcpip.Error, errorer opErrorer) error {
	if _, closed := err.(*tcpip.ErrClosedForReceive); closed {
		return io.EOF
	}
	return errorer.newOpError("read", TranslateNetstackError(err))
}

// waitForReadWithBuffer waits until ep has readable data or reaches a
// terminal state, without obtaining a caller-owned buffer.
func waitForReadWithBuffer(ep tcpip.Endpoint, wq *waiter.Queue, deadline <-chan struct{}, errorer opErrorer) (int, error) {
	select {
	case <-deadline:
		return 0, errorer.newOpError("read", &timeoutError{})
	default:
	}

	size, ready, err := readWithBufferReady(ep)
	if err != nil {
		return 0, readWithBufferError(err, errorer)
	}
	if ready {
		return size, nil
	}

	waitEntry, notifyCh := waiter.NewChannelEntry(readWithBufferEvents)
	wq.EventRegister(&waitEntry)
	defer wq.EventUnregister(&waitEntry)

	for {
		// The endpoint may have become readable between the first check and
		// registration. Recheck while the entry is installed to avoid a lost
		// wakeup.
		size, ready, err = readWithBufferReady(ep)
		if err != nil {
			return 0, readWithBufferError(err, errorer)
		}
		if ready {
			return size, nil
		}

		select {
		case <-deadline:
			return 0, errorer.newOpError("read", &timeoutError{})
		case <-notifyCh:
		}
	}
}

// commonReadWithBuffer implements the lazy-buffer form of commonRead. The
// callback is invoked after readiness has been observed and before the first
// actual read, so an idle endpoint never causes a caller buffer allocation.
func commonReadWithBuffer(
	getBuffer func(sizeHint int) []byte,
	ep tcpip.Endpoint,
	wq *waiter.Queue,
	deadline <-chan struct{},
	addr *tcpip.FullAddress,
	errorer opErrorer,
) (int, error) {
	if getBuffer == nil {
		return 0, errorer.newOpError("read", syscall.EINVAL)
	}

	sizeHint, err := waitForReadWithBuffer(ep, wq, deadline, errorer)
	if err != nil {
		return 0, err
	}

	// Keep the deadline check immediately before the callback. A deadline
	// that expired while readiness was being inspected must not cause a
	// caller buffer allocation.
	select {
	case <-deadline:
		return 0, errorer.newOpError("read", &timeoutError{})
	default:
	}

	buffer := getBuffer(sizeHint)
	opts := tcpip.ReadOptions{NeedRemoteAddr: addr != nil}
	for {
		writer := tcpip.SliceWriter(buffer)
		result, readErr := ep.Read(&writer, opts)
		if _, wouldBlock := readErr.(*tcpip.ErrWouldBlock); wouldBlock {
			// A concurrent UDP reader may consume the data after readiness was
			// observed. Keep the one caller-owned buffer and wait for the next
			// datagram instead of invoking the callback a second time.
			if _, err = waitForReadWithBuffer(ep, wq, deadline, errorer); err != nil {
				return 0, err
			}
			continue
		}

		if readErr != nil {
			return 0, readWithBufferError(readErr, errorer)
		}
		if addr != nil {
			*addr = result.RemoteAddr
		}
		return result.Count, nil
	}
}

func fullToUDPAddrPort(addr tcpip.FullAddress) netip.AddrPort {
	ip, ok := netip.AddrFromSlice(addr.Addr.AsSlice())
	if !ok {
		return netip.AddrPort{}
	}
	return netip.AddrPortFrom(ip, addr.Port)
}
