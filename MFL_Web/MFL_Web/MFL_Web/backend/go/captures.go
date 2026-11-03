package main

import (
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var capRe = regexp.MustCompile(`^(P\d{4})_(\d+)\.(png|jpe?g|bmp|gif)$`)

type Capture struct {
	File string `json:"file"`
	Seq  int64  `json:"seq"`
	Time int64  `json:"time"`
	URL  string `json:"url"`

	Severity *int `json:"severity"`
}

func scanCaptures(dir string) map[string][]Capture {
	out := make(map[string][]Capture)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := capRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		var mtime int64
		if info, err := e.Info(); err == nil {
			mtime = info.ModTime().UnixMilli()
		}
		var seq int64
		for _, c := range m[2] {
			seq = seq*10 + int64(c-'0')
		}
		out[strings.ToUpper(m[1])] = append(out[strings.ToUpper(m[1])], Capture{
			File: e.Name(), Seq: seq, Time: mtime,
			URL: "/captures/" + e.Name(),
		})
	}
	for _, lst := range out {
		sort.Slice(lst, func(i, j int) bool { return lst[i].Seq > lst[j].Seq })
	}
	return out
}

func (a *App) severityAt(pid string, ts int64) *int {
	var last *int
	for _, e := range a.events.All() {
		if e.PointID == pid && e.Timestamp <= ts {
			v := e.Severity
			last = &v
		}
	}
	return last
}

func (a *App) handlePointCaptures(w http.ResponseWriter, r *http.Request) {
	pid := r.PathValue("pid")
	caps := scanCaptures(a.capturesDir)[strings.ToUpper(pid)]
	if caps == nil {
		caps = []Capture{}
	}

	for i := range caps {
		caps[i].Severity = a.severityAt(strings.ToUpper(pid), caps[i].Time)
	}
	writeJSON(w, 200, map[string]any{"point_id": pid, "captures": caps})
}

func (a *App) handleCaptureFile(w http.ResponseWriter, r *http.Request) {
	fname := r.PathValue("file")
	if !capRe.MatchString(fname) {
		writeJSON(w, 404, map[string]any{"error": "非法文件名"})
		return
	}
	http.ServeFile(w, r, filepath.Join(a.capturesDir, fname))
}
