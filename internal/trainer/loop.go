package trainer

import (
	"bytes"
	"context"
	"errors"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"log"
	"math"
	"time"

	"warpdrive-forge/internal/dataset"
	"warpdrive-forge/internal/metrics"
	"warpdrive-forge/internal/model"
)

const featureGrid = 16
const featureSize = featureGrid * featureGrid
const numClasses = 1000

// RunConfig captures the knobs required by the training loop.
type RunConfig struct {
	Roots      map[string][]string
	Steps      int
	BatchSize  int
	NumWorkers int
	LogEvery   int
	Seed       int64
}

// Run executes the training workload.
func Run(ctx context.Context, cfg RunConfig) error {
	if cfg.Steps <= 0 {
		return errors.New("trainer: steps must be > 0")
	}
	if cfg.BatchSize <= 0 {
		return errors.New("trainer: batch size must be > 0")
	}
	if cfg.LogEvery <= 0 {
		cfg.LogEvery = 50
	}

	samplerCh, samplerErr, err := dataset.StartSampler(ctx, dataset.SamplerOptions{
		Roots:      cfg.Roots,
		Seed:       cfg.Seed,
		NumWorkers: cfg.NumWorkers,
	})
	if err != nil {
		return err
	}

	mdl := model.NewSimpleCNN(numClasses, featureSize, 0.05, cfg.Seed)
	var window metrics.Window

	for step := 1; step <= cfg.Steps; step++ {
		startData := time.Now()
		batch, err := nextBatch(ctx, samplerCh, samplerErr, cfg.BatchSize)
		if err != nil {
			return err
		}
		dataTime := time.Since(startData)

		startCompute := time.Now()
		loss := mdl.TrainStep(batch)
		computeTime := time.Since(startCompute)

		window.Record(cfg.BatchSize, dataTime, computeTime, loss)

		if step%cfg.LogEvery == 0 {
			snap := window.Snapshot()
			log.Printf("step=%d images_per_sec=%.1f data_ms=%.2f compute_ms=%.2f loss=%.4f",
				step,
				snap.ImagesPerSec,
				snap.AvgDataMS,
				snap.AvgComputeMS,
				snap.LastLoss,
			)
		}
	}

	return nil
}

func nextBatch(ctx context.Context, samples <-chan dataset.Sample, errs <-chan error, batchSize int) (model.Batch, error) {
	inputs := make([][]float64, 0, batchSize)
	labels := make([]int, 0, batchSize)
	for len(inputs) < batchSize {
		select {
		case <-ctx.Done():
			return model.Batch{}, ctx.Err()
		case err, ok := <-errs:
			if ok && err != nil {
				return model.Batch{}, err
			}
		case sample, ok := <-samples:
			if !ok {
				return model.Batch{}, errors.New("sampler closed")
			}
			features, err := extractFeatures(sample.Image)
			if err != nil {
				continue
			}
			inputs = append(inputs, features)
			labels = append(labels, clampLabel(sample.Label))
		}
	}
	return model.Batch{Inputs: inputs, Labels: labels}, nil
}

func extractFeatures(raw []byte) ([]float64, error) {
	img, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	bounds := img.Bounds()
	width := bounds.Dx()
	height := bounds.Dy()
	if width == 0 || height == 0 {
		return nil, errors.New("empty image")
	}
	features := make([]float64, featureSize)
	stepX := float64(width) / float64(featureGrid)
	stepY := float64(height) / float64(featureGrid)
	for gy := 0; gy < featureGrid; gy++ {
		for gx := 0; gx < featureGrid; gx++ {
			px := bounds.Min.X + int(math.Min(float64(width-1), float64(gx)*stepX))
			py := bounds.Min.Y + int(math.Min(float64(height-1), float64(gy)*stepY))
			r, g, b, _ := img.At(px, py).RGBA()
			intensity := (float64(r) + float64(g) + float64(b)) / (3 * 65535.0)
			features[gy*featureGrid+gx] = intensity
		}
	}
	return features, nil
}

func clampLabel(label int) int {
	if label < 0 {
		return 0
	}
	if label >= numClasses {
		return label % numClasses
	}
	return label
}
