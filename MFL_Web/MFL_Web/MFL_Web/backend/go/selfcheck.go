package main

import (
	"os"
	"runtime"
	"strconv"
	"time"
)

type CheckItem struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Value  string `json:"value"`
}

func (el *EventLog) countSince(ts int64) int {
	el.mu.Lock()
	defer el.mu.Unlock()
	n := 0
	for i := len(el.items) - 1; i >= 0; i-- {
		if el.items[i].Timestamp >= ts {
			n++
		} else {
			break
		}
	}
	return n
}

func (el *EventLog) pathSize() int64 {
	if el.fh == nil {
		return 0
	}
	if st, err := el.fh.Stat(); err == nil {
		return st.Size()
	}
	return 0
}

func dirStats(dir string) (int, int64) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, 0
	}
	n, sum := 0, int64(0)
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if info, err := e.Info(); err == nil {
			n++
			sum += info.Size()
		}
	}
	return n, sum
}

func fmtMB(b int64) string {
	return strconv.FormatFloat(float64(b)/1048576, 'f', 2, 64) + " MB"
}

func (a *App) collectSelfcheck() map[string]any {
	now := nowMs()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	heapMB := strconv.FormatFloat(float64(m.HeapAlloc)/1048576, 'f', 1, 64)
	sysMB := strconv.FormatFloat(float64(m.Sys)/1048576, 'f', 1, 64)
	goroutines := runtime.NumGoroutine()

	ev60 := a.events.countSince(now - 60_000)
	ev5 := a.events.countSince(now - 5_000)

	capN, capBytes := dirStats(a.capturesDir)

	logBytes := a.events.pathSize()
	logCount := a.events.Len()
	unresolved := a.alerts.Unresolved()

	items := []CheckItem{}
	items = append(items, CheckItem{Name: "管网拓扑", Status: "ok",
		Value: strconv.Itoa(len(a.network.Lines)) + " 线 / " + strconv.Itoa(len(a.network.Points)) + " 点"})
	logStatus := "ok"
	if logBytes > 5*1048576 {
		logStatus = "warn"
	}
	items = append(items, CheckItem{Name: "事件日志", Status: logStatus,
		Value: strconv.Itoa(logCount) + " 条 / " + fmtMB(logBytes)})
	items = append(items, CheckItem{Name: "历史图像目录", Status: "ok",
		Value: strconv.Itoa(capN) + " 个文件 / " + fmtMB(capBytes)})
	linkStatus := "ok"
	linkVal := "空闲"
	if ev60 > 0 {
		linkVal = "活跃（60s 内 " + strconv.Itoa(ev60) + " 条）"
	}
	items = append(items, CheckItem{Name: "上报链路", Status: linkStatus, Value: linkVal})
	sse := a.bus.Count()
	sseStatus := "ok"
	sseVal := strconv.Itoa(sse) + " 个客户端"
	if sse == 0 {
		sseStatus = "warn"
		sseVal += "（无浏览器连接）"
	}
	items = append(items, CheckItem{Name: "前端推送", Status: sseStatus, Value: sseVal})
	blkStatus := "ok"
	if unresolved > 50 {
		blkStatus = "warn"
	}
	items = append(items, CheckItem{Name: "告警积压", Status: blkStatus,
		Value: strconv.Itoa(unresolved) + " 条未处理"})

	offN := 0
	for _, al := range a.alerts.Snapshot(10000) {
		if al.Type == "offline" && al.Status != "已修复" {
			offN++
		}
	}
	offStatus := "ok"
	if offN > 0 {
		offStatus = "warn"
	}
	items = append(items, CheckItem{Name: "离线节点", Status: offStatus,
		Value: strconv.Itoa(offN) + " 个未恢复"})

	var cpuPct, memUsedPct, memTotalMB any
	cpuPct, memUsedPct, memTotalMB = nil, nil, nil
	if l1, cores, memTotalKB, memAvailKB, ok := readProcStats(); ok {
		v := strconv.FormatFloat(minF(200, l1/float64(cores)*100), 'f', 1, 64)
		cpuPct = v + "%"
		mu := roundF(float64(memTotalKB-memAvailKB) * 100 / float64(memTotalKB))
		memUsedPct = strconv.FormatFloat(mu, 'f', 1, 64)
		mt := strconv.Itoa(int(memTotalKB / 1024))
		memTotalMB = mt + " MB"
	}

	return map[string]any{
		"platform":       platformName(),
		"go_version":     runtime.Version(),
		"goroutines":     goroutines,
		"heap_mb":        heapMB,
		"sys_mb":         sysMB,
		"cpu_load":       cpuPct,
		"mem_used_pct":   memUsedPct,
		"mem_total_mb":   memTotalMB,
		"started_at_ms":  a.start.UnixMilli(),
		"uptime_s":       int64(time.Since(a.start).Seconds()),
		"events_total":   a.events.Len(),
		"events_60s":     ev60,
		"events_5s":      ev5,
		"log_bytes":      logBytes,
		"captures_files": capN,
		"captures_bytes": capBytes,
		"sse_clients":    a.bus.Count(),
		"alerts_unresolved": unresolved,
		"items":          items,
		"server_time":    now,
	}
}

func minF(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

func roundF(v float64) float64 {
	return float64(int(v*10+0.5)) / 10
}

func platformName() string {
	if _, _, _, _, ok := readProcStats(); ok {
		return "板端 Linux"
	}
	return "PC 开发机"
}
