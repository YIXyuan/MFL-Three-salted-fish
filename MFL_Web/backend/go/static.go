package main

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func noCacheMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if strings.HasPrefix(p, "/api/") || strings.HasPrefix(p, "/captures/") {
			w.Header().Set("Cache-Control", "no-cache")
		} else {
			w.Header().Set("Cache-Control", "no-store")
		}
		next.ServeHTTP(w, r)
	})
}

func (a *App) handleStatic(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	if name == "" {
		name = "index.html"
	}
	if strings.Contains(name, "..") || strings.Contains(name, "\\") {
		http.NotFound(w, r)
		return
	}
	full := filepath.Join(a.frontendDir, filepath.FromSlash(name))

	if st, err := os.Stat(full); err == nil && st.IsDir() {
		http.NotFound(w, r)
		return
	}
	http.ServeFile(w, r, full)
}

func ioReadAllLimit(rc io.Reader, max int64) ([]byte, error) {
	return io.ReadAll(io.LimitReader(rc, max))
}
