package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"
)

type App struct {
	frontendDir string
	capturesDir string
	offlineMin  float64
	start       time.Time

	network  *Network
	netRaw   []byte
	pointIDs map[string]struct{}
	pointMap map[string]NetPoint
	lineName map[string]string

	store  *StateStore
	events *EventLog
	alerts *Alerts
	bus    *SseBus
	ledger *Ledger

	progMu     sync.Mutex
	progSweep  int
	progTotal  int
}

func (a *App) setProgress(sweep, total int) {
	a.progMu.Lock()
	a.progSweep, a.progTotal = sweep, total
	a.progMu.Unlock()
}

func (a *App) progress() (int, int) {
	a.progMu.Lock()
	defer a.progMu.Unlock()
	return a.progSweep, a.progTotal
}

func NewApp(frontendDir, dataPath, capturesDir, eventlogPath, ledgerPath string, offlineMin float64) (*App, error) {
	net, raw, err := LoadNetwork(dataPath)
	if err != nil {
		return nil, fmt.Errorf("管网拓扑载入失败 %s: %w", dataPath, err)
	}
	app := &App{
		frontendDir: frontendDir,
		capturesDir: capturesDir,
		offlineMin:  offlineMin,
		start:       time.Now(),
		network:     net,
		netRaw:      raw,
		pointIDs:    make(map[string]struct{}, len(net.Points)),
		pointMap:    make(map[string]NetPoint, len(net.Points)),
		lineName:    make(map[string]string, len(net.Lines)),
		store:       NewStateStore(),
		events:      NewEventLog(eventlogPath),
		alerts:      NewAlerts(),
		bus:         NewSseBus(),
		ledger:      loadLedger(ledgerPath, net),
	}
	for _, l := range net.Lines {
		app.lineName[l.ID] = l.Name
	}
	for _, p := range net.Points {
		app.pointIDs[p.ID] = struct{}{}
		app.pointMap[p.ID] = p
	}
	log.Printf("管网拓扑载入：%d 条管线 / %d 个监测点 / %d 座站场",
		len(net.Lines), len(net.Points), jsonLen(net.Stations))
	return app, nil
}

func jsonLen(raw json.RawMessage) int {
	var arr []any
	if json.Unmarshal(raw, &arr) == nil {
		return len(arr)
	}
	return 0
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/network", a.handleNetwork)
	mux.HandleFunc("GET /api/state", a.handleState)
	mux.HandleFunc("POST /api/detections", a.handleDetections)

	mux.HandleFunc("POST /api/nodes/online", a.handleNodesOnline)

	mux.HandleFunc("GET /api/progress", a.handleProgressGet)
	mux.HandleFunc("POST /api/progress", a.handleProgressPost)

	mux.HandleFunc("GET /api/selfcheck", a.handleSelfcheck)

	mux.HandleFunc("GET /api/ledger", a.handleLedger)
	mux.HandleFunc("GET /api/events", a.handleEvents)

	mux.HandleFunc("GET /api/events/history", a.handleEventsHistory)
	mux.HandleFunc("GET /api/health", a.handleHealth)
	mux.HandleFunc("GET /api/alerts", a.handleAlerts)
	mux.HandleFunc("POST /api/alerts/{id}/status", a.handleAlertStatus)
	mux.HandleFunc("GET /api/stats/coverage", a.handleCoverage)
	mux.HandleFunc("GET /api/stats/top_severe", a.handleTopSevere)
	mux.HandleFunc("GET /api/stats/volatility", a.handleVolatility)
	mux.HandleFunc("GET /api/stats/point_trend/{pid}", a.handlePointTrend)
	mux.HandleFunc("GET /api/points/{pid}/captures", a.handlePointCaptures)
	mux.HandleFunc("GET /captures/{file}", a.handleCaptureFile)
	mux.HandleFunc("GET /api/system", a.handleSystem)
	mux.HandleFunc("GET /", a.handleStatic)
	return mux
}

