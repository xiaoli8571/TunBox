package bridge

import (
	"encoding/json"
	"github.com/metacubex/mihomo/component/memory"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

var resourceStop chan struct{}
var resourceExited chan struct{}
var resourceHome string

type resourceSnapshot struct {
	SampledAt        int64  `json:"sampledAt"`
	PID              int    `json:"pid"`
	RSSBytes         uint64 `json:"rssBytes"`
	HeapAlloc        uint64 `json:"heapAlloc"`
	HeapInuse        uint64 `json:"heapInuse"`
	HeapSys          uint64 `json:"heapSys"`
	HeapReleased     uint64 `json:"heapReleased"`
	Sys              uint64 `json:"sys"`
	NumGC            uint32 `json:"numGC"`
	Goroutines       int    `json:"goroutines"`
	FDCount          int    `json:"fdCount"`
	FDCountCapped    bool   `json:"fdCountCapped"`
	Connections      int    `json:"connections"`
	ProtectRequired  bool   `json:"protectRequired"`
	ProtectFailures  uint64 `json:"protectFailures"`
	ProtectSuccesses uint64 `json:"protectSuccesses"`
}

// Called under coreMu; no API polling and no synchronous ArkTS work are required.
func startResourceSampler() {
	stopResourceSampler()
	if resourceHome == "" {
		return
	}
	done := make(chan struct{})
	resourceStop = done
	exited := make(chan struct{})
	resourceExited = exited
	home := resourceHome
	go func() {
		defer close(exited)
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		history := &RotatingLog{Path: filepath.Join(home, "core_resources.jsonl"), MaxBytes: 1024 * 1024, Backups: 2}
		for {
			var mem runtime.MemStats
			runtime.ReadMemStats(&mem)
			s := resourceSnapshot{SampledAt: time.Now().UnixMilli(), PID: os.Getpid(), HeapAlloc: mem.HeapAlloc, HeapInuse: mem.HeapInuse, HeapSys: mem.HeapSys, HeapReleased: mem.HeapReleased, Sys: mem.Sys, NumGC: mem.NumGC, Goroutines: runtime.NumGoroutine(), FDCount: -1, ProtectRequired: protectRequired.Load(), ProtectFailures: protectFailures.Load(), ProtectSuccesses: protectSuccesses.Load()}
			if m, err := memory.GetMemoryInfo(int32(s.PID)); err == nil {
				s.RSSBytes = m.RSS
			}
			if f, err := os.Open("/proc/self/fd"); err == nil {
				entries, _ := f.ReadDir(4096)
				s.FDCount = len(entries)
				s.FDCountCapped = len(entries) == 4096
				_ = f.Close()
			}
			statistic.DefaultManager.Range(func(_ statistic.Tracker) bool { s.Connections++; return true })
			data, _ := json.Marshal(s)
			select {
			case <-done:
				return
			default:
			}
			target := filepath.Join(home, "core_resources.json")
			if os.WriteFile(target+".tmp", data, 0600) == nil {
				_ = os.Rename(target+".tmp", target)
			}
			_, _ = history.Write(append(data, '\n'))
			select {
			case <-done:
				return
			case <-ticker.C:
			}
		}
	}()
}

func stopResourceSampler() {
	if resourceStop != nil {
		close(resourceStop)
		resourceStop = nil
		<-resourceExited
		resourceExited = nil
	}
}
