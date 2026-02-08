package config

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// Config captures the runtime knobs for a training run.
type Config struct {
	TrainRootA string `yaml:"train_root_a"`
	TrainRootB string `yaml:"train_root_b"`
	Steps      int    `yaml:"steps"`
	BatchSize  int    `yaml:"batch_size"`
	NumWorkers int    `yaml:"num_workers"`
	Seed       int64  `yaml:"seed"`
	LogEvery   int    `yaml:"log_every"`
}

// Overrides captures CLI supplied values.
type Overrides struct {
	TrainRootA string
	TrainRootB string
	Steps      int
	BatchSize  int
	NumWorkers int
	Seed       int64
	LogEvery   int
}

// Load reads and validates a Config from YAML.
func Load(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open config: %w", err)
	}
	defer f.Close()

	cfg, err := parseYAML(f)
	if err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// ApplyOverrides updates cfg using any non-zero override.
func (c *Config) ApplyOverrides(o Overrides) {
	if o.TrainRootA != "" {
		c.TrainRootA = o.TrainRootA
	}
	if o.TrainRootB != "" {
		c.TrainRootB = o.TrainRootB
	}
	if o.Steps > 0 {
		c.Steps = o.Steps
	}
	if o.BatchSize > 0 {
		c.BatchSize = o.BatchSize
	}
	if o.NumWorkers > 0 {
		c.NumWorkers = o.NumWorkers
	}
	if o.Seed != 0 {
		c.Seed = o.Seed
	}
	if o.LogEvery > 0 {
		c.LogEvery = o.LogEvery
	}
}

// Validate verifies the config is runnable.
func (c *Config) Validate() error {
	if c == nil {
		return errors.New("config is nil")
	}
	if c.TrainRootA == "" && c.TrainRootB == "" {
		return errors.New("at least one training root must be set")
	}
	if c.TrainRootA == "" || c.TrainRootB == "" {
		return errors.New("both training roots must be provided for multi-region demo")
	}
	if c.Steps <= 0 {
		return fmt.Errorf("steps must be > 0 (got %d)", c.Steps)
	}
	if c.BatchSize <= 0 {
		return fmt.Errorf("batch_size must be > 0 (got %d)", c.BatchSize)
	}
	if c.NumWorkers <= 0 {
		return fmt.Errorf("num_workers must be > 0 (got %d)", c.NumWorkers)
	}
	if c.LogEvery <= 0 {
		c.LogEvery = 50
	}
	return nil
}

func parseYAML(r io.Reader) (*Config, error) {
	cfg := &Config{}
	scanner := bufio.NewScanner(r)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("line %d: missing ':'", lineNo)
		}
		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		value = strings.Trim(value, "\"'")
		switch key {
		case "train_root_a":
			cfg.TrainRootA = value
		case "train_root_b":
			cfg.TrainRootB = value
		case "steps":
			v, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("line %d: steps: %w", lineNo, err)
			}
			cfg.Steps = v
		case "batch_size":
			v, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("line %d: batch_size: %w", lineNo, err)
			}
			cfg.BatchSize = v
		case "num_workers":
			v, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("line %d: num_workers: %w", lineNo, err)
			}
			cfg.NumWorkers = v
		case "seed":
			v, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("line %d: seed: %w", lineNo, err)
			}
			cfg.Seed = v
		case "log_every":
			v, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("line %d: log_every: %w", lineNo, err)
			}
			cfg.LogEvery = v
		default:
			return nil, fmt.Errorf("line %d: unknown key %s", lineNo, key)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return cfg, nil
}
