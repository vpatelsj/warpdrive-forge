package dataset

import (
	"archive/tar"
	"bytes"
	"context"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
	"time"
)

func TestBuildRoundRobinOrderDeterministic(t *testing.T) {
	roots := map[string][]string{
		"/rootA": {"/rootA/shard-000000.tar", "/rootA/shard-000002.tar"},
		"/rootB": {"/rootB/shard-000001.tar"},
	}
	rng1 := rand.New(rand.NewSource(7))
	rng2 := rand.New(rand.NewSource(7))

	order1 := buildRoundRobinOrder(roots, rng1)
	order2 := buildRoundRobinOrder(roots, rng2)

	if !reflect.DeepEqual(order1, order2) {
		t.Fatalf("round robin order not deterministic: %v vs %v", order1, order2)
	}

	if len(order1) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(order1))
	}

	if order1[0].root == order1[1].root {
		t.Fatalf("expected alternating roots, got %v", order1)
	}
}

func TestSamplerDeterministicStream(t *testing.T) {
	temp := t.TempDir()
	rootA := filepath.Join(temp, "rootA")
	rootB := filepath.Join(temp, "rootB")
	mustShard(t, filepath.Join(rootA, "shard-000000.tar"), map[string]int{"a0": 0})
	mustShard(t, filepath.Join(rootA, "shard-000002.tar"), map[string]int{"a1": 1})
	mustShard(t, filepath.Join(rootB, "shard-000001.tar"), map[string]int{"b0": 2})

	opts := SamplerOptions{
		Roots: map[string][]string{
			rootA: {
				filepath.Join(rootA, "shard-000000.tar"),
				filepath.Join(rootA, "shard-000002.tar"),
			},
			rootB: {
				filepath.Join(rootB, "shard-000001.tar"),
			},
		},
		Seed:       123,
		NumWorkers: 2,
	}

	samplesRun1 := collectSamples(t, opts, 3)
	samplesRun2 := collectSamples(t, opts, 3)

	if !reflect.DeepEqual(samplesRun1, samplesRun2) {
		t.Fatalf("sampler order not deterministic: %v vs %v", samplesRun1, samplesRun2)
	}
}

func collectSamples(t *testing.T, opts SamplerOptions, count int) []string {
	ctx, cancel := context.WithCancel(context.Background())
	stream, errCh, err := StartSampler(ctx, opts)
	if err != nil {
		t.Fatalf("StartSampler error: %v", err)
	}
	defer cancel()

	out := make([]string, 0, count)
	deadline := time.After(time.Second)
	for len(out) < count {
		select {
		case sample, ok := <-stream:
			if !ok {
				t.Fatalf("stream closed early; collected %d samples", len(out))
			}
			out = append(out, sample.Key)
		case err := <-errCh:
			if err != nil {
				t.Fatalf("sampler reported error: %v", err)
			}
		case <-deadline:
			t.Fatal("timed out waiting for samples")
		}
	}
	cancel()
	for err := range errCh {
		if err != nil {
			t.Fatalf("sampler emitted error after cancel: %v", err)
		}
	}
	return out
}

func mustShard(t *testing.T, path string, samples map[string]int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	buf := &bytes.Buffer{}
	tw := tar.NewWriter(buf)
	for key, label := range samples {
		addTarPayload(t, tw, key+".jpg", []byte(key))
		addTarPayload(t, tw, key+".cls", []byte(strconv.Itoa(label)))
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatalf("write shard: %v", err)
	}
}

func addTarPayload(t *testing.T, tw *tar.Writer, name string, data []byte) {
	t.Helper()
	hdr := &tar.Header{Name: name, Size: int64(len(data)), Mode: 0o644}
	if err := tw.WriteHeader(hdr); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := tw.Write(data); err != nil {
		t.Fatalf("write data: %v", err)
	}
}
