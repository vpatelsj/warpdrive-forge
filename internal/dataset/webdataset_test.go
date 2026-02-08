package dataset

import (
	"archive/tar"
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestStreamShardPairsEntries(t *testing.T) {
	buf := buildShard(map[string]filePair{
		"000001": {imageExt: ".jpg", image: []byte("jpeg"), label: 3},
		"000002": {imageExt: ".png", image: []byte("png"), label: 7},
	})

	dir := t.TempDir()
	shard := filepath.Join(dir, "shard-000000.tar")
	if err := os.WriteFile(shard, buf.Bytes(), 0o644); err != nil {
		t.Fatalf("write shard: %v", err)
	}

	ctx := context.Background()
	samplesCh, errCh := StreamShard(ctx, shard, 4)

	var samples []Sample
	for samplesCh != nil || errCh != nil {
		select {
		case sample, ok := <-samplesCh:
			if !ok {
				samplesCh = nil
				continue
			}
			samples = append(samples, sample)
		case err, ok := <-errCh:
			if !ok {
				errCh = nil
				continue
			}
			if err != nil {
				t.Fatalf("StreamShard returned error: %v", err)
			}
			errCh = nil
		}
	}

	if len(samples) != 2 {
		t.Fatalf("expected 2 samples, got %d", len(samples))
	}
}

func buildShard(data map[string]filePair) *bytes.Buffer {
	buf := &bytes.Buffer{}
	tw := tar.NewWriter(buf)
	for key, pair := range data {
		addTarEntry(tw, key+pair.imageExt, pair.image)
		addTarEntry(tw, key+".cls", []byte(strconv.Itoa(pair.label)))
	}
	tw.Close()
	return buf
}

type filePair struct {
	imageExt string
	image    []byte
	label    int
}

func addTarEntry(tw *tar.Writer, name string, data []byte) {
	hdr := &tar.Header{Name: name, Size: int64(len(data)), Mode: 0o644}
	if err := tw.WriteHeader(hdr); err != nil {
		panic(err)
	}
	if _, err := tw.Write(data); err != nil {
		panic(err)
	}
}
