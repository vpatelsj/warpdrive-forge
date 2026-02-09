# WarpDrive Forge Demo — Explained

This document walks through **every detail** of what the WarpDrive showcase demo does, step by step, in plain English.

---

## What is WarpDrive?

WarpDrive is a **data fabric**. It takes files stored in cloud object storage (like Azure Blob Storage, S3, GCS) and makes them appear as ordinary files on your local filesystem. Under the hood it uses **FUSE** — a Linux mechanism that lets a user-space program pretend to be a filesystem. When your code opens `/wd/datasets-cac/train/shard-000042.tar`, WarpDrive intercepts that call, fetches the data from Azure, and hands it back as if the file were sitting on a local disk.

The killer feature is **transparent NVMe caching**. The first time a block of data is read from the cloud, WarpDrive saves a copy on the VM's local NVMe SSD. The second time that same block is read, it comes straight from the NVMe — no network round-trip, no cloud API call. This is completely invisible to the application.

## What is warpdrive-forge?

warpdrive-forge is a **purpose-built training workload** written in Go. Its sole job is to exercise WarpDrive by reading thousands of images as fast as possible, so we can measure exactly how much the caching helps. It reads WebDataset tar archives (a common format in ML), extracts image-label pairs, and runs them through a tiny neural network. The neural network is deliberately simple — we want data loading (I/O) to be the bottleneck, not compute.

## The Setup

Before the demo runs, several infrastructure scripts prepare the environment:

### The Azure VM

The demo runs on an **Azure L8s_v3** virtual machine. This is a "storage-optimized" VM with:
- 8 CPU cores, 64 GB RAM
- **1.8 TB NVMe SSD** — this is the critical piece. NVMe SSDs deliver millions of IOPS and multi-GB/s bandwidth, making them ideal as a local cache tier.

The NVMe disk is formatted as ext4 and mounted at `/mnt/nvme`. WarpDrive's cache directory lives at `/mnt/nvme/warpdrive-cache`.

### The Dataset

The dataset is **COCO train2017** — 118,287 real photographs from the Common Objects in Context project. These are real JPEG images, not synthetic noise, totaling about 19 GB.

The images are packed into 200 **WebDataset tar shards**, each containing roughly 592 images and weighing about 95 MB. WebDataset is a standard format where each sample is a set of files inside a tar archive (e.g., `000001.jpg` and `000001.cls` for image and label).

### Multi-Region Storage

The 200 shards are split across **two Azure regions**:
- Shards 0, 2, 4, 6, … (the even-numbered 100 shards) go to a storage account in **Canada Central**.
- Shards 1, 3, 5, 7, … (the odd-numbered 100 shards) go to a storage account in **West US 3**.

This is intentional. It simulates a real-world scenario where data is distributed across regions for redundancy, compliance, or locality. Without WarpDrive, the training code would need separate credentials and API calls for each region. With WarpDrive, both regions appear as subdirectories under `/wd/`.

### Authentication

The VM has a **Managed Identity** assigned by Azure (Entra ID). WarpDrive uses this to authenticate to both storage accounts. There are zero secrets, zero API keys, and zero credentials stored anywhere in the config files. The VM simply "is who it is" and Azure trusts it.

---

## The Demo Script (05-run.sh)

The demo has four phases. Here's exactly what happens in each.

---

### Phase 1 — Cross-Region Data Fabric

**What it does:** Mounts WarpDrive and shows what the unified filesystem looks like.

**Step by step:**

1. **Clean up.** If WarpDrive was running from a previous attempt, unmount it and kill the process. This ensures a clean start.

2. **Delete the cache.** The entire `/mnt/nvme/warpdrive-cache` directory is wiped. Every file in the cache is gone. This guarantees that Phase 2 starts with a completely empty cache — a true "cold" start.

3. **Start WarpDrive.** The `warpdrive-mount` binary is launched in the background with the config file at `/etc/warpdrive/config.yaml`. This config tells WarpDrive:
   - Mount at `/wd`
   - Connect to two Azure Blob backends (Canada Central and West US 3)
   - Use Managed Identity for auth
   - Cache blocks on the NVMe at `/mnt/nvme/warpdrive-cache`
   - Expose Prometheus metrics on port 9090

4. **Wait for mount.** The script polls every second for up to 30 seconds, checking if `/wd` is mounted and listable. If it isn't ready in time, the script prints the last 20 lines of the WarpDrive log and exits.