func (a *App) handleNetwork(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write(a.netRaw)
}

func (a *App) handleState(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{
		"server_time": nowMs(),
		"points":      a.store.Snapshot(),
	})
}

func (a *App) handleDetections(w http.ResponseWriter, r *http.Request) {
	body, err := ioReadAllLimit(r.Body, 1<<20)
	if err != nil {
		writeJSON(w, 400, map[string]any{"error": "读取请求体失败"})
		return
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var root any
	if err := dec.Decode(&root); err != nil {
		writeJSON(w, 400, map[string]any{"error": `body 需为 {"items":[...]} 或单个检测对象`})
		return
	}
	var items []any
	switch v := root.(type) {
	case map[string]any:
		if iv, ok := v["items"]; ok {
			list, ok2 := iv.([]any)
			if !ok2 {
				writeJSON(w, 400, map[string]any{"error": `body 需为 {"items":[...]} 或单个检测对象`})
				return
			}
			items = list
		} else {
			items = []any{v}
		}
	case []any:
		items = v
	default:
		writeJSON(w, 400, map[string]any{"error": `body 需为 {"items":[...]} 或单个检测对象`})
		return
	}

	now := nowMs()
	accepted := 0
	rejected := []map[string]any{}
	events := []Event{}
	alertChanged := false

	for i, it := range items {
		m, ok := it.(map[string]any)
		if !ok {
			rejected = append(rejected, map[string]any{"index": i, "reason": "item 不是对象"})
			continue
		}
		pidVal := m["point_id"]
		pid, isStr := pidVal.(string)
		if !isStr {
			rejected = append(rejected, map[string]any{"point_id": pidVal, "reason": "point_id 未知"})
			continue
		}
		if _, known := a.pointIDs[pid]; !known {
			rejected = append(rejected, map[string]any{"point_id": pidVal, "reason": "point_id 未知"})
			continue
		}

		sevOK := false
		var sev int
		if n, isNum := m["severity"].(json.Number); isNum {
			if iv, err := n.Int64(); err == nil && iv >= 0 && iv <= 2 {
				sev = int(iv)
				sevOK = true
			}
		}
		if !sevOK {
			rejected = append(rejected, map[string]any{"point_id": pid, "reason": "severity 需为 0/1/2"})
			continue
		}
		var ts int64
		if n, isNum := m["timestamp"].(json.Number); isNum {
			if iv, err := n.Int64(); err == nil && iv > 0 {
				ts = iv
			}
		}
		if ts <= 0 {
			ts = now
		}

		prev, had := a.store.Update(pid, sev, ts)
		a.events.Append(Event{PointID: pid, Severity: sev, Timestamp: ts})
		events = append(events, Event{PointID: pid, Severity: sev, Timestamp: ts})
		accepted++

		prevSev := -1
		if had && prev.Severity != nil {
			prevSev = *prev.Severity
		}
		if sev == 2 && prevSev < 2 {
			p := a.pointMap[pid]
			if a.alerts.RaiseCluster(p.Line, a.lineName[p.Line], pid, p.Mileage,
				"突发严重腐蚀："+pid+" 升级为重度") != nil {
				alertChanged = true
			}
		}

		if len(a.alerts.ResolveOffline(pid)) > 0 {
			alertChanged = true
		}
	}

	if len(events) > 0 {
		a.bus.Publish(map[string]any{"type": "detection", "items": events})
	}
	if alertChanged {
		a.bus.Publish(map[string]any{"type": "alert"})
	}
	writeJSON(w, 200, map[string]any{
		"accepted": accepted, "rejected": rejected, "server_time": now,
	})
}

func (a *App) handleNodesOnline(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Items []string `json:"items"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body.Items) == 0 {
		writeJSON(w, 400, map[string]any{"error": "body 需为 {\"items\":[point_id...]}"})
		return
	}
	valid := make([]string, 0, len(body.Items))
	unknown := 0
	for _, pid := range body.Items {
		if _, ok := a.pointIDs[pid]; ok {
			valid = append(valid, pid)
		} else {
			unknown++
		}
	}
	n := a.store.MarkOnline(valid)
	if n > 0 {
		a.bus.Publish(map[string]any{"type": "online"})
	}
	writeJSON(w, 200, map[string]any{
		"online": n, "unknown": unknown, "server_time": nowMs(),
	})
}

func (a *App) handleEventsHistory(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var since, until int64
	if v, err := strconv.ParseInt(q.Get("since"), 10, 64); err == nil {
		since = v
	}
	if v, err := strconv.ParseInt(q.Get("until"), 10, 64); err == nil && v > 0 {
		until = v
	} else {
		until = nowMs()
	}
	const limit = 50000
	all := a.events.All()
	out := make([]Event, 0, len(all))
	for _, e := range all {
		if e.Timestamp >= since && e.Timestamp <= until {
			out = append(out, e)
		}
	}
	if len(out) > limit {
		out = out[len(out)-limit:]
	}
	writeJSON(w, 200, map[string]any{
		"events": out, "server_time": nowMs(), "count": len(out),
	})
}

func (a *App) handleSelfcheck(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, a.collectSelfcheck())
}

func (a *App) handleProgressPost(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Sweep int `json:"sweep"`
		Total int `json:"total"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Sweep <= 0 {
		writeJSON(w, 400, map[string]any{"error": "body 需为 {\"sweep\":k,\"total\":T}"})
		return
	}
	a.setProgress(body.Sweep, body.Total)
	a.bus.Publish(map[string]any{"type": "progress", "sweep": body.Sweep, "total": body.Total})
	writeJSON(w, 200, map[string]any{"ok": true, "sweep": body.Sweep, "total": body.Total})
}

func (a *App) handleProgressGet(w http.ResponseWriter, r *http.Request) {
	sw, tot := a.progress()
	if tot <= 0 {
		writeJSON(w, 200, map[string]any{"active": false})
		return
	}
	writeJSON(w, 200, map[string]any{"active": true, "sweep": sw, "total": tot,
		"server_time": nowMs()})
}

func (a *App) handleEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", 500)
		return
	}
	ch := a.bus.Subscribe()
	defer a.bus.Unsubscribe(ch)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	fmt.Fprint(w, "retry: 3000\n\n")
	hello, _ := json.Marshal(map[string]any{"type": "hello", "server_time": nowMs()})
	fmt.Fprintf(w, "data: %s\n\n", hello)
	fl.Flush()

	for {
		select {
		case payload := <-ch:
			w.Write(payload)
			fl.Flush()
		case <-time.After(15 * time.Second):
			fmt.Fprint(w, ": keep-alive\n\n")
			fl.Flush()
		case <-r.Context().Done():
			return
		}
	}
}

func (a *App) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{
		"ok":                true,
		"points":            len(a.store.Snapshot()),
		"events":            a.events.Len(),
		"alerts_unresolved": a.alerts.Unresolved(),
		"sse_clients":       a.bus.Count(),
		"server_time":       nowMs(),
	})
}

func (a *App) handleAlerts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{
		"alerts":      a.alerts.Snapshot(100),
		"unresolved":  a.alerts.Unresolved(),
		"server_time": nowMs(),
	})
}

func (a *App) handleAlertStatus(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		writeJSON(w, 404, map[string]any{"error": "告警不存在"})
		return
	}
	var body struct {
		Status string `json:"status"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	valid := false
	for _, s := range alertStatuses {
		if body.Status == s {
			valid = true
		}
	}
	if !valid {
		writeJSON(w, 400, map[string]any{"error": "status 需为 待处理/处理中/已修复"})
		return
	}
	al := a.alerts.SetStatus(id, body.Status)
	if al == nil {
		writeJSON(w, 404, map[string]any{"error": "告警不存在"})
		return
	}
	a.bus.Publish(map[string]any{"type": "alert"})
	writeJSON(w, 200, al)
}
