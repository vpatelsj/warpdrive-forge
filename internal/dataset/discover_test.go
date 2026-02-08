package dataset

import (
    "os"
    "path/filepath"
    "testing"
)

func TestDiscoverShardsBasic(t *testing.T) {
    dir := t.TempDir()
    mustWrite(t, filepath.Join(dir, "shard-000000.tar"))
    mustWrite(t, filepath.Join(dir, "nested", "shard-000001.tar"))
    mustWrite(t, filepath.Join(dir, "ignore.txt"))

    shards, err := DiscoverShards(dir)
    if err != nil {
        t.Fatalf("DiscoverShards error: %v", err)
    }
    want := []string{
        filepath.Join(dir, "nested", "shard-000001.tar"),
        filepath.Join(dir, "shard-000000.tar"),
    }
    if len(shards) != len(want) {
        t.Fatalf("expected %d shards, got %d", len(want), len(shards))
    }
    for i, shard := range want {
        if shards[i] != shard {
            t.Fatalf("shard[%d]=%s want %s", i, shards[i], shard)
        }
    }
}

func TestDiscoverShardsGrowth(t *testing.T) {
    dir := t.TempDir()
    mustWrite(t, filepath.Join(dir, "shard-000000.tar"))

    first, err := DiscoverShards(dir)
    if err != nil {
        t.Fatalf("first discover error: %v", err)
    }
    if len(first) != 1 {
        t.Fatalf("expected 1 shard, got %d", len(first))
    }

    mustWrite(t, filepath.Join(dir, "shard-000001.tar"))

    second, err := DiscoverShards(dir)
    if err != nil {
        t.Fatalf("second discover error: %v", err)
    }
    if len(second) != 2 {
        t.Fatalf("expected 2 shards, got %d", len(second))
    }
}

func mustWrite(t *testing.T, path string) {
    t.Helper()
    if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
        t.Fatalf("mkdir: %v", err)
    }
    if err := os.WriteFile(path, []byte(""), 0o644); err != nil {
        t.Fatalf("write %s: %v", path, err)
    }
}