5. **Show the directory tree.** The script lists what's under `/wd/`:
   ```
   /wd/
    ├── datasets-cac/
    │   └── train/  (100 shards: shard-000000.tar, shard-000002.tar, shard-000004.tar …)
    ├── datasets-wus3/
    │   └── train/  (100 shards: shard-000001.tar, shard-000003.tar, shard-000005.tar …)
   ```

   This is the "aha" moment. Two storage accounts in two different Azure regions appear as two directories under a single mount point. The training code can read from both as if they were local folders.

6. **Highlight key points:**
   - Auth is via Managed Identity — no secrets.
   - The training code uses plain POSIX paths like `/wd/datasets-cac/train/shard-000000.tar`. Zero cloud SDK calls. Zero Azure-specific code.

---

### Phase 2 — Cold-Cache Training

**What it does:** Runs the full training workload with an empty cache. Every byte must come from the network.

**What "cold cache" means:** The cache was just deleted. WarpDrive has never seen any of this data before. When the training loop opens a shard file and reads a block, WarpDrive must:
1. Receive the FUSE read request from the kernel
2. Check the local cache — miss (nothing there)
3. Fetch the block from Azure Blob Storage over HTTPS
4. Write the block to the NVMe cache for next time
5. Return the block to the application

This is the slow path. Every read involves a network round-trip to Azure.

**Step by step:**

1. **Snapshot metrics (before).** The script captures the current values of all WarpDrive Prometheus counters — cache hits, cache misses, bytes fetched, FUSE read count. These are cumulative counters, so we need the "before" values to compute deltas.

2. **Record wall clock start time** in nanoseconds.

3. **Run training.** The `warpdrive-forge` binary is invoked with:
   - `-train-root-a /wd/datasets-cac/train` — the Canada Central shards
   - `-train-root-b /wd/datasets-wus3/train` — the West US 3 shards
   - `-steps 300` — train for 300 steps
   - `-batch-size 32` — each step reads 32 images
   - `-num-workers 8` — 8 goroutines load data in parallel
   - `-seed 42` — deterministic randomness (same shards, same order, both runs)
   - `-log-every 50` — print progress every 50 steps

   Inside the binary, this is what happens for each training step:
   
   a. **Data loading.** 8 worker goroutines are continuously reading from the shard files. Each worker picks a random shard (from both regions), opens the tar file, scans it for image+label pairs, and pushes them into a shared channel. The main loop pulls 32 samples from this channel to form a batch.
   
   b. **Feature extraction.** Each JPEG image's raw bytes are sampled at regular intervals to produce a 256-element feature vector. Critically, the JPEG is **not decoded** — we skip the expensive CPU work of decompressing pixels. This is deliberate: we want I/O to be the bottleneck, not compute.
   
   c. **Model forward + backward pass.** The 256-element vector is fed through a simple linear classifier (256 inputs → 10 classes). A softmax is computed, cross-entropy loss is calculated, and weights are updated via gradient descent. With only 10 classes and 256 features, this takes about 0.25 ms — almost nothing.
   
   d. **Logging.** Every 50 steps the binary prints: `step=150 images_per_sec=577.3 data_ms=55.18 compute_ms=0.25 loss=2.2941`. The key numbers are `images_per_sec` (throughput) and `data_ms` (how long each step waited for data).

4. **Record wall clock end time.**

5. **Snapshot metrics (after).** Capture all the same Prometheus counters again.

6. **Compute deltas.** Subtract "before" from "after" to get exactly how many cache hits, misses, bytes fetched, FUSE reads, etc. happened during this training run only.

7. **Display results.** A table showing:
   - **Wall time** — total elapsed time (e.g., 33,383 ms)
   - **Throughput** — images per second (e.g., 577.3)
   - **Avg data load** — milliseconds per step spent waiting for data (e.g., 55.18 ms)
   - **FUSE reads** — how many read() syscalls WarpDrive handled
   - **Cache hits / misses** — almost all misses during cold run (e.g., 97.5% hit rate because blocks within the same shard get reused, but there are still 340 misses for blocks fetched for the first time)
   - **Fetched (CAC)** — gigabytes pulled from the Canada Central storage account
   - **Fetched (WUS3)** — gigabytes pulled from the West US 3 storage account

---

### Phase 3 — Warm-Cache Training

**What it does:** Runs the **exact same** training workload again. Same shards, same order, same seed. But now WarpDrive has every block cached on the NVMe.

