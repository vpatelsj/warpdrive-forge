package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"warpdrive-forge/internal/config"
	"warpdrive-forge/internal/dataset"
	"warpdrive-forge/internal/trainer"
)

func main() {
	cfgPath := flag.String("config", "configs/demo.yaml", "Path to YAML config")
	trainRootA := flag.String("train-root-a", "", "Override training root A")
	trainRootB := flag.String("train-root-b", "", "Override training root B")
	steps := flag.Int("steps", 0, "Number of training steps")
	batchSize := flag.Int("batch-size", 0, "Batch size")
	numWorkers := flag.Int("num-workers", 0, "Number of data loader workers")
	seed := flag.Int64("seed", 0, "PRNG seed")
	logEvery := flag.Int("log-every", 0, "Log every N steps")

	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	cfg.ApplyOverrides(config.Overrides{
		TrainRootA: *trainRootA,
		TrainRootB: *trainRootB,
		Steps:      *steps,
		BatchSize:  *batchSize,
		NumWorkers: *numWorkers,
		Seed:       *seed,
		LogEvery:   *logEvery,
	})

	if err := cfg.Validate(); err != nil {
		log.Fatalf("invalid config: %v", err)
	}

	roots := map[string][]string{}
	for _, root := range []string{cfg.TrainRootA, cfg.TrainRootB} {
		shards, err := dataset.DiscoverShards(root)
		if err != nil {
			log.Fatalf("discover shards under %s: %v", root, err)
		}
		if len(shards) == 0 {
			log.Fatalf("no shards discovered under %s", root)
		}
		roots[root] = shards
		log.Printf("root=%s shards=%d", root, len(shards))
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	runCfg := trainer.RunConfig{
		Roots:      roots,
		Steps:      cfg.Steps,
		BatchSize:  cfg.BatchSize,
		NumWorkers: cfg.NumWorkers,
		LogEvery:   cfg.LogEvery,
		Seed:       cfg.Seed,
	}

	if err := trainer.Run(ctx, runCfg); err != nil {
		log.Fatalf("training failed: %v", err)
	}
}
