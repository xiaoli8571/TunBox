package callback

import (
	"errors"
	"net"
	"os"

	"github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/common/buf"
	C "github.com/metacubex/mihomo/constant"
)

// errorCallBackConn records the first non-nil error of each direction so a
// connection that dies mid-transfer is not reported as a success.
// It must not implement the replaceable protocol or SyscallConn: the copy
// engine would peel it and the record would go blind for the fast paths.
type errorCallBackConn struct {
	C.Conn
	readErr  *atomic.TypedValue[error]
	writeErr *atomic.TypedValue[error]
}

// our own close and a transient deadline must not be charged to the node
func isConnectionLifecycle(err error) bool {
	return errors.Is(err, net.ErrClosed) || errors.Is(err, os.ErrDeadlineExceeded)
}

func (c *errorCallBackConn) record(slot *atomic.TypedValue[error], err error) {
	if err == nil || isConnectionLifecycle(err) {
		return
	}
	slot.CompareAndSwap(nil, err)
}

func (c *errorCallBackConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.record(c.readErr, err)
	return n, err
}

func (c *errorCallBackConn) ReadBuffer(buffer *buf.Buffer) error {
	err := c.Conn.ReadBuffer(buffer)
	c.record(c.readErr, err)
	return err
}

func (c *errorCallBackConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.record(c.writeErr, err)
	return n, err
}

func (c *errorCallBackConn) WriteBuffer(buffer *buf.Buffer) error {
	err := c.Conn.WriteBuffer(buffer)
	c.record(c.writeErr, err)
	return err
}

func (c *errorCallBackConn) Upstream() any {
	return c.Conn
}

func NewErrorCallBackConn(c C.Conn, readErr, writeErr *atomic.TypedValue[error]) C.Conn {
	return &errorCallBackConn{Conn: c, readErr: readErr, writeErr: writeErr}
}

// errorCallBackPacketConn is the udp counterpart of errorCallBackConn and
// shares its peel contract. The ICMP refusal of the far side is filtered: it
// must not be charged to the node.
type errorCallBackPacketConn struct {
	C.PacketConn
	readErr  *atomic.TypedValue[error]
	writeErr *atomic.TypedValue[error]
}

func (c *errorCallBackPacketConn) record(slot *atomic.TypedValue[error], err error) {
	if err == nil || isConnectionLifecycle(err) || isICMPRefusal(err) {
		return
	}
	slot.CompareAndSwap(nil, err)
}

func (c *errorCallBackPacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, addr, err := c.PacketConn.ReadFrom(b)
	c.record(c.readErr, err)
	return n, addr, err
}

func (c *errorCallBackPacketConn) WaitReadFrom() (data []byte, put func(), addr net.Addr, err error) {
	data, put, addr, err = c.PacketConn.WaitReadFrom()
	c.record(c.readErr, err)
	return
}

func (c *errorCallBackPacketConn) WriteTo(b []byte, addr net.Addr) (int, error) {
	n, err := c.PacketConn.WriteTo(b, addr)
	c.record(c.writeErr, err)
	return n, err
}

func (c *errorCallBackPacketConn) Upstream() any {
	return c.PacketConn
}

func NewErrorCallBackPacketConn(pc C.PacketConn, readErr, writeErr *atomic.TypedValue[error]) C.PacketConn {
	return &errorCallBackPacketConn{PacketConn: pc, readErr: readErr, writeErr: writeErr}
}
