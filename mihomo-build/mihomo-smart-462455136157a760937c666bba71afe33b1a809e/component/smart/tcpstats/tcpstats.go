package tcpstats

import (
	"sync"
	"time"
)

// The sampler holds increments until the window clears this floor.
const (
	lossWindowMinSegs   = 64
	lossWindowMinBytes  = 64 << 10
	lossSamplerCapacity = 4096
)

// The interval is a variable so a test can shrink it instead of waiting it out.
var lossSamplerTTL = 30 * time.Minute

type Stats struct {
	BytesSent    uint64
	BytesRetrans uint64
	SegsOut      uint64
	RetransSegs  uint64
}

type lossSamplerEntry struct {
	segs         uint64 // counters at the last judged window
	retransSegs  uint64
	bytesSent    uint64
	bytesRetrans uint64
	updated      time.Time // the last read, so an idle socket expires
}

// LossSampler judges one socket's counters in windows: increments below the window floor
// are held and accumulate, and a judged window is consumed exactly once.
type LossSampler struct {
	mu      sync.Mutex
	entries map[uint64]lossSamplerEntry
}

func NewLossSampler() *LossSampler {
	return &LossSampler{entries: make(map[uint64]lossSamplerEntry)}
}

func (s *Stats) LossRate() float64 {
	if s == nil {
		return 0
	}
	var rate float64
	if s.SegsOut > 0 {
		rate = float64(s.RetransSegs) / float64(s.SegsOut)
	} else if s.BytesSent > 0 {
		rate = float64(s.BytesRetrans) / float64(s.BytesSent)
	} else {
		return 0
	}
	if rate > 1 {
		return 1
	}
	return rate
}

func (s *Stats) TotalSent() uint64 {
	if s == nil {
		return 0
	}
	if s.SegsOut > 0 {
		return s.SegsOut
	}
	return s.BytesSent
}

func (s *Stats) TotalRetrans() uint64 {
	if s == nil {
		return 0
	}
	if s.RetransSegs > 0 || s.SegsOut > 0 {
		return s.RetransSegs
	}
	return s.BytesRetrans
}

func (s *Stats) meetsLossWindowFloor() bool {
	if s == nil {
		return false
	}
	if s.SegsOut > 0 {
		return s.SegsOut >= lossWindowMinSegs
	}
	return s.BytesSent >= lossWindowMinBytes
}

// Consume returns the judged window this read completes: the counters accumulated since
// the last judged window, or nil while they are still below the floor or unchanged.
func (s *LossSampler) Consume(source uint64, stats *Stats) *Stats {
	if stats == nil {
		return nil
	}
	if s == nil || source == 0 {
		// no identity to accumulate on, judge the read itself once it clears the floor
		if stats.meetsLossWindowFloor() {
			return stats
		}
		return nil
	}

	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()

	entry, known := s.entries[source]
	if known && (stats.SegsOut < entry.segs ||
		stats.RetransSegs < entry.retransSegs ||
		stats.BytesSent < entry.bytesSent ||
		stats.BytesRetrans < entry.bytesRetrans) {
		known = false // counters going backwards mean the pointer now holds a fresh socket
	}
	if known && now.Sub(entry.updated) > lossSamplerTTL {
		known = false // a long gap rereads the lifetime counters of a possibly new socket
	}
	if !known {
		if len(s.entries) >= lossSamplerCapacity {
			s.evictLocked(now)
		}
		entry = lossSamplerEntry{}
	}
	entry.updated = now

	window := Stats{
		SegsOut:      stats.SegsOut - entry.segs,
		RetransSegs:  stats.RetransSegs - entry.retransSegs,
		BytesSent:    stats.BytesSent - entry.bytesSent,
		BytesRetrans: stats.BytesRetrans - entry.bytesRetrans,
	}
	if !window.meetsLossWindowFloor() {
		s.entries[source] = entry // keep the anchor, the window keeps accumulating
		return nil
	}

	s.entries[source] = lossSamplerEntry{
		segs:         stats.SegsOut,
		retransSegs:  stats.RetransSegs,
		bytesSent:    stats.BytesSent,
		bytesRetrans: stats.BytesRetrans,
		updated:      now,
	}
	return &window
}

func (s *LossSampler) evictLocked(now time.Time) {
	for key, entry := range s.entries {
		if now.Sub(entry.updated) > lossSamplerTTL {
			delete(s.entries, key)
		}
	}
	// the map order is random; a dropped entry just restarts its window
	for key := range s.entries {
		if len(s.entries) < lossSamplerCapacity {
			break
		}
		delete(s.entries, key)
	}
}
