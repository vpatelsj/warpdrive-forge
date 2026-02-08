package metrics

import "time"

// Window accumulates timing stats across multiple steps.
type Window struct {
	samples  int
	data     time.Duration
	compute  time.Duration
	steps    int
	lastLoss float64
}

// Record adds a new measurement to the window.
func (w *Window) Record(batchSize int, dataTime, computeTime time.Duration, loss float64) {
	w.samples += batchSize
	w.data += dataTime
	w.compute += computeTime
	w.steps++
	w.lastLoss = loss
}

// Snapshot returns aggregated metrics and resets the window.
func (w *Window) Snapshot() Snapshot {
	snap := Snapshot{}
	total := w.data + w.compute
	if total > 0 {
		snap.ImagesPerSec = float64(w.samples) / total.Seconds()
	}
	if w.steps > 0 {
		snap.AvgDataMS = (w.data.Seconds() * 1000) / float64(w.steps)
		snap.AvgComputeMS = (w.compute.Seconds() * 1000) / float64(w.steps)
	}
	snap.LastLoss = w.lastLoss

	w.samples = 0
	w.data = 0
	w.compute = 0
	w.steps = 0
	return snap
}

// Snapshot represents loggable metrics.
type Snapshot struct {
	ImagesPerSec float64
	AvgDataMS    float64
	AvgComputeMS float64
	LastLoss     float64
}
