package dataset

import (
	"context"
	"errors"
	"math/rand"
	"sort"
	"sync"
	"time"
)

// SamplerOptions configures the multi-root sampler.
type SamplerOptions struct {
	Roots      map[string][]string
	Seed       int64
	NumWorkers int
	PendingCap int
}

// StartSampler launches the multi-root sampler pipeline.
func StartSampler(parent context.Context, opts SamplerOptions) (<-chan Sample, <-chan error, error) {
	if len(opts.Roots) == 0 {
		return nil, nil, errors.New("sampler: no dataset roots provided")
	}
	total := 0
	for _, shards := range opts.Roots {
		total += len(shards)
	}
	if total == 0 {
		return nil, nil, errors.New("sampler: no shards discovered")
	}
	if opts.NumWorkers <= 0 {
		opts.NumWorkers = 1
	}
	if opts.PendingCap <= 0 {
		opts.PendingCap = defaultPendingCap
	}
	if opts.Seed == 0 {
		opts.Seed = 42
	}

	ctx, cancel := context.WithCancel(parent)

	jobs := make(chan shardJob, opts.NumWorkers)
	cursors := make(chan shardCursor, opts.NumWorkers)
	out := make(chan Sample, opts.NumWorkers*2)
	errCh := make(chan error, opts.NumWorkers)

	rng := rand.New(rand.NewSource(opts.Seed))

	go produceJobs(ctx, jobs, opts.Roots, rng)

	var wg sync.WaitGroup
	for i := 0; i < opts.NumWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			worker(ctx, jobs, cursors, opts.PendingCap)
		}()
	}

	go func() {
		wg.Wait()
		close(cursors)
	}()

	go func() {
		defer cancel()
		defer close(out)
		defer close(errCh)
		runAggregator(ctx, cursors, out, errCh)
	}()

	return out, errCh, nil
}

type shardJob struct {
	id   int64
	root string
	path string
}

type shardCursor struct {
	id      int64
	samples <-chan Sample
	errCh   <-chan error
}

func worker(ctx context.Context, jobs <-chan shardJob, cursors chan<- shardCursor, pendingCap int) {
	for {
		select {
		case <-ctx.Done():
			return
		case job, ok := <-jobs:
			if !ok {
				return
			}
			samples, errCh := StreamShard(ctx, job.path, pendingCap)
			cursor := shardCursor{id: job.id, samples: samples, errCh: errCh}
			select {
			case <-ctx.Done():
				return
			case cursors <- cursor:
			}
		}
	}
}

func runAggregator(ctx context.Context, cursors <-chan shardCursor, out chan<- Sample, errCh chan<- error) {
	pending := make(map[int64]shardCursor)
	var nextID int64
	for {
		cursor, ok := pending[nextID]
		if !ok {
			var received bool
			select {
			case <-ctx.Done():
				return
			case cursor, ok = <-cursors:
				if !ok {
					return
				}
				pending[cursor.id] = cursor
				received = true
			}
			if !received {
				continue
			}
			continue
		}

		for {
			select {
			case <-ctx.Done():
				return
			case sample, ok := <-cursor.samples:
				if !ok {
					goto shardDone
				}
				select {
				case <-ctx.Done():
					return
				case out <- sample:
				}
			}
		}

	shardDone:
		if err := <-cursor.errCh; err != nil && !errors.Is(err, context.Canceled) {
			errCh <- err
			return
		}
		delete(pending, nextID)
		nextID++
	}
}

func produceJobs(ctx context.Context, jobs chan<- shardJob, roots map[string][]string, rng *rand.Rand) {
	var jobID int64
	for {
		order := buildRoundRobinOrder(roots, rng)
		if len(order) == 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(500 * time.Millisecond):
			}
			continue
		}
		for _, entry := range order {
			select {
			case <-ctx.Done():
				return
			case jobs <- shardJob{id: jobID, root: entry.root, path: entry.path}:
				jobID++
			}
		}
	}
}

type orderEntry struct {
	root string
	path string
}

func buildRoundRobinOrder(roots map[string][]string, rng *rand.Rand) []orderEntry {
	rootNames := make([]string, 0, len(roots))
	copied := make(map[string][]string, len(roots))
	for root, shards := range roots {
		if len(shards) == 0 {
			continue
		}
		rootNames = append(rootNames, root)
		copied[root] = append([]string(nil), shards...)
		if rng != nil {
			rng.Shuffle(len(copied[root]), func(i, j int) {
				copied[root][i], copied[root][j] = copied[root][j], copied[root][i]
			})
		}
	}
	sort.Strings(rootNames)
	var order []orderEntry
	for {
		advanced := false
		for _, root := range rootNames {
			shards := copied[root]
			if len(shards) == 0 {
				continue
			}
			order = append(order, orderEntry{root: root, path: shards[0]})
			copied[root] = shards[1:]
			advanced = true
		}
		if !advanced {
			break
		}
	}
	return order
}