**What "warm cache" means:** During Phase 2, WarpDrive fetched every block from Azure and saved it to the NVMe. Now when the training loop reads the same data, WarpDrive:
1. Receives the FUSE read request
2. Checks the local cache — hit!
3. Reads the block from the NVMe SSD (microseconds, not milliseconds)
4. Returns it to the application

No network. No cloud API calls. Pure local NVMe speed.

**Step by step:**

The steps are identical to Phase 2:
1. Snapshot metrics (before)
2. Record start time
3. Run the same training command with identical parameters
4. Record end time
5. Snapshot metrics (after)
6. Compute deltas
7. Display results

The numbers tell the story:
- **Wall time** drops dramatically (e.g., 14,236 ms — down from 33,383 ms)
- **Throughput** jumps (e.g., 1,403.6 images/sec — up from 577.3)
- **Data load** is faster (e.g., 22.56 ms/step — down from 55.18 ms)
- **Cache hit rate** is 100% — zero misses
- **Backend data fetched** is 0.00 GB — nothing pulled from the network

---

### Phase 4 — Results Comparison

**What it does:** Prints a side-by-side comparison table so you can see the speedup at a glance.

**The table looks like:**

| Metric                   | Cold         | Warm          | Delta  |
|--------------------------|--------------|---------------|--------|
| Wall time                | 33,383 ms    | 14,236 ms     | 2.3x   |
| Throughput (images)      | 577.3/sec    | 1,403.6/sec   | 2.4x   |
| Avg data load / step     | 55.18 ms     | 22.56 ms      | 2.4x   |
| Cache hit rate           | 97.5%        | 100.0%        |        |
| Cache hits               | 26,163       | 26,503        |        |
| Cache misses             | 340          | 0             |        |
| Backend data fetched     | 1.58 GB      | 0.00 GB       |        |

The **2.4x throughput improvement** is the headline number. The training workload processed 2.4 times more images per second on the warm run versus cold, with zero code changes and zero application awareness of caching.

---

## The Prometheus Metrics Dashboard

After the comparison, the script queries WarpDrive's Prometheus endpoint (`http://localhost:9090/metrics`) and displays a comprehensive dashboard. Here's what each section means:

### FUSE Operations

These are the raw filesystem operation counts that the Linux kernel sent to WarpDrive:

| Operation | What it means |
|-----------|---------------|
| **read**    | An application called `read()` on a file under `/wd`. This is the hot path — thousands of these happen during training. |
| **lookup**  | The kernel asked "does this file exist?" — happens when `open()` or `stat()` is called on a path. |
| **readdir** | The kernel asked "what files are in this directory?" — happens when you `ls` or `os.ReadDir()`. |

Example: `read 26,060    lookup 825    readdir 8`

### FUSE Read Latency Histogram

This is a **bar chart** showing how long each FUSE read took, bucketed by latency:

```
≤100μs  │████████████████████████████  │ 24,851
≤500μs  │██                            │ 892
≤1ms    │                              │ 12
≤5ms    │                              │ 156
≤50ms   │                              │ 149
>50ms   │                              │ 0
```

Most reads complete in under 100 microseconds — that's the NVMe cache at work. The few reads that took 1-50ms were the cold-cache misses that had to go to Azure. The "Mean" line shows the average read latency across all reads.

### Cache

| Metric      | What it means |
|-------------|---------------|
| **hits**       | Number of times a requested block was found in the NVMe cache. |
| **misses**     | Number of times a block was NOT in cache and had to be fetched from Azure. |
| **evictions**  | Number of times an old cached block was deleted to make room for new data. 0 means the cache is large enough for the entire dataset. |
| **hit rate**   | `hits / (hits + misses)` as a percentage. Close to 100% means the cache is working perfectly. |
| **cache used** | Total bytes on disk in the cache directory, and what percentage of the NVMe's capacity that represents. For example, "2,372 MB (4.6%)" means the 19 GB dataset takes up only 4.6% of the 1.8 TB NVMe. |

### Readahead

WarpDrive tries to predict what blocks you'll need next and pre-fetches them before you ask.

| Metric         | What it means |
|----------------|---------------|
| **prefetch hits** | Number of times a readahead prediction was correct — the block was pre-fetched and was indeed requested. |
| **wasted**        | Number of times a block was pre-fetched but never used — a wrong prediction. |

### Backend I/O

| Metric         | What it means |
|----------------|---------------|
| **bytes fetched** | Total bytes downloaded from Azure Blob Storage across all backends. |
| **requests**      | Number of HTTP requests made to Azure. |
| **errors**        | Number of I/O errors (timeouts, connection resets, etc.). 0 means everything went smoothly. |

