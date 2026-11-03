package main

import (
	"math"
	"net/http"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

func round1(v float64) float64 { return math.Round(v*10) / 10 }
func round2(v float64) float64 { return math.Round(v*100) / 100 }

func (a *App) handleCoverage(w http.ResponseWriter, r *http.Request) {
	coveredSet := make(map[string]struct{})

	for pid, rec := range a.store.Snapshot() {
		if rec.Detected {
			coveredSet[pid] = struct{}{}
		}
	}
	type cov struct {
		ID      string  `json:"id"`
		Name    string  `json:"name"`
		Total   int     `json:"total"`
		Covered int     `json:"covered"`
		Pct     float64 `json:"pct"`
	}
	type overallCov struct {
		Total   int     `json:"total"`
		Covered int     `json:"covered"`
		Pct     float64 `json:"pct"`
	}
	var lines []cov
	overall := overallCov{}
	for _, l := range a.network.Lines {
		c := cov{ID: l.ID, Name: l.Name}
		for _, p := range a.network.Points {
			if p.Line != l.ID {
				continue
			}
			c.Total++
			if _, ok := coveredSet[p.ID]; ok {
				c.Covered++
			}
		}
		if c.Total > 0 {
			c.Pct = round1(float64(c.Covered) * 100.0 / float64(c.Total))
		}
		overall.Total += c.Total
		overall.Covered += c.Covered
		lines = append(lines, c)
	}
	if overall.Total > 0 {
		overall.Pct = round1(float64(overall.Covered) * 100.0 / float64(overall.Total))
	}
	if lines == nil {
		lines = []cov{}
	}
	writeJSON(w, 200, map[string]any{"overall": overall, "lines": lines})
}

func (a *App) handleTopSevere(w http.ResponseWriter, r *http.Request) {
	const limit = 10
	counts := make(map[string]int)

	firstSeen := make(map[string]int)
	seen := 0
	for _, e := range a.events.All() {
		if e.Severity == 2 {
			if _, ok := counts[e.PointID]; !ok {
				firstSeen[e.PointID] = seen
				seen++
			}
			counts[e.PointID]++
		}
	}
	type row struct {
		PointID  string  `json:"point_id"`
		Count    int     `json:"count"`
		Line     *string `json:"line"`
		LineName string  `json:"line_name"`
		MileageM float64 `json:"mileage_m"`
		Current  *int    `json:"current"`
	}
	ids := make([]string, 0, len(counts))
	for pid := range counts {
		ids = append(ids, pid)
	}
	sort.Slice(ids, func(i, j int) bool {
		if counts[ids[i]] != counts[ids[j]] {
			return counts[ids[i]] > counts[ids[j]]
		}
		return firstSeen[ids[i]] < firstSeen[ids[j]]
	})
	if len(ids) > limit {
		ids = ids[:limit]
	}
	cur := a.store.Snapshot()
	items := make([]row, 0, len(ids))
	for _, pid := range ids {
		it := row{PointID: pid, Count: counts[pid]}
		if p, ok := a.pointMap[pid]; ok {
			ln := p.Line
			it.Line = &ln
			it.LineName = a.lineName[p.Line]
			it.MileageM = p.Mileage
		}
		if st, ok := cur[pid]; ok && st.Severity != nil {

			it.Current = st.Severity
		}
		items = append(items, it)
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (a *App) handleVolatility(w http.ResponseWriter, r *http.Request) {
	const limit = 20
	series := make(map[string][]Event)
	order := []string{}
	for _, e := range a.events.All() {
		if _, ok := series[e.PointID]; !ok {
			order = append(order, e.PointID)
		}
		series[e.PointID] = append(series[e.PointID], e)
	}
	cur := a.store.Snapshot()
	type row struct {
		PointID     string  `json:"point_id"`
		Volatility  float64 `json:"volatility"`
		TV          float64 `json:"tv"`
		Transitions int     `json:"transitions"`
		Max         int     `json:"max"`
		Min         int     `json:"min"`
		Current     *int    `json:"current"`
		Line        *string `json:"line"`
		LineName    string  `json:"line_name"`
		MileageM    float64 `json:"mileage_m"`
	}
	rows := make([]row, 0, len(series))
	for _, pid := range order {
		s := series[pid]
		sort.Slice(s, func(i, j int) bool {
			if s[i].Timestamp != s[j].Timestamp {
				return s[i].Timestamp < s[j].Timestamp
			}
			return s[i].Severity < s[j].Severity
		})
		tv := 0.0
		mx, mn := s[0].Severity, s[0].Severity
		for i := 1; i < len(s); i++ {
			tv += math.Abs(float64(s[i].Severity - s[i-1].Severity))
			if s[i].Severity > mx {
				mx = s[i].Severity
			}
			if s[i].Severity < mn {
				mn = s[i].Severity
			}
		}
		trans := len(s) - 1
		it := row{
			PointID:     pid,
			Volatility:  round2(tv + 0.5*float64(trans)),
			TV:          round2(tv),
			Transitions: trans,
			Max:         mx,
			Min:         mn,
		}
		if st, ok := cur[pid]; ok && st.Severity != nil {

			it.Current = st.Severity
		}
		if p, ok := a.pointMap[pid]; ok {
			ln := p.Line
			it.Line = &ln
			it.LineName = a.lineName[p.Line]
			it.MileageM = p.Mileage
		}
		rows = append(rows, it)
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Volatility > rows[j].Volatility })
	if len(rows) > limit {
		rows = rows[:limit]
	}
	writeJSON(w, 200, map[string]any{"items": rows})
}

func (a *App) handlePointTrend(w http.ResponseWriter, r *http.Request) {
	pid := r.PathValue("pid")
	if _, ok := a.pointIDs[pid]; !ok {
		writeJSON(w, 404, map[string]any{"error": "point_id 未知"})
		return
	}
	const maxPoints = 600
	var s []Event
	for _, e := range a.events.All() {
		if e.PointID == pid {
			s = append(s, e)
		}
	}
	sort.Slice(s, func(i, j int) bool {
		if s[i].Timestamp != s[j].Timestamp {
			return s[i].Timestamp < s[j].Timestamp
		}
		return s[i].Severity < s[j].Severity
	})
	if len(s) > maxPoints {
		step := float64(len(s)) / float64(maxPoints)
		sampled := make([]Event, maxPoints)
		for i := 0; i < maxPoints; i++ {
			sampled[i] = s[int(float64(i)*step)]
		}
		s = sampled
	}
	series := make([][]int64, len(s))
	for i, e := range s {
		series[i] = []int64{e.Timestamp, int64(e.Severity)}
	}
	resp := map[string]any{
		"point_id": pid,
		"series":   series,
	}
	if p, ok := a.pointMap[pid]; ok {
		resp["line"] = p.Line
		resp["line_name"] = a.lineName[p.Line]
		resp["mileage_m"] = p.Mileage
	}
	writeJSON(w, 200, resp)
}

func (a *App) handleSystem(w http.ResponseWriter, r *http.Request) {
	platform := "PC 开发机"
	var cpuPct, memUsedPct, memTotalMB *float64
	if l1, cores, memTotalKB, memAvailKB, ok := readProcStats(); ok {
		platform = "板端 Linux"
		v := round1(math.Min(200.0, l1/float64(cores)*100))
		cpuPct = &v
		mt := round1(float64(memTotalKB) / 1024)
		memTotalMB = &mt
		mu := round1(float64(memTotalKB-memAvailKB) * 100.0 / float64(memTotalKB))
		memUsedPct = &mu
	}

	snap := a.store.Snapshot()
	var lastTs int64

	detected := 0
	for _, rec := range snap {
		if !rec.Detected {
			continue
		}
		detected++
		if rec.Timestamp > lastTs {
			lastTs = rec.Timestamp
		}
	}
	var lastAge *int64
	link := "空闲"
	if lastTs > 0 {
		age := (nowMs() - lastTs) / 1000
		if age < 0 {
			age = 0
		}
		lastAge = &age
		if age <= 60 {
			link = "活跃"
		}
	}

	writeJSON(w, 200, map[string]any{
		"platform":         platform,

		"started_at_ms":    a.start.UnixMilli(),
		"uptime_s":         int64(time.Since(a.start).Seconds()),
		"cpu_pct":          cpuPct,
		"mem_used_pct":     memUsedPct,
		"mem_total_mb":     memTotalMB,
		"events_total":     a.events.Len(),
		"points_with_data": detected,
		"last_event_age_s": lastAge,
		"link":             link,
		"sse_clients":      a.bus.Count(),
		"alerts_unresolved": a.alerts.Unresolved(),
		"server_time":      nowMs(),
	})
}

func readProcStats() (l1 float64, cores int, memTotalKB, memAvailKB int64, ok bool) {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, 0, 0, 0, false
	}
	fields := strings.Fields(string(data))
	if len(fields) < 1 {
		return 0, 0, 0, 0, false
	}
	l1, err = strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, 0, 0, 0, false
	}
	cores = runtime.NumCPU()

	mem, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0, 0, 0, false
	}
	for _, ln := range strings.Split(string(mem), "\n") {
		kv := strings.SplitN(ln, ":", 2)
		if len(kv) != 2 {
			continue
		}
		k := strings.TrimSpace(kv[0])
		vf := strings.Fields(strings.TrimSpace(kv[1]))
		if len(vf) == 0 {
			continue
		}
		v, err := strconv.ParseInt(vf[0], 10, 64)
		if err != nil {
			continue
		}
		if k == "MemTotal" {
			memTotalKB = v
		} else if k == "MemAvailable" {
			memAvailKB = v
		}
	}
	if memTotalKB == 0 {
		return 0, 0, 0, 0, false
	}
	return l1, cores, memTotalKB, memAvailKB, true
}
