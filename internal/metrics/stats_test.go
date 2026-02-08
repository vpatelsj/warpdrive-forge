package metrics

import (
	"math"
	"testing"
	"time"
)

func TestWindowSnapshot(t *testing.T) {
	var w Window
	w.Record(64, 20*time.Millisecond, 10*time.Millisecond, 1.2)
	w.Record(64, 10*time.Millisecond, 20*time.Millisecond, 0.8)
	snap := w.Snapshot()
	if math.Abs(snap.ImagesPerSec-2133.3333) > 1 {
		t.Fatalf("unexpected throughput %.2f", snap.ImagesPerSec)
	}
	if w.samples != 0 || w.steps != 0 {
		t.Fatalf("window was not reset")
	}
	if snap.LastLoss != 0.8 {
		t.Fatalf("expected last loss 0.8, got %.2f", snap.LastLoss)
	}
}
