package main

import (
	"bufio"
	"encoding/json"
	"log"
	"os"
	"strings"
	"sync"
)

type PointState struct {
	Severity  *int  `json:"severity,omitempty"`
	Timestamp int64 `json:"timestamp,omitempty"`
	Online    bool  `json:"online,omitempty"`
	Detected  bool  `json:"detected,omitempty"`
}

type StateStore struct {
	mu     sync.RWMutex
	points map[string]PointState
}

func NewStateStore() *StateStore { return &StateStore{points: make(map[string]PointState)} }

func (s *StateStore) Update(pid string, sev int, ts int64) (PointState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	prev, had := s.points[pid]
	sevCopy := sev
	s.points[pid] = PointState{Severity: &sevCopy, Timestamp: ts,
		Online: true, Detected: true}
	return prev, had
}

func (s *StateStore) MarkOnline(ids []string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, pid := range ids {
		prev, existed := s.points[pid]
		if !existed {
			s.points[pid] = PointState{Online: true}
			n++
		} else if !prev.Online {
			prev.Online = true
			s.points[pid] = prev
			n++
		}
	}
	return n
}

func (s *StateStore) Snapshot() map[string]PointState {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]PointState, len(s.points))
	for k, v := range s.points {
		out[k] = v
	}
	return out
}

type Event struct {
	PointID   string `json:"point_id"`
	Severity  int    `json:"severity"`
	Timestamp int64  `json:"timestamp"`
}

const eventLogMax = 200000

type EventLog struct {
	mu    sync.Mutex
	items []Event
	fh    *os.File
	bw    *bufio.Writer
}

func NewEventLog(path string) *EventLog {
	el := &EventLog{}
	if path == "" {
		return el
	}
	if data, err := os.ReadFile(path); err == nil {
		for _, ln := range strings.Split(string(data), "\n") {
			ln = strings.TrimSpace(ln)
			if ln == "" {
				continue
			}
			var e Event
			if json.Unmarshal([]byte(ln), &e) == nil && e.PointID != "" {
				el.items = append(el.items, e)
			}
		}
		log.Printf("事件日志加载历史 %d 条", len(el.items))
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err == nil {
		el.fh = f
		el.bw = bufio.NewWriter(f)
	}
	return el
}

func (el *EventLog) Append(e Event) {
	el.mu.Lock()
	defer el.mu.Unlock()
	el.items = append(el.items, e)
	if len(el.items) > eventLogMax {
		el.items = append([]Event(nil), el.items[len(el.items)-eventLogMax:]...)
	}
	if el.bw != nil {
		line, _ := json.Marshal(e)
		el.bw.Write(line)
		el.bw.WriteByte('\n')
		el.bw.Flush()
	}
}

func (el *EventLog) All() []Event {
	el.mu.Lock()
	defer el.mu.Unlock()
	out := make([]Event, len(el.items))
	copy(out, el.items)
	return out
}

func (el *EventLog) Len() int {
	el.mu.Lock()
	defer el.mu.Unlock()
	return len(el.items)
}

var alertStatuses = []string{"待处理", "处理中", "已修复"}

type Alert struct {
	ID        int    `json:"id"`
	Type      string `json:"type"`
	TypeText  string `json:"type_text,omitempty"`
	Line      string `json:"line,omitempty"`
	PointID   string `json:"point_id"`
	StartPID  string `json:"start_pid,omitempty"`
	EndPID    string `json:"end_pid,omitempty"`
	RangeText string `json:"range_text,omitempty"`
	Count     int    `json:"count,omitempty"`
	StartM    float64 `json:"-"`
	EndM      float64 `json:"-"`
	Text      string `json:"text"`
	Time      int64  `json:"time"`
	Status    string `json:"status"`
}

type Alerts struct {
	mu     sync.Mutex
	list   []Alert
	nextID int
}

func NewAlerts() *Alerts { return &Alerts{nextID: 1} }

func (a *Alerts) Raise(typ, pid, text string) *Alert {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, al := range a.list {
		if al.Type == typ && al.PointID == pid && al.Status != "已修复" {
			return nil
		}
	}
	al := Alert{ID: a.nextID, Type: typ, PointID: pid, Text: text,
		Time: nowMs(), Status: "待处理"}
	if typ == "severe" {
		al.TypeText = "突发严重腐蚀"
	}
	a.nextID++
	a.list = append(a.list, al)
	return &al
}

func (a *Alerts) RaiseCluster(line, lineName, pid string, mileage float64, text string) *Alert {
	a.mu.Lock()
	defer a.mu.Unlock()
	const clusterGap = 800.0
	for i := range a.list {
		al := &a.list[i]
		if al.Type == "cluster" && al.Line == line && al.Status != "已修复" &&
			mileage >= al.StartM-clusterGap && mileage <= al.EndM+clusterGap {
			if mileage < al.StartM {
				al.StartM, al.StartPID = mileage, pid
			}
			if mileage > al.EndM {
				al.EndM, al.EndPID = mileage, pid
			}
			al.Count++
			al.RangeText = al.StartPID + "~" + al.EndPID
			al.Text = text
			al.Time = nowMs()
			cp := *al
			cp.StartM, cp.EndM = 0, 0
			return &cp
		}
	}
	al := Alert{ID: a.nextID, Type: "cluster", TypeText: lineName + "区片腐蚀",
		Line: line, PointID: pid, StartPID: pid, EndPID: pid,
		RangeText: pid + "~" + pid, Count: 1,
		StartM: mileage, EndM: mileage,
		Text: text, Time: nowMs(), Status: "待处理"}
	a.nextID++
	a.list = append(a.list, al)
	cp := al
	cp.StartM, cp.EndM = 0, 0
	return &cp
}

func (a *Alerts) ResolveOffline(pid string) []Alert {
	a.mu.Lock()
	defer a.mu.Unlock()
	var changed []Alert
	for i := range a.list {
		al := &a.list[i]
		if al.Type == "offline" && al.PointID == pid && al.Status != "已修复" {
			al.Status = "已修复"
			changed = append(changed, *al)
		}
	}
	return changed
}

func (a *Alerts) SetStatus(id int, status string) *Alert {
	a.mu.Lock()
	defer a.mu.Unlock()
	for i := range a.list {
		if a.list[i].ID == id {
			a.list[i].Status = status
			al := a.list[i]
			return &al
		}
	}
	return nil
}

func (a *Alerts) Snapshot(limit int) []Alert {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]Alert, 0, limit)
	for i := len(a.list) - 1; i >= 0 && len(out) < limit; i-- {
		out = append(out, a.list[i])
	}
	return out
}

