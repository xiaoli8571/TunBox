package smart

import (
	"container/heap"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/common/lru"
	"github.com/metacubex/mihomo/common/xsync"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

const (
	asnEvidencePrefix = "asn:"

	RankMostUsed   = "MostUsed"
	RankOccasional = "OccasionalUsed"
	RankRarelyUsed = "RarelyUsed"

	HostFailureNodeTTL       = 24 * time.Hour
	hostStatusRetryAfter     = 4 * time.Hour
	hostStatusViewTTLSeconds = 30

	// packet loss needs this many strikes within the window
	hostStrikeWindow = 5 * time.Minute
	hostStrikeLimit  = 2

	RecordExpiredTime = 7 * 24 * time.Hour

	asnEvidenceRebuildInterval = 30 * time.Minute
)

var (
	asnEvidenceCache xsync.Map[string, *asnEvidenceEntry]

	shardedLocks     [1024]*sync.Mutex
	shardedLocksOnce sync.Once
)

type asnEvidenceEntry struct {
	mutex   sync.Mutex
	updated time.Time
	data    map[string]map[string]int
}

type StatsRecord struct {
	Success            int64              `json:"success"`
	Failure            int64              `json:"failure"`
	ConnectTime        int64              `json:"connect_time"`
	Latency            int64              `json:"latency"`
	LastUsed           int64              `json:"last_used"`
	Weights            map[string]float64 `json:"weights"`
	UploadTotal        float64            `json:"upload_total"`
	DownloadTotal      float64            `json:"download_total"`
	MaxUploadRate      float64            `json:"max_upload_rate"`
	MaxDownloadRate    float64            `json:"max_download_rate"`
	ConnectionDuration float64            `json:"connection_duration"`
	LossRate           float64            `json:"loss_rate,omitempty"`
	CumulSent          uint64             `json:"cumul_sent,omitempty"`
	CumulRetrans       uint64             `json:"cumul_retrans,omitempty"`
}

type NodeState struct {
	Name           string `json:"name"`
	LastChecked    int64  `json:"last_checked"`
	BlockedUntil   int64  `json:"blocked_until"`
	ThresholdGrade int    `json:"threshold_grade,omitempty"`
	ExitRegion     string `json:"exit_region,omitempty"`
	ExitASN        string `json:"exit_asn,omitempty"`
	ExitKey        string `json:"exit_key,omitempty"`
	ExitUpdated    int64  `json:"exit_updated,omitempty"`
	ExitFailed     int64  `json:"exit_failed,omitempty"`
}

type AtomicStatsRecord struct {
	success     atomic.Int64
	failure     atomic.Int64
	connectTime atomic.Int64
	latency     atomic.Int64
	lastUsed    atomic.Int64

	uploadTotal     atomic.Float64
	downloadTotal   atomic.Float64
	duration        atomic.Float64
	maxUploadRate   atomic.Float64
	maxDownloadRate atomic.Float64
	lossRate        atomic.Float64
	cumulSent       atomic.Int64
	cumulRetrans    atomic.Int64

	weights *lru.LruCache[string, float64]
}

type CodeNodeSet struct {
	Nodes         map[string]int64  `json:"nodes"`
	FailCounts    map[string]int    `json:"fail_counts,omitempty"`
	Confirmations map[string]int    `json:"confirmations,omitempty"` // code 5 ladder memory
	NodeHosts     map[string]string `json:"node_hosts,omitempty"`
}

type HostStatus struct {
	initOnce    sync.Once            `json:"-"`
	mu          sync.RWMutex         `json:"-"`
	LastFailure int64                `json:"last_failure,omitempty"`
	LastCheck   int64                `json:"last_check,omitempty"`
	Blocked     bool                 `json:"blocked,omitempty"`
	Codes       map[int]*CodeNodeSet `json:"codes,omitempty"`

	rev  atomic.Int64                      `json:"-"`
	view atomic.TypedValue[hostStatusView] `json:"-"`
}

type hostStatusView struct {
	rev     int64
	limit   int
	expire  int64
	nodes   map[string]int
	blocked bool
}

type ActiveTarget struct {
	Target   string
	IsUDP    bool
	LastUsed int64
}

type NodeRankItem struct {
	Name   string
	Rank   string
	Weight float64
}

type NodeRank struct {
	LastUpdated int64          `json:"last_updated"`
	Result      []NodeRankItem `json:"result"`
}

type targetMinHeap []ActiveTarget

func initShardedLocks() {
	shardedLocksOnce.Do(func() {
		for i := range shardedLocks {
			shardedLocks[i] = &sync.Mutex{}
		}
	})
}

func GetTargetNodeLock(target, group, proxy string) *sync.Mutex {
	initShardedLocks()

	const fnvOffset32 uint32 = 2166136261
	const fnvPrime32 uint32 = 16777619
	h := fnvOffset32
	for i := 0; i < len(target); i++ {
		h ^= uint32(target[i])
		h *= fnvPrime32
	}
	for i := 0; i < len(group); i++ {
		h ^= uint32(group[i])
		h *= fnvPrime32
	}
	for i := 0; i < len(proxy); i++ {
		h ^= uint32(proxy[i])
		h *= fnvPrime32
	}

	return shardedLocks[h&1023]
}

func (s *Store) GetOrCreateAtomicRecord(cacheKey string, group, config, target, proxy string) *AtomicStatsRecord {
	if record, ok := recordCache.Get(cacheKey); ok {
		return record
	}

	record := s.loadAtomicRecord(group, config, target, proxy)
	record, _ = recordCache.GetOrStore(cacheKey, func() *AtomicStatsRecord { return record })
	return record
}

// loadAtomicRecord restores one node's persisted counters; the cache lock is not held here
// on purpose, a database read must not hold up every other key of the cache.
func (s *Store) loadAtomicRecord(group, config, target, proxy string) *AtomicStatsRecord {
	r := &AtomicStatsRecord{weights: lru.New[string, float64](lru.WithSize[string, float64](100))}

	existingData, err := s.GetStatsForTarget(group, config, target, proxy)
	if err != nil {
		return r
	}
	data, exists := existingData[proxy]
	if !exists {
		return r
	}
	var existingRecord StatsRecord
	if json.Unmarshal(data, &existingRecord) != nil {
		return r
	}

	r.success.Store(existingRecord.Success)
	r.failure.Store(existingRecord.Failure)
	r.connectTime.Store(existingRecord.ConnectTime)
	r.latency.Store(existingRecord.Latency)
	r.lastUsed.Store(existingRecord.LastUsed)
	r.uploadTotal.Store(existingRecord.UploadTotal)
	r.downloadTotal.Store(existingRecord.DownloadTotal)
	r.duration.Store(existingRecord.ConnectionDuration)
	r.maxUploadRate.Store(existingRecord.MaxUploadRate)
	r.maxDownloadRate.Store(existingRecord.MaxDownloadRate)
	r.lossRate.Store(existingRecord.LossRate)
	r.cumulSent.Store(int64(existingRecord.CumulSent))
	r.cumulRetrans.Store(int64(existingRecord.CumulRetrans))
	if existingRecord.Weights != nil {
		for k, v := range existingRecord.Weights {
			r.weights.Set(k, v)
		}
	}
	return r
}

func (record *AtomicStatsRecord) CreateStatsSnapshot(cacheKey string) *StatsRecord {
	if record == nil {
		return &StatsRecord{}
	}

	snapshot := &StatsRecord{
		Success:            record.success.Load(),
		Failure:            record.failure.Load(),
		ConnectTime:        record.connectTime.Load(),
		Latency:            record.latency.Load(),
		LastUsed:           record.lastUsed.Load(),
		UploadTotal:        record.uploadTotal.Load(),
		DownloadTotal:      record.downloadTotal.Load(),
		MaxUploadRate:      record.maxUploadRate.Load(),
		MaxDownloadRate:    record.maxDownloadRate.Load(),
		ConnectionDuration: record.duration.Load(),
		LossRate:           record.lossRate.Load(),
		CumulSent:          uint64(record.cumulSent.Load()),
		CumulRetrans:       uint64(record.cumulRetrans.Load()),
		Weights:            record.weights.FilterByKeyPrefix(""),
	}

	recordCache.Set(cacheKey, record)

	return snapshot
}

func (r *AtomicStatsRecord) Success() int64 {
	return r.success.Load()
}

func (r *AtomicStatsRecord) AddSuccess(v int64) {
	current := r.success.Load()
	if v > 0 && current > math.MaxInt64/2-v {
		r.success.Store(math.MaxInt64 / 4)
	} else {
		r.success.Add(v)
	}
}

func (r *AtomicStatsRecord) Failure() int64 {
	return r.failure.Load()
}

func (r *AtomicStatsRecord) AddFailure(v int64) {
	current := r.failure.Load()
	if v > 0 && current > math.MaxInt64/2-v {
		r.failure.Store(math.MaxInt64 / 4)
	} else {
		r.failure.Add(v)
	}
}

func (r *AtomicStatsRecord) ConnectTime() int64 {
	return r.connectTime.Load()
}

func (r *AtomicStatsRecord) SetConnectTime(v int64) {
	r.connectTime.Store(v)
}

func (r *AtomicStatsRecord) Latency() int64 {
	return r.latency.Load()
}

func (r *AtomicStatsRecord) SetLatency(v int64) {
	r.latency.Store(v)
}

func (r *AtomicStatsRecord) LastUsed() int64 {
	return r.lastUsed.Load()
}

func (r *AtomicStatsRecord) SetLastUsed(v int64) {
	r.lastUsed.Store(v)
}

func (r *AtomicStatsRecord) UploadTotal() float64 {
	return r.uploadTotal.Load()
}

// AddUploadTotal caps the counter; a wrapped value would poison the model input.
func (r *AtomicStatsRecord) AddUploadTotal(v float64) {
	current := r.uploadTotal.Load()
	const maxUpload = 1125899906842624.0
	if current+v > maxUpload {
		r.uploadTotal.Store(maxUpload / 2)
	} else {
		r.uploadTotal.Add(v)
	}
}

func (r *AtomicStatsRecord) DownloadTotal() float64 {
	return r.downloadTotal.Load()
}

// AddDownloadTotal caps the counter like AddUploadTotal.
func (r *AtomicStatsRecord) AddDownloadTotal(v float64) {
	current := r.downloadTotal.Load()
	const maxDownload = 1125899906842624.0
	if current+v > maxDownload {
		r.downloadTotal.Store(maxDownload / 2)
	} else {
		r.downloadTotal.Add(v)
	}
}

func (r *AtomicStatsRecord) MaxUploadRate() float64 {
	return r.maxUploadRate.Load()
}

func (r *AtomicStatsRecord) SetMaxUploadRate(v float64) {
	r.maxUploadRate.Store(v)
}

func (r *AtomicStatsRecord) MaxDownloadRate() float64 {
	return r.maxDownloadRate.Load()
}

func (r *AtomicStatsRecord) SetMaxDownloadRate(v float64) {
	r.maxDownloadRate.Store(v)
}

func (r *AtomicStatsRecord) Duration() float64 {
	return r.duration.Load()
}

func (r *AtomicStatsRecord) SetDuration(v float64) {
	r.duration.Store(v)
}

func (r *AtomicStatsRecord) LossRate() float64 {
	return r.lossRate.Load()
}

func (r *AtomicStatsRecord) SetLossRate(v float64) {
	r.lossRate.Store(v)
}

func (r *AtomicStatsRecord) CumulSent() int64 {
	return r.cumulSent.Load()
}

// AddCumulSent halves both loss counters at once, so their ratio stays meaningful after an overflow.
func (r *AtomicStatsRecord) AddCumulSent(v int64) {
	if v <= 0 {
		return
	}
	current := r.cumulSent.Load()
	if current > math.MaxInt64/2-v {
		r.cumulSent.Store(current / 2)
		r.cumulRetrans.Store(r.cumulRetrans.Load() / 2)
	} else {
		r.cumulSent.Add(v)
	}
}

func (r *AtomicStatsRecord) CumulRetrans() int64 {
	return r.cumulRetrans.Load()
}

func (r *AtomicStatsRecord) AddCumulRetrans(v int64) {
	if v <= 0 {
		return
	}
	current := r.cumulRetrans.Load()
	if current > math.MaxInt64/2-v {
		r.cumulSent.Store(r.cumulSent.Load() / 2)
		r.cumulRetrans.Store(current / 2)
	} else {
		r.cumulRetrans.Add(v)
	}
}

func (r *AtomicStatsRecord) GetWeight(weightType string) float64 {
	if value, ok := r.weights.Get(weightType); ok {
		return value
	}
	return 0
}

func (r *AtomicStatsRecord) SetWeight(weightType string, value float64) {
	r.weights.Set(weightType, value)
}

// AddASNEvidence counts one more observation of a network on this target, the
// evidence ClaimedASNRules is built from, see asnEvidencePrefix.
func (r *AtomicStatsRecord) AddASNEvidence(asn string) {
	if asn == "" {
		return
	}
	key := asnEvidencePrefix + asn
	value, _ := r.weights.Get(key)
	r.weights.Set(key, value+1)
}

func (s *Store) GetNodeWeightRankingCache(group, config string) (NodeRank, error) {
	pathPrefix := FormatDBKey(KeyTypeRanking, config, group)
	rawResult, err := s.GetSubBytesByPath(pathPrefix)
	if err != nil {
		return NodeRank{}, err
	}

	for _, data := range rawResult {
		var wrapper NodeRank
		if err := json.Unmarshal(data, &wrapper); err == nil && len(wrapper.Result) > 0 {
			return wrapper, nil
		}
	}

	return NodeRank{}, nil
}

func (s *Store) GetNodeWeightRanking(group, config, testUrl string, proxies []C.Proxy) (NodeRank, error) {
	if len(proxies) == 0 {
		return NodeRank{}, fmt.Errorf("no proxies provided")
	}

	resultItems := make([]NodeRankItem, 0, len(proxies))
	proxyNames := make([]string, 0, len(proxies))
	allNodes := make(map[string]struct{}, len(proxies))
	aliveNodes := make(map[string]bool, len(proxies))
	blockedNodes := s.GetBlockedNodes(group, config)
	for _, p := range proxies {
		name := p.Name()
		proxyNames = append(proxyNames, name)
		if p.AliveForTestUrl(testUrl) && !blockedNodes[name] {
			aliveNodes[name] = true
		}
		allNodes[name] = struct{}{}
	}

	globalCacheParams.mutex.RLock()
	prefetchLimit := globalCacheParams.MaxTargets / 2
	globalCacheParams.mutex.RUnlock()

	activeTargets := s.GetActiveTargets(group, config, prefetchLimit)

	nodeScores := make(map[string]float64, len(proxies))

	for _, ad := range activeTargets {
		nodes, weights := s.GetPrefetchResult(group, config, ad.Target, ad.IsUDP)
		limit := len(nodes)
		if len(weights) < limit {
			limit = len(weights)
		}
		for i := 0; i < limit; i++ {
			node := nodes[i]
			if _, ok := allNodes[node]; !ok {
				continue
			}
			if weights[i] < AllowedWeight {
				break
			}
			score := 1.0 / float64(i+1)
			if score < 1e-4 {
				break
			}
			nodeScores[node] += score
		}
	}

	maxScore := 0.0
	for _, score := range nodeScores {
		if score > maxScore {
			maxScore = score
		}
	}

	if maxScore == 0 {
		return NodeRank{}, nil
	}

	for _, node := range proxyNames {
		score := nodeScores[node]
		percentScore := math.Round(score/maxScore*100*100) / 100
		resultItems = append(resultItems, NodeRankItem{Name: node, Weight: percentScore, Rank: ""})
	}

	sort.Slice(resultItems, func(i, j int) bool {
		ai := aliveNodes[resultItems[i].Name]
		aj := aliveNodes[resultItems[j].Name]
		if ai != aj {
			return ai
		}
		if resultItems[i].Weight != resultItems[j].Weight {
			return resultItems[i].Weight > resultItems[j].Weight
		}
		return resultItems[i].Name < resultItems[j].Name
	})

	if len(resultItems) > 0 {
		aliveCount := 0
		positiveAliveCount := 0
		for _, r := range resultItems {
			if aliveNodes[r.Name] {
				aliveCount++
				if r.Weight > 0 {
					positiveAliveCount++
				}
			}
		}

		if aliveCount > 0 && positiveAliveCount > 0 {
			mostUsedBound := int(float64(positiveAliveCount) * 0.2)
			if mostUsedBound < 1 {
				mostUsedBound = 1
			}

			occasionalBound := mostUsedBound + int(float64(positiveAliveCount)*0.5)

			for i := 0; i < mostUsedBound; i++ {
				resultItems[i].Rank = RankMostUsed
			}
			for i := mostUsedBound; i < occasionalBound; i++ {
				resultItems[i].Rank = RankOccasional
			}
			for i := occasionalBound; i < aliveCount; i++ {
				resultItems[i].Rank = RankRarelyUsed
			}
		}

		for i := aliveCount; i < len(resultItems); i++ {
			resultItems[i].Rank = RankRarelyUsed
		}

		wrapper := NodeRank{LastUpdated: time.Now().Unix(), Result: resultItems}
		s.StoreNodeWeightRanking(group, config, wrapper)
		return wrapper, nil
	}

	return NodeRank{}, nil
}

func (s *Store) StoreNodeWeightRanking(group, config string, ranking NodeRank) {
	data, err := json.Marshal(ranking)
	if err != nil {
		return
	}

	s.AppendToGlobalQueue(StoreOperation{
		Type:   OpSaveRanking,
		Group:  group,
		Config: config,
		Data:   data,
	})
}

func (s *Store) GetBestProxyForTarget(group, config, target string, isUDP bool) ([]string, []float64, error) {
	if target == "" {
		return nil, nil, errors.New("empty target")
	}

	allStatsMap, err := s.GetAllStats(group, config)
	if err != nil {
		return nil, nil, err
	}

	return s.bestProxyForTargetFrom(allStatsMap, group, config, target, isUDP)
}

func (s *Store) bestProxyForTargetFrom(allStatsMap map[string]map[string][]byte, group, config, target string, isUDP bool) ([]string, []float64, error) {
	now := time.Now().Unix()
	minDecay := 0.4

	getTimeDecay := func(lastUsedTime int64) float64 {
		return GetTimeDecayWithCache(lastUsedTime, now, minDecay)
	}

	weightType := WeightTypeTCP
	if isUDP {
		weightType = WeightTypeUDP
	}

	nodesWithWeight := make(map[string]float64)

	stats := allStatsMap[target]
	if len(stats) == 0 {
		stats, _ = s.GetStatsForTarget(group, config, target, "")
	}

	for nodeName, data := range stats {
		var record StatsRecord
		if json.Unmarshal(data, &record) != nil {
			continue
		}
		var weight float64
		if record.Weights != nil {
			weight = record.Weights[weightType]
		}
		if weight > 0 {
			timeDecay := getTimeDecay(record.LastUsed)
			nodesWithWeight[nodeName] = weight * timeDecay
		}
	}

	if len(nodesWithWeight) == 0 {
		return nil, nil, errors.New("no best node with enough weight")
	}

	nodeList := make([]NodeWithWeight, 0, len(nodesWithWeight))
	for node, weight := range nodesWithWeight {
		nodeList = append(nodeList, NodeWithWeight{node, weight})
	}

	sort.Slice(nodeList, func(i, j int) bool {
		if nodeList[i].Weight != nodeList[j].Weight {
			return nodeList[i].Weight > nodeList[j].Weight
		}
		return nodeList[i].Node < nodeList[j].Node
	})

	n := len(nodeList)
	bestNodes := make([]string, n)
	bestWeights := make([]float64, n)
	for i, nw := range nodeList {
		bestNodes[i] = nw.Node
		bestWeights[i] = nw.Weight
	}

	return bestNodes, bestWeights, nil
}

func (h targetMinHeap) Len() int            { return len(h) }
func (h targetMinHeap) Less(i, j int) bool  { return h[i].LastUsed < h[j].LastUsed }
func (h targetMinHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *targetMinHeap) Push(x interface{}) { *h = append(*h, x.(ActiveTarget)) }
func (h *targetMinHeap) Pop() interface{} {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[0 : n-1]
	return x
}

func (s *Store) GetActiveTargets(group, config string, limit int) []ActiveTarget {
	allStats, err := s.GetAllStats(group, config)
	if err != nil || len(allStats) == 0 {
		return nil
	}

	h := &targetMinHeap{}
	heap.Init(h)

	for target, nodeStats := range allStats {
		active := make(map[bool]int64)

		for _, data := range nodeStats {
			var record StatsRecord
			if json.Unmarshal(data, &record) != nil {
				continue
			}
			if record.Weights == nil {
				continue
			}

			if w, ok := record.Weights[WeightTypeTCP]; ok && w > 0 {
				if last, exists := active[false]; !exists || record.LastUsed > last {
					active[false] = record.LastUsed
				}
			}
			if w, ok := record.Weights[WeightTypeUDP]; ok && w > 0 {
				if last, exists := active[true]; !exists || record.LastUsed > last {
					active[true] = record.LastUsed
				}
			}
		}

		for isUDP, lastUsed := range active {
			heap.Push(h, ActiveTarget{
				Target:   target,
				IsUDP:    isUDP,
				LastUsed: lastUsed,
			})
			if h.Len() > limit {
				heap.Pop(h)
			}
		}
	}

	sorted := make([]ActiveTarget, 0, h.Len())
	for h.Len() > 0 {
		sorted = append(sorted, heap.Pop(h).(ActiveTarget))
	}
	for i, j := 0, len(sorted)-1; i < j; i, j = i+1, j-1 {
		sorted[i], sorted[j] = sorted[j], sorted[i]
	}

	return sorted
}

func (s *Store) RunPrefetch(group, config string, proxyMap map[string]bool) int {
	log.Debugln("[SmartStore] Executing target pre-calculation for policy group [%s]", group)

	if len(proxyMap) == 0 {
		log.Debugln("[SmartStore] No available nodes for prefetch calculation in group [%s]", group)
		return 0
	}

	globalCacheParams.mutex.RLock()
	prefetchLimit := globalCacheParams.MaxTargets / 2
	globalCacheParams.mutex.RUnlock()

	activeTargets := s.GetActiveTargets(group, config, prefetchLimit)

	type prefetchItem struct {
		target      string
		isUDP       bool
		bestNodes   []string
		bestWeights []float64
	}

	items := make([]prefetchItem, 0, len(activeTargets))

	hoistedStats, hoistedErr := s.GetAllStats(group, config)

	bestFor := func(active ActiveTarget) ([]string, []float64, error) {
		if hoistedErr == nil {
			return s.bestProxyForTargetFrom(hoistedStats, group, config, active.Target, active.IsUDP)
		}
		return s.GetBestProxyForTarget(group, config, active.Target, active.IsUDP)
	}

	for _, active := range activeTargets {
		bestNodes, bestWeights, err := bestFor(active)
		if err != nil || len(bestNodes) == 0 {
			continue
		}

		nodes := make([]string, 0, len(bestNodes))
		weights := make([]float64, 0, len(bestWeights))
		for i := 0; i < len(bestNodes); i++ {
			if !proxyMap[bestNodes[i]] {
				continue
			}
			nodes = append(nodes, bestNodes[i])
			weights = append(weights, bestWeights[i])
		}

		if len(nodes) > 0 {
			item := prefetchItem{
				target:      active.Target,
				isUDP:       active.IsUDP,
				bestNodes:   nodes,
				bestWeights: weights,
			}
			items = append(items, item)
		}
	}

	targetNodeExistsCache := make(map[string]map[string]bool)

	prefetchCount := 0

	for _, item := range items {
		oldNodes, oldWeights := s.GetPrefetchResult(group, config, item.target, item.isUDP)

		target := item.target

		networkType := "tcp"
		if item.isUDP {
			networkType = "udp"
		}

		var sortedNodes []string
		var sortedWeights []float64
		var needUpdate bool

		if len(oldNodes) == 0 {
			needUpdate = true
			sortedNodes = item.bestNodes
			sortedWeights = item.bestWeights
		} else {
			finalNodeMap := make(map[string]float64, len(oldNodes)+len(item.bestNodes))
			for i, node := range oldNodes {
				finalNodeMap[node] = oldWeights[i]
			}

			for i, newNode := range item.bestNodes {
				newW := item.bestWeights[i]
				if oldW, exists := finalNodeMap[newNode]; exists {
					// prevent degrade recovery too fast
					if oldW <= 0 || math.Abs(newW-oldW)/oldW > 0.1 {
						finalNodeMap[newNode] = newW
						needUpdate = true
					}
				} else {
					finalNodeMap[newNode] = newW
					needUpdate = true
				}
			}

			// drop prefetch entries without stats, otherwise stale names stay listed.
			nodeExistsMap, ok := targetNodeExistsCache[item.target]
			if !ok {
				nodeExistsMap = make(map[string]bool)
				targetNodeExistsCache[item.target] = nodeExistsMap
			}

			for node := range finalNodeMap {
				if !proxyMap[node] && finalNodeMap[node] > AllowedWeight {
					delete(finalNodeMap, node)
					continue
				}
				exists, checked := nodeExistsMap[node]
				if !checked {
					if nodeStats, err := s.GetStatsForTarget(group, config, item.target, node); err == nil && len(nodeStats) > 0 {
						exists = true
					}
					nodeExistsMap[node] = exists
				}
				if !exists {
					delete(finalNodeMap, node)
				}
			}

			if needUpdate {
				var nodeList []NodeWithWeight
				for node, weight := range finalNodeMap {
					nodeList = append(nodeList, NodeWithWeight{node, weight})
				}
				sort.Slice(nodeList, func(i, j int) bool {
					if nodeList[i].Weight != nodeList[j].Weight {
						return nodeList[i].Weight > nodeList[j].Weight
					}
					return nodeList[i].Node < nodeList[j].Node
				})

				sortedNodes = make([]string, len(nodeList))
				sortedWeights = make([]float64, len(nodeList))
				for i, nw := range nodeList {
					sortedNodes[i] = nw.Node
					sortedWeights[i] = nw.Weight
				}
			} else {
				sortedNodes = item.bestNodes
				sortedWeights = item.bestWeights
			}
		}

		if needUpdate {
			s.StorePrefetchResult(group, config, item.target, item.isUDP, sortedNodes, sortedWeights)
		}

		prefetchCount++

		nodeWeightPairs := make([]string, len(sortedNodes))
		for i := range sortedNodes {
			nodeWeightPairs[i] = fmt.Sprintf("%s: %.2f", sortedNodes[i], sortedWeights[i])
		}

		if len(oldNodes) == 0 {
			log.Debugln("[SmartStore] Prefetching for group [%s]: network: [%s] => target: [%s] => result: [%s] (no old result)",
				group, networkType, target, strings.Join(nodeWeightPairs, ", "))
		} else if needUpdate {
			oldNodeWeightPairs := make([]string, len(oldNodes))
			for i := range oldNodes {
				oldNodeWeightPairs[i] = fmt.Sprintf("%s: %.2f", oldNodes[i], oldWeights[i])
			}
			log.Debugln("[SmartStore] Prefetching for group [%s]: network: [%s] => target: [%s] => result: [%s] (updated from old: [%s])",
				group, networkType, target, strings.Join(nodeWeightPairs, ", "), strings.Join(oldNodeWeightPairs, ", "))
		}
	}

	log.Infoln("[SmartStore] Prefetch completed for group [%s]: pre-calculated [%d] targets",
		group, prefetchCount)
	return prefetchCount
}

// RecordASNEvidence counts one more network observation of a target; the counters are
// seeded only after TargetASNEvidence scanned the store, until then the call is a no-op.
func (s *Store) RecordASNEvidence(group, config, target, asn string) {
	if asn == "" || target == "" {
		return
	}

	entry, ok := asnEvidenceCache.Load(config + "|" + group)
	if !ok {
		return
	}

	entry.mutex.Lock()
	defer entry.mutex.Unlock()

	if entry.data == nil {
		entry.data = make(map[string]map[string]int)
	}
	asns := entry.data[target]
	if asns == nil {
		asns = make(map[string]int)
		entry.data[target] = asns
	}
	asns[asn]++
}

// TargetASNEvidence returns for every target the networks its successful connections
// were served from and how often, which is the evidence ClaimedASNRules works on.
// The returned maps are a copy, the counters keep changing in the background.
func (s *Store) TargetASNEvidence(group, config string) map[string]map[string]int {
	entry, _ := asnEvidenceCache.LoadOrStore(config+"|"+group, &asnEvidenceEntry{})

	entry.mutex.Lock()
	defer entry.mutex.Unlock()

	if entry.updated.IsZero() || time.Since(entry.updated) > asnEvidenceRebuildInterval {
		entry.data = s.scanASNEvidence(group, config)
		entry.updated = time.Now()
	}

	if len(entry.data) == 0 {
		return nil
	}

	result := make(map[string]map[string]int, len(entry.data))
	for target, asns := range entry.data {
		asnsCopy := make(map[string]int, len(asns))
		for asn, hits := range asns {
			asnsCopy[asn] = hits
		}
		result[target] = asnsCopy
	}
	return result
}

func (s *Store) scanASNEvidence(group, config string) map[string]map[string]int {
	allStats, err := s.GetAllStats(group, config)
	if err != nil || len(allStats) == 0 {
		return nil
	}

	result := make(map[string]map[string]int)

	for target, nodeStats := range allStats {
		for _, data := range nodeStats {
			var record StatsRecord
			if json.Unmarshal(data, &record) != nil || record.Weights == nil {
				continue
			}
			for key, value := range record.Weights {
				if !strings.HasPrefix(key, asnEvidencePrefix) {
					continue
				}
				asn := strings.TrimPrefix(key, asnEvidencePrefix)
				if asn == "" || value <= 0 {
					continue
				}
				if result[target] == nil {
					result[target] = make(map[string]int)
				}
				result[target][asn] += int(value)
			}
		}
	}

	return result
}

func (s *Store) GetStatsForTarget(group, config, target, proxy string) (map[string][]byte, error) {
	result := make(map[string][]byte)

	var pathPrefix string
	if proxy != "" {
		pathPrefix = FormatDBKey(KeyTypeStats, config, group, target, proxy)
	} else {
		pathPrefix = FormatDBKey(KeyTypeStats, config, group, target)
	}

	rawResult, err := s.GetSubBytesByPath(pathPrefix)
	if err != nil {
		return nil, err
	}

	if proxy != "" {
		for _, data := range rawResult {
			result[proxy] = data
		}
	} else {
		for fullPath, data := range rawResult {
			nodeName := fullPath[strings.LastIndexByte(fullPath, '/')+1:]
			result[nodeName] = data
		}
	}

	return result, nil
}

func (s *Store) GetAllStats(group, config string) (map[string]map[string][]byte, error) {
	pathPrefix := FormatDBKey(KeyTypeStats, config, group)

	result := make(map[string]map[string][]byte)

	rawResult, err := s.GetSubBytesByPath(pathPrefix)
	if err != nil {
		return nil, err
	}

	for fullPath, data := range rawResult {
		if strings.Count(fullPath, "/") < 5 {
			continue
		}
		lastSlash := strings.LastIndexByte(fullPath, '/')
		node := fullPath[lastSlash+1:]
		prevSlash := strings.LastIndexByte(fullPath[:lastSlash], '/')
		target := fullPath[prevSlash+1 : lastSlash]

		if _, ok := result[target]; !ok {
			result[target] = make(map[string][]byte)
		}
		result[target][node] = data
	}

	return result, nil
}

func (s *Store) GetAllGroupsForConfig(config string) ([]string, error) {
	groupsMap := make(map[string]bool)

	statsPath := FormatDBKey(KeyTypeStats, config)
	collect := func(fullPath string) {
		rest, found := strings.CutPrefix(fullPath, statsPath+"/")
		if !found {
			return
		}
		if group, _, _ := strings.Cut(rest, "/"); group != "" {
			groupsMap[group] = true
		}
	}

	raw, err := s.GetSubBytesByPath(statsPath)
	if err != nil {
		raw = nil
	}

	for fullPath := range raw {
		collect(fullPath)
	}

	if len(groupsMap) == 0 {
		scanResults, err2 := s.DBViewPrefixScan(statsPath, -1, false)
		if err2 != nil {
			return nil, err2
		}
		for path := range scanResults {
			collect(path)
		}
	}

	result := make([]string, 0, len(groupsMap))
	for g := range groupsMap {
		result = append(result, g)
	}

	return result, nil
}

func (s *Store) GetAllNodesForGroup(group, config string) ([]string, error) {
	nodesMap := make(map[string]bool)

	nodesPath := FormatDBKey(KeyTypeNode, config, group)
	nodeStatesData, err := s.GetSubBytesByPath(nodesPath)
	if err == nil {
		for key := range nodeStatesData {
			nodeName := key[strings.LastIndexByte(key, '/')+1:]
			if nodeName != "" {
				nodesMap[nodeName] = true
			}
		}
	}

	statsPath := FormatDBKey(KeyTypeStats, config, group)
	statsData, err := s.GetSubBytesByPath(statsPath)
	if err == nil {
		for key := range statsData {
			if strings.Count(key, "/") < 5 {
				continue
			}
			nodeName := key[strings.LastIndexByte(key, '/')+1:]
			if nodeName != "" {
				nodesMap[nodeName] = true
			}
		}
	}

	result := make([]string, 0, len(nodesMap))
	for node := range nodesMap {
		result = append(result, node)
	}
	return result, nil
}

func countsTowardBlock(code int) bool {
	return code != 1 && code != 2 && code != 6
}

func buildHostStatusView(codes map[int]*CodeNodeSet, now int64, hostFailLimit int) (map[string]int, bool) {
	var nodes map[string]int
	blockingCount := 0

	for code, codeSet := range codes {
		if codeSet == nil {
			continue
		}
		for nodeName, nodeEntry := range codeSet.Nodes {
			if nodeEntry == 0 || nodeEntry > now {
				if nodes == nil {
					nodes = make(map[string]int)
				}
				if oldCode, exists := nodes[nodeName]; !exists || code < oldCode {
					nodes[nodeName] = code
				}
			}
			if countsTowardBlock(code) && nodeEntry > now {
				blockingCount++
			}
		}
	}

	return nodes, blockingCount > hostFailLimit
}

func (s *Store) GetHostStatus(group, config, wildcardTarget string, hostFailLimit int, extraTargets ...string) (failNodes map[string]int, blocked bool) {
	now := time.Now().Unix()

	lookup := func(pathPrefix string) (nodes map[string]int, blocked bool) {
		hs, _ := hostStatusCache.GetOrStore(pathPrefix, func() *HostStatus { return &HostStatus{} })
		hs.initOnce.Do(func() {
			if rawResult, err := s.GetSubBytesByPath(pathPrefix); err == nil {
				for _, data := range rawResult {
					if json.Unmarshal(data, hs) == nil {
						break
					}
				}
			}
			hs.rev.Add(1)
		})

		hs.mu.RLock()
		rev := hs.rev.Load()
		if cached := hs.view.Load(); cached.rev == rev && cached.limit == hostFailLimit && now < cached.expire {
			nodes, blocked = cached.nodes, cached.blocked
			hs.mu.RUnlock()
			return nodes, blocked
		}
		nodes, blocked = buildHostStatusView(hs.Codes, now, hostFailLimit)
		hs.mu.RUnlock()

		hs.view.Store(hostStatusView{
			rev:     rev,
			limit:   hostFailLimit,
			expire:  now + hostStatusViewTTLSeconds,
			nodes:   nodes,
			blocked: blocked,
		})

		return nodes, blocked
	}

	failNodes, blocked = lookup(FormatDBKey(KeyTypeHostFailures, config, group, wildcardTarget))

	for _, extraTarget := range extraTargets {
		if extraTarget == "" || extraTarget == wildcardTarget {
			continue
		}
		if extraNodes, _ := lookup(FormatDBKey(KeyTypeHostFailures, config, group, extraTarget)); len(extraNodes) > 0 {
			if len(failNodes) == 0 {
				// the view is shared with the cache and is never written by a caller
				failNodes = extraNodes
				continue
			}
			merged := make(map[string]int, len(failNodes)+len(extraNodes))
			for k, v := range failNodes {
				merged[k] = v
			}
			for k, v := range extraNodes {
				if oldCode, exists := merged[k]; !exists || v < oldCode {
					merged[k] = v
				}
			}
			failNodes = merged
		}
	}

	return
}

func (s *Store) UpdateHostStatus(group, config, wildcardTarget string, metadata *C.Metadata, name string, maxFailedTimes int, hostFailLimit int, failure, checked bool, statusCode int64, ttl time.Duration) bool {
	if !checked {
		return false
	}

	newCode := int(statusCode)

	var host string
	if failure && newCode == 2 {
		if metadata.Host == "" {
			return false
		}
		host = metadata.Host
	}

	blockTTL := HostFailureNodeTTL
	if ttl > 0 {
		blockTTL = ttl
	}

	pathPrefix := FormatDBKey(KeyTypeHostFailures, config, group, wildcardTarget)

	var failedBlock bool
	now := time.Now().Unix()

	hs, _ := hostStatusCache.GetOrStore(pathPrefix, func() *HostStatus { return &HostStatus{} })

	hs.initOnce.Do(func() {
		rawResult, err := s.GetSubBytesByPath(pathPrefix)
		if err == nil {
			for _, data := range rawResult {
				if err := json.Unmarshal(data, hs); err == nil {
					break
				}
			}
		}
	})

	hs.mu.Lock()
	defer hs.mu.Unlock()
	hs.rev.Add(1)

	if hs.Codes == nil {
		hs.Codes = make(map[int]*CodeNodeSet)
	}

	for code, codeSet := range hs.Codes {
		if codeSet == nil {
			delete(hs.Codes, code)
			continue
		}
		if code == 1 {
			continue
		}
		if code == 2 {
			for nodeName, nodeEntry := range codeSet.Nodes {
				if nodeEntry != 0 && nodeEntry <= now {
					delete(codeSet.Nodes, nodeName)
					if codeSet.NodeHosts != nil {
						delete(codeSet.NodeHosts, nodeName)
					}
				}
			}
			// FailCounts keep the back off alive, they are dropped once the host is quiet again
			if now-hs.LastFailure > int64(hostStatusRetryAfter.Seconds()) {
				codeSet.FailCounts = nil
			}
			if len(codeSet.Nodes) == 0 && len(codeSet.FailCounts) == 0 {
				delete(hs.Codes, code)
			}
			continue
		}
		for nodeName, nodeEntry := range codeSet.Nodes {
			if nodeEntry != 0 && nodeEntry <= now {
				delete(codeSet.Nodes, nodeName)
				if codeSet.FailCounts != nil {
					delete(codeSet.FailCounts, nodeName)
				}
			}
		}
		// the ladder memory drops once the record stays quiet for the retry window
		if code == 5 && now-hs.LastFailure > int64(hostStatusRetryAfter.Seconds()) {
			codeSet.Confirmations = nil
		}
		if len(codeSet.Nodes) == 0 && len(codeSet.FailCounts) == 0 && len(codeSet.Confirmations) == 0 {
			delete(hs.Codes, code)
		}
	}

	oldLastFailure := hs.LastFailure
	currentCode := -1

	for code, codeSet := range hs.Codes {
		if codeSet == nil {
			continue
		}
		if _, ok := codeSet.Nodes[name]; ok {
			if currentCode == -1 || code < currentCode {
				currentCode = code
			}
		}
		if codeSet.FailCounts != nil {
			if _, ok := codeSet.FailCounts[name]; ok {
				// a pending strike must not shadow the other codes
				if code != 5 {
					if currentCode == -1 || code < currentCode {
						currentCode = code
					}
				}
			}
		}
	}

	if !failure && newCode == 0 {
		for code, codeSet := range hs.Codes {
			if code == 1 || codeSet == nil {
				continue
			}
			delete(codeSet.Nodes, name)
			if codeSet.FailCounts != nil {
				delete(codeSet.FailCounts, name)
			}
			if codeSet.Confirmations != nil {
				delete(codeSet.Confirmations, name)
			}
			if codeSet.NodeHosts != nil {
				delete(codeSet.NodeHosts, name)
			}
		}
		goto saveAndReturn
	}

	// the first strike only counts, the second excludes the node
	if failure && newCode == 5 {
		count := 1
		if oldLastFailure != 0 && now-oldLastFailure <= int64(hostStrikeWindow.Seconds()) {
			if codeSet := hs.Codes[newCode]; codeSet != nil && codeSet.FailCounts != nil {
				count = codeSet.FailCounts[name] + 1
			}
		}
		if count < hostStrikeLimit {
			if hs.Codes[newCode] == nil {
				hs.Codes[newCode] = &CodeNodeSet{Nodes: make(map[string]int64)}
			}
			codeSet := hs.Codes[newCode]
			if codeSet.FailCounts == nil {
				codeSet.FailCounts = make(map[string]int)
			}
			codeSet.FailCounts[name] = count
			hs.LastFailure = now
			goto saveAndReturn
		}
	}

	if currentCode != -1 && currentCode != newCode {
		if newCode > currentCode {
			goto saveAndReturn
		}
		for code, codeSet := range hs.Codes {
			if code == newCode || codeSet == nil {
				continue
			}
			delete(codeSet.Nodes, name)
			if codeSet.FailCounts != nil {
				delete(codeSet.FailCounts, name)
			}
			if codeSet.NodeHosts != nil {
				delete(codeSet.NodeHosts, name)
			}
		}
	}

	if failure || newCode == 3 {
		hs.LastFailure = now

		if hs.Codes[newCode] == nil {
			hs.Codes[newCode] = &CodeNodeSet{
				Nodes: make(map[string]int64),
			}
		}
		codeSet := hs.Codes[newCode]
		if codeSet.Nodes == nil {
			codeSet.Nodes = make(map[string]int64)
		}

		excluded := ""
		switch newCode {
		case 1:
			codeSet.Nodes[name] = 0 // TTL=0 means permanent
			excluded = "permanent"
		case 2:
			if ttl > 0 {
				if codeSet.FailCounts == nil {
					codeSet.FailCounts = make(map[string]int)
				}
				count := codeSet.FailCounts[name] + 1
				if oldLastFailure != 0 && now-oldLastFailure > int64(hostStatusRetryAfter.Seconds()) {
					count = 1
				}
				codeSet.FailCounts[name] = count
				// a host that keeps rejecting must back off, a short exclusion would break
				// the per-target node consistency
				switch {
				case count == 2:
					blockTTL = 15 * time.Minute
				case count == 3:
					blockTTL = time.Hour
				case count == 4:
					blockTTL = 4 * time.Hour
				case count > 4:
					blockTTL = HostFailureNodeTTL
				}
			}
			codeSet.Nodes[name] = time.Now().Add(blockTTL).Unix()
			excluded = blockTTL.String()
			if codeSet.NodeHosts == nil {
				codeSet.NodeHosts = make(map[string]string)
			}
			codeSet.NodeHosts[name] = host
		case 3:
			if codeSet.FailCounts == nil {
				codeSet.FailCounts = make(map[string]int)
			}
			count := codeSet.FailCounts[name]
			if oldLastFailure == 0 || now-oldLastFailure > 300 {
				count = 1
			} else {
				count++
			}
			if count >= maxFailedTimes {
				codeSet.Nodes[name] = time.Now().Add(blockTTL).Unix()
				excluded = blockTTL.String()
				delete(codeSet.FailCounts, name)
				failedBlock = true
			} else {
				codeSet.FailCounts[name] = count
			}
		case 5:
			if codeSet.FailCounts != nil {
				delete(codeSet.FailCounts, name)
			}
			// a repeated confirmation while the node is still excluded is a no-op
			if entry, exists := codeSet.Nodes[name]; exists && entry > now {
				break
			}
			// each confirmed pair climbs the exclusion ladder, the tier survives the block
			if codeSet.Confirmations == nil {
				codeSet.Confirmations = make(map[string]int)
			}
			confirmations := codeSet.Confirmations[name] + 1
			codeSet.Confirmations[name] = confirmations
			// an explicit ttl (the UDP fallback) keeps its fixed block
			if ttl <= 0 {
				switch {
				case confirmations == 1:
					blockTTL = 15 * time.Minute
				case confirmations == 2:
					blockTTL = time.Hour
				case confirmations == 3:
					blockTTL = 4 * time.Hour
				default:
					blockTTL = HostFailureNodeTTL
				}
			}
			codeSet.Nodes[name] = time.Now().Add(blockTTL).Unix()
			excluded = blockTTL.String()
			failedBlock = true
		default:
			codeSet.Nodes[name] = time.Now().Add(blockTTL).Unix()
			excluded = blockTTL.String()
		}
		if excluded != "" {
			log.Debugln("[Smart] Node [%s] excluded for [%s] by code [%d] on target [%s]", name, excluded, newCode, wildcardTarget)
		}
	}

saveAndReturn:
	hs.LastCheck = now
	hostBlockingCount := 0

	for code, cs := range hs.Codes {
		if countsTowardBlock(code) && cs != nil {
			hostBlockingCount += len(cs.Nodes)
		}
	}
	if hostBlockingCount > hostFailLimit {
		hs.Blocked = true
		failedBlock = false
	} else {
		hs.Blocked = false
	}

	for code, codeSet := range hs.Codes {
		if codeSet == nil || (len(codeSet.Nodes) == 0 && len(codeSet.FailCounts) == 0 && len(codeSet.Confirmations) == 0) {
			delete(hs.Codes, code)
		}
	}

	if len(hs.Codes) > 0 {
		data, err := json.Marshal(&hs)
		if err != nil {
			return failedBlock
		}

		s.AppendToGlobalQueue(StoreOperation{
			Type:   OpSaveHostFailures,
			Group:  group,
			Config: config,
			Target: wildcardTarget,
			Data:   data,
		})
	} else {
		s.AppendToGlobalQueue(StoreOperation{
			Type:    OpDeleteData,
			KeyType: KeyTypeHostFailures,
			Group:   group,
			Config:  config,
			Target:  wildcardTarget,
		})
	}

	return failedBlock
}

// a code 2 entry beyond probeMaxBlockTTL is stale and dropped.
func (s *Store) CheckHostStatus(group, config string, hostFailLimit int) (map[string]map[string]string, error) {
	pathPrefix := FormatDBKey(KeyTypeHostFailures, config, group)
	dataMap, err := s.GetSubBytesByPath(pathPrefix)
	if err != nil {
		return nil, err
	}

	// result[wildcardTarget][nodeName] = host
	result := make(map[string]map[string]string)
	now := time.Now().Unix()

	for fullPath, data := range dataMap {
		var hs HostStatus
		if err := json.Unmarshal(data, &hs); err != nil {
			continue
		}

		lastSlash := strings.LastIndexByte(fullPath, '/')
		if lastSlash < 0 {
			continue
		}
		wildcardTarget := fullPath[lastSlash+1:]
		if isNetScopedTarget(wildcardTarget) {
			continue
		}

		cachePath := FormatDBKey(KeyTypeHostFailures, config, group, wildcardTarget)
		cacheHS, _ := hostStatusCache.GetOrStore(cachePath, func() *HostStatus { return &HostStatus{} })
		cacheHS.initOnce.Do(func() {
			if rawResult, err := s.GetSubBytesByPath(cachePath); err == nil {
				for _, data := range rawResult {
					if json.Unmarshal(data, cacheHS) == nil {
						break
					}
				}
			}
		})

		cacheHS.mu.Lock()
		hostBlockingCount := 0
		for code, cs := range cacheHS.Codes {
			if countsTowardBlock(code) && cs != nil {
				for _, nodeEntry := range cs.Nodes {
					if nodeEntry == 0 || nodeEntry > now {
						hostBlockingCount++
					}
				}
			}
		}
		dirty := false
		if cs := cacheHS.Codes[2]; cs != nil {
			maxEntry := now + int64(probeMaxBlockTTL/time.Second)
			for nodeName, nodeEntry := range cs.Nodes {
				if nodeEntry > maxEntry {
					delete(cs.Nodes, nodeName)
					delete(cs.NodeHosts, nodeName)
					dirty = true
				}
			}
			if len(cs.Nodes) == 0 {
				delete(cacheHS.Codes, 2)
			}
		}
		if newBlocked := hostBlockingCount > hostFailLimit; newBlocked != cacheHS.Blocked {
			cacheHS.Blocked = newBlocked
			dirty = true
		}
		if dirty {
			cacheHS.rev.Add(1)
			if newData, merr := json.Marshal(cacheHS); merr == nil {
				s.AppendToGlobalQueue(StoreOperation{
					Type:   OpSaveHostFailures,
					Group:  group,
					Config: config,
					Target: wildcardTarget,
					Data:   newData,
				})
			}
		}
		cacheHS.mu.Unlock()

		codeSet, ok := cacheHS.Codes[2]
		if !ok || codeSet == nil || codeSet.NodeHosts == nil {
			continue
		}

		for nodeName, nodeEntry := range codeSet.Nodes {
			if nodeEntry == 0 || nodeEntry-now > int64((HostFailureNodeTTL-hostStatusRetryAfter).Seconds()) {
				continue
			}
			h, ok2 := codeSet.NodeHosts[nodeName]
			if !ok2 || h == "" {
				continue
			}
			if _, ok := result[wildcardTarget]; !ok {
				result[wildcardTarget] = make(map[string]string)
			}
			result[wildcardTarget][nodeName] = h
		}
	}

	return result, nil
}

func (s *Store) RemoveNodesData(group, config string, hostFailLimit int, nodes []string) error {
	if len(nodes) == 0 {
		return nil
	}

	removeNodesFromQueue(group, config, nodes)

	nodeSet := make(map[string]struct{}, len(nodes))
	for _, n := range nodes {
		nodeSet[n] = struct{}{}
	}

	var firstErr error

	statsPrefix := FormatDBKey(KeyTypeStats, config, group)
	statsResults, err := s.DBViewPrefixScan(statsPrefix, -1, false)
	if err != nil {
		return err
	}
	var statsToDelete []string
	for path := range statsResults {
		if strings.Count(path, "/") < 5 {
			continue
		}
		node := path[strings.LastIndexByte(path, '/')+1:]
		if _, ok := nodeSet[node]; ok {
			statsToDelete = append(statsToDelete, path)
		}
	}
	if len(statsToDelete) > 0 {
		if delErr := s.DBBatchDeletePrefix(statsToDelete, true); delErr != nil && firstErr == nil {
			firstErr = delErr
		}
	}

	prefetchPrefix := FormatDBKey(KeyTypePrefetch, config, group)
	prefetchResults, err := s.DBViewPrefixScan(prefetchPrefix, -1, false)
	if err != nil {
		if firstErr == nil {
			firstErr = err
		}
		return firstErr
	}
	var prefetchToDelete []string
	for path, data := range prefetchResults {
		var pm PrefetchMap
		if err := json.Unmarshal(data, &pm); err != nil {
			prefetchToDelete = append(prefetchToDelete, path)
			continue
		}

		changed := false
		newTCPNodes := make([]string, 0, len(pm.TCP.Nodes))
		newTCPWeights := make([]float64, 0, len(pm.TCP.Weights))
		for i, node := range pm.TCP.Nodes {
			if _, toRemove := nodeSet[node]; !toRemove {
				newTCPNodes = append(newTCPNodes, node)
				if i < len(pm.TCP.Weights) {
					newTCPWeights = append(newTCPWeights, pm.TCP.Weights[i])
				}
			} else {
				changed = true
			}
		}
		pm.TCP.Nodes = newTCPNodes
		pm.TCP.Weights = newTCPWeights

		newUDPNodes := make([]string, 0, len(pm.UDP.Nodes))
		newUDPWeights := make([]float64, 0, len(pm.UDP.Weights))
		for i, node := range pm.UDP.Nodes {
			if _, toRemove := nodeSet[node]; !toRemove {
				newUDPNodes = append(newUDPNodes, node)
				if i < len(pm.UDP.Weights) {
					newUDPWeights = append(newUDPWeights, pm.UDP.Weights[i])
				}
			} else {
				changed = true
			}
		}
		pm.UDP.Nodes = newUDPNodes
		pm.UDP.Weights = newUDPWeights

		if changed {
			if len(pm.TCP.Nodes) == 0 && len(pm.UDP.Nodes) == 0 {
				prefetchToDelete = append(prefetchToDelete, path)
			} else {
				newData, merr := json.Marshal(pm)
				if merr != nil {
					if firstErr == nil {
						firstErr = merr
					}
					continue
				}
				if perr := s.DBBatchPutItem(path, newData); perr != nil && firstErr == nil {
					firstErr = perr
				}
			}
		}
	}
	if len(prefetchToDelete) > 0 {
		if delErr := s.DBBatchDeletePrefix(prefetchToDelete, true); delErr != nil && firstErr == nil {
			firstErr = delErr
		}
	}

	rankingPrefix := FormatDBKey(KeyTypeRanking, config, group)
	rankingResults, err := s.DBViewPrefixScan(rankingPrefix, -1, true)
	if err != nil {
		if firstErr == nil {
			firstErr = err
		}
		return firstErr
	}
	var rankingToDelete []string
	for path, data := range rankingResults {
		var wrapper NodeRank
		if err := json.Unmarshal(data, &wrapper); err != nil {
			rankingToDelete = append(rankingToDelete, path)
			continue
		}

		changed := false
		newResult := make([]NodeRankItem, 0, len(wrapper.Result))
		for _, rank := range wrapper.Result {
			if _, toRemove := nodeSet[rank.Name]; toRemove {
				changed = true
			} else {
				newResult = append(newResult, rank)
			}
		}

		if changed {
			if len(newResult) == 0 {
				rankingToDelete = append(rankingToDelete, path)
			} else {
				newWrapper := NodeRank{LastUpdated: wrapper.LastUpdated, Result: newResult}
				newData, merr := json.Marshal(newWrapper)
				if merr != nil {
					if firstErr == nil {
						firstErr = merr
					}
					continue
				}
				if perr := s.DBBatchPutItem(path, newData); perr != nil && firstErr == nil {
					firstErr = perr
				}
			}
		}
	}
	if len(rankingToDelete) > 0 {
		if delErr := s.DBBatchDeletePrefix(rankingToDelete, true); delErr != nil && firstErr == nil {
			firstErr = delErr
		}
	}

	var failuresToDelete []string
	failuresPrefix := FormatDBKey(KeyTypeHostFailures, config, group)
	failuresResults, err := s.DBViewPrefixScan(failuresPrefix, -1, false)
	if err != nil {
		if firstErr == nil {
			firstErr = err
		}
	} else {
		for path, data := range failuresResults {
			var hs HostStatus
			if err := json.Unmarshal(data, &hs); err != nil {
				failuresToDelete = append(failuresToDelete, path)
				continue
			}
			if hs.Codes == nil {
				continue
			}
			changed := false
			for code, codeSet := range hs.Codes {
				if codeSet == nil {
					continue
				}
				for nodeName := range codeSet.Nodes {
					if _, toRemove := nodeSet[nodeName]; toRemove {
						delete(codeSet.Nodes, nodeName)
						if codeSet.NodeHosts != nil {
							delete(codeSet.NodeHosts, nodeName)
						}
						changed = true
					}
				}
				if codeSet.FailCounts != nil {
					for nodeName := range codeSet.FailCounts {
						if _, toRemove := nodeSet[nodeName]; toRemove {
							delete(codeSet.FailCounts, nodeName)
							changed = true
						}
					}
				}
				if codeSet.Confirmations != nil {
					for nodeName := range codeSet.Confirmations {
						if _, toRemove := nodeSet[nodeName]; toRemove {
							delete(codeSet.Confirmations, nodeName)
							changed = true
						}
					}
				}
				if len(codeSet.Nodes) == 0 && len(codeSet.FailCounts) == 0 && len(codeSet.Confirmations) == 0 {
					delete(hs.Codes, code)
				}
			}
			if changed {
				if lastSlash := strings.LastIndexByte(path, '/'); lastSlash >= 0 {
					wTarget := path[lastSlash+1:]
					cachePath := FormatDBKey(KeyTypeHostFailures, config, group, wTarget)
					hostStatusCache.Delete(cachePath)
				}
				if len(hs.Codes) == 0 {
					failuresToDelete = append(failuresToDelete, path)
				} else {
					hostBlockingCount := 0
					for code, cs := range hs.Codes {
						if countsTowardBlock(code) && cs != nil {
							hostBlockingCount += len(cs.Nodes)
						}
					}
					hs.Blocked = hostBlockingCount > hostFailLimit
					newData, merr := json.Marshal(&hs)
					if merr != nil {
						if firstErr == nil {
							firstErr = merr
						}
						continue
					}
					if perr := s.DBBatchPutItem(path, newData); perr != nil && firstErr == nil {
						firstErr = perr
					}
				}
			}
		}
	}
	if len(failuresToDelete) > 0 {
		if delErr := s.DBBatchDeletePrefix(failuresToDelete, true); delErr != nil && firstErr == nil {
			firstErr = delErr
		}
	}

	nodeStateKeys := make([]string, len(nodes))
	for i, nodeName := range nodes {
		nodeStateKeys[i] = FormatDBKey(KeyTypeNode, config, group, nodeName)
	}
	if len(nodeStateKeys) > 0 {
		s.DBBatchDeletePrefix(nodeStateKeys, true)
	}

	return firstErr
}

func (s *Store) CleanupOldRecords(group, config string) {
	keyTypes := []string{KeyTypeStats, KeyTypePrefetch, KeyTypeHostFailures}

	globalCacheParams.mutex.RLock()
	maxTargets := globalCacheParams.MaxTargets
	globalCacheParams.mutex.RUnlock()

	for _, keyType := range keyTypes {
		pathPrefix := FormatDBKey(keyType, config, group)

		rawData, err := s.DBViewPrefixScan(pathPrefix, -1, false)
		if err != nil {
			continue
		}

		type targetInfo struct {
			path  string
			time  time.Time
			value float64
		}
		var records []targetInfo
		var toDelete []string

		for path, data := range rawData {
			rest, found := strings.CutPrefix(path, pathPrefix+"/")
			if !found {
				continue
			}
			target := rest
			hasNode := false
			if cut := strings.IndexByte(rest, '/'); cut >= 0 {
				target = rest[:cut]
				hasNode = true
			}
			if target == "" {
				continue
			}

			var lastTime int64
			var value float64
			switch keyType {
			case KeyTypeStats:
				if !hasNode {
					continue
				}
				var record StatsRecord
				if err := json.Unmarshal(data, &record); err != nil {
					toDelete = append(toDelete, path)
					continue
				}
				lastTime = record.LastUsed
				value = float64(record.Success + record.Failure)
			case KeyTypePrefetch:
				var pm PrefetchMap
				if err := json.Unmarshal(data, &pm); err != nil {
					toDelete = append(toDelete, path)
					continue
				}
				lastTime = pm.UpdatedTime
				value = float64(len(pm.TCP.Nodes) + len(pm.UDP.Nodes))
			case KeyTypeHostFailures:
				var stats HostStatus
				if err := json.Unmarshal(data, &stats); err != nil {
					toDelete = append(toDelete, path)
					continue
				}
				if stats.LastFailure > lastTime {
					lastTime = stats.LastFailure
				}
				totalNodes := 0
				for _, codeSet := range stats.Codes {
					if codeSet != nil {
						totalNodes += len(codeSet.Nodes)
					}
				}
				value = float64(totalNodes)
			default:
				continue
			}

			records = append(records, targetInfo{path: path, time: time.Unix(lastTime, 0), value: value})
		}

		var invalidTargets []targetInfo
		var validTargets []targetInfo
		for _, info := range records {
			if info.time.Unix() <= 0 {
				invalidTargets = append(invalidTargets, info)
			} else {
				validTargets = append(validTargets, info)
			}
		}

		totalRecords := len(records)
		toDeleteCount := totalRecords - maxTargets
		if toDeleteCount < 0 {
			toDeleteCount = 0
		}
		deleted := 0

		sort.Slice(validTargets, func(i, j int) bool {
			if validTargets[i].value != validTargets[j].value {
				return validTargets[i].value < validTargets[j].value
			}
			return validTargets[i].time.Before(validTargets[j].time)
		})

		for _, info := range validTargets {
			shouldDeleteByCount := deleted < toDeleteCount && totalRecords > maxTargets*2
			if shouldDeleteByCount || time.Since(info.time) > RecordExpiredTime {
				toDelete = append(toDelete, info.path)
				deleted++
			}
		}

		for _, info := range invalidTargets {
			toDelete = append(toDelete, info.path)
			deleted++
		}
		if len(toDelete) > 0 {
			if delErr := s.DBBatchDeletePrefix(toDelete, true); delErr != nil {
				log.Debugln("[SmartStore] Failed to batch clean records for keyType [%s], group [%s]: %v", keyType, group, delErr)
				deleted = 0
			}
		}

		if deleted > 0 {
			if keyType == KeyTypeStats {
				recordCache.RemoveByKeyPrefix(pathPrefix)
			} else if keyType == KeyTypePrefetch {
				dbResultCache.RemoveByKeyPrefix(pathPrefix)
			} else if keyType == KeyTypeHostFailures {
				hostStatusCache.RemoveByKeyPrefix(pathPrefix)
			}
			log.Debugln("[SmartStore] Cleaned up [%d] old [%s] records, group [%s] keeping [%d] valuable and recent data...",
				deleted, keyType, group, totalRecords-deleted)
		}
	}
}
