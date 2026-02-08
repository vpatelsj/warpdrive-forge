package dataset

import (
    "fmt"
    "io/fs"
    "path/filepath"
    "regexp"
    "sort"
)

var shardRegexp = regexp.MustCompile(`^shard-[0-9]{6,}\.tar$`)

// DiscoverShards returns absolute paths to shard TAR files beneath root.
func DiscoverShards(root string) ([]string, error) {
    entries := make([]string, 0)
    err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
        if err != nil {
            return err
        }
        if d.IsDir() {
            return nil
        }
        if shardRegexp.MatchString(d.Name()) {
            entries = append(entries, path)
        }
        return nil
    })
    if err != nil {
        return nil, fmt.Errorf("discover shards: %w", err)
    }
    sort.Strings(entries)
    return entries, nil
}

// DiscoverByRoot scans each root independently.
func DiscoverByRoot(roots []string) (map[string][]string, error) {
    result := make(map[string][]string, len(roots))
    for _, root := range roots {
        shards, err := DiscoverShards(root)
        if err != nil {
            return nil, err
        }
        result[root] = shards
    }
    return result, nil
}