func (a *Alerts) Unresolved() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for _, al := range a.list {
		if al.Status != "已修复" {
			n++
		}
	}
	return n
}

type SseBus struct {
	mu      sync.Mutex
	clients map[chan []byte]struct{}
}

func NewSseBus() *SseBus {
	return &SseBus{clients: make(map[chan []byte]struct{})}
}

func (b *SseBus) Subscribe() chan []byte {
	ch := make(chan []byte, 256)
	b.mu.Lock()
	b.clients[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *SseBus) Unsubscribe(ch chan []byte) {
	b.mu.Lock()
	delete(b.clients, ch)
	b.mu.Unlock()
}

func (b *SseBus) Publish(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	payload := make([]byte, 0, len(data)+8)
	payload = append(payload, "data: "...)
	payload = append(payload, data...)
	payload = append(payload, '\n', '\n')
	b.mu.Lock()
	chans := make([]chan []byte, 0, len(b.clients))
	for ch := range b.clients {
		chans = append(chans, ch)
	}
	b.mu.Unlock()
	for _, ch := range chans {
		select {
		case ch <- payload:
		default:
		}
	}
}

func (b *SseBus) Count() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.clients)
}

type NetPoint struct {
	ID      string  `json:"id"`
	Line    string  `json:"line"`
	Mileage float64 `json:"mileage"`
	X       float64 `json:"x"`
	Y       float64 `json:"y"`
}

type NetLine struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Type       string      `json:"type"`
	Waypoints  [][]float64 `json:"waypoints"`
	LengthM    float64     `json:"length_m"`
	PointCount int         `json:"point_count"`
}

type Network struct {
	Meta     json.RawMessage `json:"meta"`
	Lines    []NetLine       `json:"lines"`
	Stations json.RawMessage `json:"stations"`
	Points   []NetPoint      `json:"points"`
}

func LoadNetwork(path string) (*Network, []byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	var net Network
	if err := json.Unmarshal(raw, &net); err != nil {
		return nil, nil, err
	}
	return &net, raw, nil
}