### Auth

| Metric                | What it means |
|-----------------------|---------------|
| **credential refreshes** | Number of times WarpDrive obtained or renewed a Managed Identity token from Azure's IMDS endpoint. This happens automatically and transparently. |

The script also notes that this Prometheus endpoint is **scrapable** by any monitoring tool — Grafana, Datadog, Prometheus server, etc. In production, you'd point your monitoring stack at `:9090/metrics` and get live dashboards.

---

## Data Governance (warpdrive-ctl)

After the training runs, the script **unmounts WarpDrive** (because the governance tool needs exclusive access to the cache database) and runs three `warpdrive-ctl` commands:

### `warpdrive-ctl stats`

Shows overall statistics about the cache — total entries, total bytes, hit/miss ratios from the embedded database.

### `warpdrive-ctl usage`

Shows a breakdown of cache usage **by path or backend**. This tells you which datasets or which teams' data is consuming cache space. Useful for multi-tenant environments where you need to track which project is using how much of the shared NVMe cache.

### `warpdrive-ctl stale`

Lists cached data that hasn't been accessed recently. This helps identify data that could be evicted to free up space for active workloads. In a production environment, you might run this on a schedule to automatically clean up old cached data.

### Other Available Commands

The script also lists governance commands that aren't run in the demo but exist for production use:

| Command   | What it does |
|-----------|--------------|
| `warm`    | **Pre-populate the cache** for a given path. Run this before a training job starts to ensure the first epoch is fast. Example: `warpdrive-ctl warm /wd/datasets-cac/train` |
| `quota`   | **Set per-team storage quotas.** In a shared cluster, limit how much of the NVMe cache each team can consume. |
| `move`    | **Move or copy data between backends.** Migrate data from one cloud region to another through WarpDrive's control plane. |
| `status`  | **Show mount + control-plane health.** Is WarpDrive running? Is the cache healthy? Are all backends reachable? |
| `serve`   | **Start the control-plane server.** Provides an API for programmatic governance. |

---

## The Capabilities Summary

At the end, the script prints a checklist of everything that was demonstrated:

| Capability | What was shown |
|------------|----------------|
| **Cross-Region Data Fabric** | Two Azure regions (Canada Central + West US 3) accessible under a single FUSE mount at `/wd`. |
| **Transparent NVMe Caching** | Cold run had hundreds of cache misses and fetched ~1.58 GB from blob. Warm run had 100% hit rate and zero backend I/O. |
| **Zero-Code Cloud Access** | Training reads plain POSIX paths. Zero Azure SDK calls. Switch cloud providers by changing WarpDrive config only. |
| **Managed-Identity Auth** | Credentials auto-resolved via Entra ID. No secrets stored anywhere. |
| **Prometheus Observability** | Real-time metrics at `:9090` — FUSE ops, cache stats, backend bytes, latency histograms, auth events. |
| **Data Governance** | `warpdrive-ctl` provides status, usage, quota, stale, warm — manage cached data across hybrid and multi-cloud storage. |

---

## Why the Numbers Matter

The **2.4x throughput improvement** from cold to warm cache is the core value proposition of WarpDrive. In real-world ML training:

- **Epoch 1** (cold) is slow because every byte comes from the cloud.
- **Epochs 2, 3, 4, …** (warm) are dramatically faster because everything is already cached on the local NVMe.
- Multi-epoch training is the norm — you iterate over the same dataset dozens or hundreds of times.

Without WarpDrive, you'd either:
1. Pre-download the entire dataset to the VM's local disk (slow, requires manual orchestration, wastes disk for datasets you're not actively using), or
2. Read from cloud storage every epoch (slow, expensive in bandwidth).

WarpDrive gives you the best of both worlds: cloud-native storage with local-disk performance, transparently and automatically.

---

## Actual Results from the Demo Run

| Metric | Cold Cache | Warm Cache | Improvement |
|--------|-----------|------------|-------------|
| Wall time | 33,383 ms | 14,236 ms | 2.3x faster |
| Throughput | 577.3 images/sec | 1,403.6 images/sec | 2.4x higher |
| Data load per step | 55.18 ms | 22.56 ms | 2.4x faster |
| Cache hit rate | 97.5% | 100.0% | — |
| Cache misses | 340 | 0 | — |
| Backend data fetched | 1.58 GB | 0.00 GB | — |
| FUSE reads (total) | — | 26,060 | — |
| Cache used | — | 2,372 MB (4.6% of 1.8 TB NVMe) | — |
