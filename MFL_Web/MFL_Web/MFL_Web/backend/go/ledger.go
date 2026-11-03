package main

import (
	"encoding/json"
	"math/rand"
	"net/http"
	"os"
	"time"
)

type LedgerEntry struct {
	InstalledMS int64   `json:"installed_ms"`
	AgeYears    float64 `json:"age_years"`
	WallMM      float64 `json:"wall_mm"`
	Material    string  `json:"material"`
	LastPigMS   int64   `json:"last_pig_ms"`
}

type Ledger struct {
	Points map[string]LedgerEntry `json:"points"`
}

func genLedgerData(network *Network, seed int64, now time.Time) *Ledger {
	rng := rand.New(rand.NewSource(seed))
	lg := &Ledger{Points: make(map[string]LedgerEntry, len(network.Points))}
	materials := []string{"L245", "L360", "L415", "X52", "X60", "X65"}
	for _, p := range network.Points {
		var age float64
		if len(p.Line) > 0 && p.Line[0] == 'T' {
			age = 5 + rng.Float64()*7
		} else {
			age = 2 + rng.Float64()*8
		}
		lg.Points[p.ID] = LedgerEntry{
			InstalledMS: now.Add(-time.Duration(age * 365.25 * 24 * float64(time.Hour))).UnixMilli(),
			AgeYears:    age,
			WallMM:      float64(int((6.4+rng.Float64()*6.3)*10)) / 10,
			Material:    materials[rng.Intn(len(materials))],
			LastPigMS:   now.Add(-time.Duration(rng.Float64() * 370 * 24 * float64(time.Hour))).UnixMilli(),
		}
	}
	return lg
}

func loadLedger(path string, network *Network) *Ledger {
	if data, err := os.ReadFile(path); err == nil {
		var lg Ledger
		if json.Unmarshal(data, &lg) == nil && len(lg.Points) > 0 {
			return &lg
		}
	}
	lg := genLedgerData(network, 42, time.Now())
	if data, err := json.MarshalIndent(lg, "", " "); err == nil {
		_ = os.WriteFile(path, data, 0o644)
	}
	return lg
}

func (a *App) handleLedger(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{
		"points": a.ledger.Points,
	})
}
