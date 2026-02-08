package dataset

import (
	"archive/tar"
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Sample represents a paired record from a WebDataset shard.
type Sample struct {
	Key   string
	Image []byte
	Label int
}

// ErrPendingOverflow indicates the pairing map exceeded the configured bound.
var ErrPendingOverflow = errors.New("webdataset: pending pair buffer exceeded")

const defaultPendingCap = 1024

// StreamShard streams paired samples from the shard at path.
func StreamShard(ctx context.Context, path string, pendingCap int) (<-chan Sample, <-chan error) {
	if pendingCap <= 0 {
		pendingCap = defaultPendingCap
	}
	out := make(chan Sample)
	errCh := make(chan error, 1)

	go func() {
		defer close(out)
		defer close(errCh)

		f, err := os.Open(path)
		if err != nil {
			errCh <- fmt.Errorf("open shard: %w", err)
			return
		}
		defer f.Close()

		tr := tar.NewReader(bufio.NewReader(f))
		pending := make(map[string]*partial)

		for {
			if ctx != nil {
				select {
				case <-ctx.Done():
					errCh <- ctx.Err()
					return
				default:
				}
			}

			hdr, err := tr.Next()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				errCh <- fmt.Errorf("read tar: %w", err)
				return
			}
			if hdr.FileInfo().IsDir() {
				continue
			}
			name := filepath.Base(hdr.Name)
			ext := strings.ToLower(filepath.Ext(name))
			key := strings.TrimSuffix(name, ext)

			switch ext {
			case ".jpg", ".jpeg", ".png":
				data, err := io.ReadAll(tr)
				if err != nil {
					errCh <- fmt.Errorf("read image %s: %w", name, err)
					return
				}
				part := pending[key]
				if part == nil {
					part = &partial{}
					pending[key] = part
				}
				part.image = data
			case ".cls":
				payload, err := io.ReadAll(tr)
				if err != nil {
					errCh <- fmt.Errorf("read label %s: %w", name, err)
					return
				}
				trimmed := strings.TrimSpace(string(payload))
				label, err := strconv.Atoi(trimmed)
				if err != nil {
					errCh <- fmt.Errorf("parse label %s: %w", name, err)
					return
				}
				part := pending[key]
				if part == nil {
					part = &partial{}
					pending[key] = part
				}
				part.label = &label
			default:
				// ignore unknown extension
				continue
			}

			if len(pending) > pendingCap {
				errCh <- ErrPendingOverflow
				return
			}

			if part := pending[key]; part != nil && part.ready() {
				sample := Sample{Key: key, Image: part.image, Label: *part.label}
				delete(pending, key)

				if ctx != nil {
					select {
					case <-ctx.Done():
						errCh <- ctx.Err()
						return
					case out <- sample:
					}
				} else {
					out <- sample
				}
			}
		}

		if len(pending) > 0 {
			errCh <- fmt.Errorf("%d samples incomplete", len(pending))
		}
	}()

	return out, errCh
}

type partial struct {
	image []byte
	label *int
}

func (p *partial) ready() bool {
	return len(p.image) > 0 && p.label != nil
}

func contextCanceledErr() error {
	return errors.New("context canceled")
}
