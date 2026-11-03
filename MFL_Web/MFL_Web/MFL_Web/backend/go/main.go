package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

func main() {
	var (
		host          = flag.String("host", "0.0.0.0", "监听地址")
		port          = flag.Int("port", 8080, "监听端口")
		frontendFlag  = flag.String("frontend", "", "前端静态目录（缺省自动探测）")
		dataFlag      = flag.String("data", "", "管网拓扑 JSON（缺省自动探测）")
		capturesFlag  = flag.String("captures-dir", "", "历史磁漏图像目录（缺省自动探测）")
		ledgerFlag    = flag.String("ledger", "", "管道台账 JSON（缺省 data/ledger.json，缺失自动生成）")
		eventlogFlag  = flag.String("eventlog", "", "事件日志路径（缺省 CWD/event_log.jsonl）")
		noEventlog    = flag.Bool("no-eventlog", false, "关闭事件日志落盘")
		offlineMin    = flag.Float64("offline-minutes", 10.0, "节点离线判定阈值（分钟）")

		autoOnline    = flag.Bool("auto-online", true, "启动后自动全节点依次上线（无需等检测结果）")
		logFile       = flag.String("log-file", "", "日志文件（缺省仅控制台）")
	)
	flag.Parse()

	log.SetFlags(log.LstdFlags)
	if *logFile != "" {
		f, err := os.OpenFile(*logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err == nil {
			log.SetOutput(io.MultiWriter(os.Stdout, f))
		}
	}

	exeDir := ""
	if exe, err := os.Executable(); err == nil {
		exeDir = filepath.Dir(exe)
	}
	frontendDir := *frontendFlag
	if frontendDir == "" {
		frontendDir = firstExisting(
			"frontend",
			filepath.Join(exeDir, "frontend"),
			filepath.Join(exeDir, "..", "frontend"),
		)
	}
	dataPath := *dataFlag
	if dataPath == "" {
		dataPath = firstExisting(
			filepath.Join("data", "network.json"),
			filepath.Join(exeDir, "data", "network.json"),
			filepath.Join(exeDir, "..", "data", "network.json"),
		)
	}
	capturesDir := *capturesFlag
	if capturesDir == "" {
		if d := firstExistingDir(
			filepath.Join("data", "captures"),
			filepath.Join(exeDir, "data", "captures"),
			filepath.Join(exeDir, "..", "data", "captures"),
		); d != "" {
			capturesDir = d
		} else {
			capturesDir = filepath.Join("data", "captures")
		}
	}
	eventlogPath := *eventlogFlag
	if eventlogPath == "" {
		eventlogPath = "event_log.jsonl"
	}
	ledgerPath := *ledgerFlag
	if ledgerPath == "" {
		ledgerPath = filepath.Join("data", "ledger.json")
	}
	if *noEventlog {
		eventlogPath = ""
	}

	app, err := NewApp(frontendDir, dataPath, capturesDir, eventlogPath, ledgerPath, *offlineMin)
	if err != nil {
		log.Fatalf("启动失败：%v", err)
	}
	log.Printf("事件日志：%s", eventlogLabel(eventlogPath))
	log.Printf("监听 http://%s:%d （浏览器访问 http://<本机IP>:%d）", *host, *port, *port)

	go offlineSweeper(app)

	if *autoOnline {
		go func() {
			time.Sleep(2500 * time.Millisecond)
			ids := make([]string, 0, len(app.pointIDs))
			for pid := range app.pointIDs {
				ids = append(ids, pid)
			}
			sort.Strings(ids)
			const batch = 60
			for i := 0; i < len(ids); i += batch {
				end := i + batch
				if end > len(ids) {
					end = len(ids)
				}
				app.store.MarkOnline(ids[i:end])
				app.bus.Publish(map[string]any{"type": "online"})
				time.Sleep(120 * time.Millisecond)
			}
			log.Printf("自动上线完成：%d 个节点", len(ids))
		}()
	}

	srv := &http.Server{
		Addr:    fmt.Sprintf("%s:%d", *host, *port),
		Handler: noCacheMiddleware(app.routes()),
	}
	log.Fatal(srv.ListenAndServe())
}

func offlineSweeper(app *App) {
	threshold := int64(float64(app.offlineMin) * 60 * 1000)
	if threshold < 1000 {
		threshold = 1000
	}
	for {
		time.Sleep(15 * time.Second)
		raised := false
		for pid, rec := range app.store.Snapshot() {

			if !rec.Detected {
				continue
			}
			if nowMs()-rec.Timestamp > threshold {
				if app.alerts.Raise("offline", pid,
					"节点意外离线：超过 "+formatG(app.offlineMin)+" 分钟无检测数据") != nil {
					raised = true
				}
			}
		}
		if raised {
			app.bus.Publish(map[string]any{"type": "alert"})
		}
	}
}

func firstExisting(paths ...string) string {
	for _, p := range paths {
		if p != "" {
			if st, err := os.Stat(p); err == nil && !st.IsDir() {
				return p
			}
		}
	}
	return paths[0]
}

func firstExistingDir(paths ...string) string {
	for _, p := range paths {
		if p != "" {
			if st, err := os.Stat(p); err == nil && st.IsDir() {
				return p
			}
		}
	}
	return ""
}

func nowMs() int64 { return time.Now().UnixMilli() }

func formatG(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

func eventlogLabel(p string) string {
	if p == "" {
		return "（已关闭 --no-eventlog）"
	}
	return p
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	_ = enc.Encode(v)
}
