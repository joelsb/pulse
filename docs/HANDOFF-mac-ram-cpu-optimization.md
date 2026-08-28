# HANDOFF: Mac RAM + CPU optimization

**Date:** 2026-08-28
**Machine:** Mac16,13 (Apple M4, 4 Performance + 6 Efficiency cores, 16 GB RAM, 460 GB volume)
**Priority order Joel gave:** RAM first, CPU second.
**Status:** omniroute removed. 5.2 GB disk reclaimed. Pulse's own CPU cost partly fixed, one thread still unexplained.

---

## 0. Read this first

This file exists because the work spans two things at once: **auditing Joel's machine** (what should not be running) and **fixing Pulse itself** (which turned out to be one of the worst offenders, at ~36% of a core with its panel open).

There is **one uncommitted change that must not ship as-is**: `Sources/Pulse/Core/Services/SystemMonitor.swift` currently contains `--trace-ticks` instrumentation added for profiling. It is gated behind a launch argument and writes to `/tmp/pulse-ticks.log`. Decide whether to keep it (it earned its place - see §4) or strip it before committing.

Working directory for all Pulse work: `~/MYNE/Projects/pulse`. Last commit: `bc8767a`.

---

## 1. What is DONE and verified

### 1.1 omniroute removed (RAM: -594 MB)

Joel's instruction was "keep it installed locally with its data, just not running and not using RAM". That is exactly what was done.

| What | State |
|---|---|
| Processes | 0 (was 2: pid 1079 parent + 1294 child, 594 MB combined) |
| Binary | **kept** - `/usr/local/bin/omniroute` -> `../lib/node_modules/omniroute/bin/omniroute.mjs` |
| Data | **kept** - `~/.omniroute`, 82 MB including `storage.sqlite` |
| Launch agent | moved to `~/Library/LaunchAgents/disabled/io.datainnovation.omniroute.plist` |
| jcode provider block | removed from `~/.jcode/config.toml` |

Commands used:
```bash
launchctl bootout gui/$(id -u)/io.datainnovation.omniroute
mkdir -p ~/Library/LaunchAgents/disabled
mv ~/Library/LaunchAgents/io.datainnovation.omniroute.plist ~/Library/LaunchAgents/disabled/
# then removed the [providers.omniroute] block + its 3 [[providers.omniroute.models]] entries
```

**Verification actually performed** (not assumed):
- 0 established connections on ports 20128/20131/20132 before removal, so nothing was using it.
- `default_provider = "claude"`, so the jcode provider block was defined-but-unrouted.
- Config re-parsed with a **real TOML parser** (`tomli`) afterwards: valid, `provider.default_provider = claude` intact, zero `omniroute` strings anywhere in the parsed structure.
- Survived 3+ seconds after bootout without restarting, which proves the `KeepAlive: true` agent is genuinely unloaded.

**Backups:** `~/.jcode/backups-omniroute/omniroute-agent.plist.bak-20260828-132025` (moved out of `/tmp` so a reboot cannot lose it) and `~/.jcode/config.toml.bak-omniroute-20260828-132025`. The build-audit script from §1.2 is saved beside the plist as `~/.jcode/backups-omniroute/jcode-build-audit.py`.

**To restore:**
```bash
mv ~/Library/LaunchAgents/disabled/io.datainnovation.omniroute.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.datainnovation.omniroute.plist
```
To run it manually without autostart: `omniroute serve`.

### 1.2 Disk reclaimed: 5.2 GB total

Joel's volume was at **99% full with 4.4 GB free** and falling. That is more dangerous than any RAM figure: at that level a `cargo build` fails in ways that look like compiler bugs.

| Action | Reclaimed |
|---|---|
| 17 stale `~/.jcode/builds/versions/*` dev builds | 4.5 GB |
| 6967 `~/.jcode/scratch` entries older than 7 days | ~560 MB |
| `~/.jcode/skills-archived-gstack-20260814-220219` | 179 MB |

Now at **11 GB free (98%)**.

The build cleanup used `/tmp/jcode-build-audit.py`, which **protects** anything that is: named by `current-version` / `stable-version` / `shared-server-version`, the manifest canary, one of the 3 most recent builds (rollback window), or **held open by a running process** (checked with `lsof` - a deleted-but-open binary frees nothing until that process exits). 26 versions -> 9 kept. `jcode --version` still works.

**That script is worth keeping.** Copy it into the repo if this needs doing again; `~/.jcode/builds` will regrow at ~320 MB per dev build.

---

## 2. Machine audit: the RAM table

Measured with `phys_footprint` (Activity Monitor's "Memory" column), grouped so an app's helpers count toward the app. Total footprint across 594 processes was **18.87 GB** on 16 GB of RAM, which is why swap sits at 2.8 GB.

| Group | Memory | CPU | Procs | Verdict |
|---|---|---|---|---|
| Safari/WebKit content | 4.50 GB | 8.5% | 11 | **biggest single win available.** Tab hygiene, not a code fix. |
| Spotify | 1.25 GB | 4.2% | 8 | 8 processes for a music player. Quit when not listening. |
| jcode | 1.23 GB | 3.4% | 30 | 30 processes. Worth asking whether all are live sessions. |
| wezterm-gui | 1.12 GB | 2.9% | 1 | scrollback. Reducing it is a config change. |
| Google Chrome | 922 MB | 5.9% | 13 | second browser running alongside Safari. |
| Safari (main) | 774 MB | 5.9% | 1 | |
| ~~omniroute~~ | ~~594 MB~~ | | | **DONE - removed** |
| mysqld | 571 MB | 0.0% | 1 | **KEEP.** 6 established PHP connections, genuinely in use. |
| Lightshot Screenshot | 477 MB | 0.0% | 1 | **best remaining candidate.** 477 MB for a screenshot tool that is idle. macOS Shift-Cmd-4 does most of it. |
| Obsidian helpers | 579 MB | 0.0% | 3 | |
| **Pulse** | 249 MB | see §4 | 1 | our own app |

### Login items still loaded

```
com.jcode.hotkey                              pid 19478
com.kunchenguid.no-mistakes.daemon.eba4be4a   pid 1067
com.samsung.portablessdplus.mon               pid 1089   <- 6 MB, no Samsung drive attached. Not worth removing.
herdr.collie                                  pid 73415
homebrew.mxcl.mysql                           pid 97188  <- in use, keep
com.openai.atlas.update-helper                (not running)
com.stremio.service                           (not running)
io.datainnovation.mcp-reaper                  (not running)
```

### Disk hogs not yet touched (judgment calls, not cleanups)

- `~/.cache/whisper` **4.4 GB** - `large-v3.pt` (2.9 GB) + `medium.pt` (1.4 GB) + `base.pt` (139 MB). FluidVoice is the consumer. **Ask Joel which model FluidVoice actually uses**; the other two are pure waste, and dropping `large-v3` alone frees 2.9 GB.
- `~/.jcode/sessions` 1.6 GB, `~/.jcode/logs` 835 MB (nothing older than 14 days, so it is all recent), `~/.cache/codex-runtimes` 1.5 GB, `~/.cache/opencode` 956 MB, `~/.cache/huggingface` 852 MB.
- `~/MYNE` is **214 GB**. Not investigated. This is where the real disk pressure lives.

---

## 3. TODO, in priority order (RAM first, as instructed)

### RAM
1. **Lightshot Screenshot: 477 MB idle.** Decide whether to keep it. Highest RAM-per-value ratio left after omniroute.
2. **Ask Joel about the two browsers.** Safari 5.27 GB + Chrome 922 GB = 6.2 GB, ~39% of his RAM. Not something to change without asking; it is how he works.
3. **jcode's 30 processes / 1.23 GB.** Determine how many are live sessions vs strays. There is an `io.datainnovation.mcp-reaper` agent that is not running - possibly meant for exactly this.
4. **Spotify's 8 processes / 1.25 GB.** Quitting when unused is a habit change, not a fix.

### CPU
5. **Finish Pulse's panel-open cost.** See §4. Was 37%, disk fix took the per-tick work from 28 ms to 1-5 ms, but the process still measured 36.6% afterwards - so **something else is also burning CPU and has not been found yet**. This is the one genuinely unfinished investigation.
6. **Decide the fate of the `--trace-ticks` instrumentation** before committing.
7. **WindowServer at 33-46%** was the top CPU consumer all session. Usually means a lot of window/animation work. Possibly related to the pinned Pulse panel being open during measurement - re-measure with the panel closed before chasing it.

### Disk
8. **Whisper models: 4.4 GB.** One question to Joel unlocks up to 4.2 GB.
9. `~/MYNE` at 214 GB needs its own pass.

---

## 4. Pulse's own CPU cost: what was found, what is still open

This started because Joel said "even Pulse is spending too much". He was right, and the sidebar built earlier this session was the cause.

### Measurements (all on this machine, panel pinned open)

| State | CPU |
|---|---|
| Panel **closed** | **0.0%** - ref-counted polling works, nothing runs |
| Panel open, sidebar **off** | 0.2% steady state |
| Panel open, sidebar **on** (before fixes) | **37.3%** of one core |
| Panel open, sidebar on (after disk fix) | still 36.6% - **unexplained** |

### Fix 1: the `ps` spawn (committed, 100x)

The process table was read by spawning `/bin/ps`. Measured **82-100 ms per tick**. Replaced with `sysctl(KERN_PROC_ALL)` + `proc_pid_rusage` per pid: **0.45-0.8 ms**, about 100x cheaper. Verified by a benchmark assertion in the verifier so it cannot regress.

### Fix 2: the disk call (uncommitted, 28 ms -> 0 ms)

**This is the important finding.** `volumeAvailableCapacityForImportantUsage` - needed because it is the figure Finder shows - routes through `CacheDelete`, which computes reclaimable space across the whole volume and emits `os_log` traffic while doing it. In-app per-phase timing:

```
before: sample=28.32ms | cpu=0.0 mem=0.0 load=0.0 swap=0.0 disk=25.7 proctable=2.2 rank=0.1
after:  sample=1.22ms  | cpu=0.0 mem=0.0 load=0.0 swap=0.0 disk=0.0  proctable=1.1 rank=0.0
```

Fixed by caching the disk reading for 60 seconds. Free space moves in gigabytes over hours, so nothing perceptible is lost.

### Fix 3: tick interval 2 s -> 3 s, and skip no-op publishes (uncommitted)

`apply()` now returns early when the new sample equals the old one, since publishing an identical value still invalidates every observed view.

### STILL OPEN: the missing ~35%

After fix 2 the per-tick work is 1-5 ms every 3 seconds, which is well under 1% of a core. **The process still measured 36.6%.** So the tick is not the whole cost and the remaining consumer has not been identified.

What was already ruled out:
- **Not the process cards.** Turning them off changed 37.3% -> 35.6%.
- **Not the sampler.** In-app timing accounts for only 1-5 ms per 3 s.
- **Not SwiftUI layout**, despite `sample` pointing there. The layout symbols were 38 samples out of 2529, i.e. noise. `geometryGroup()` isolation was added anyway and changed nothing measurable.
- **Not `apply()`.** 0.03-0.19 ms.

Next diagnostic step, not yet run: measure sidebar-off vs sidebar-on **on the same build** with the disk fix in place, both at steady state after 40+ seconds. The last attempt at this was interrupted. If sidebar-off is ~0.2% and sidebar-on is ~36% while ticks cost 5 ms, then the cost is in **view invalidation frequency rather than tick work** - suspect the two `Sparkline`s, whose `values` array changes identity every tick, and `TimelineView(.periodic(by: 1))` in `PanelFooter` re-evaluating a tree that now contains ~10 more views.

---

## 5. Domain notes worth keeping (things that cost real time this session)

1. **`ri_user_time` is in MACH TICKS on Apple Silicon, not nanoseconds.** `mach_timebase_info` gives numer=125 denom=3, so 1 unit = 41.667 ns. Reading it as ns under-reports every process by 41.67x - `herdr` showed 0.5% against `ps`'s 20.4%. A plausible "quiet machine" reading that is completely wrong.

2. **`host_processor_info` lists EFFICIENCY cores first, the reverse of the perflevel numbering.** `hw.perflevel0` is "Performance" (4 cores), `hw.perflevel1` is "Efficiency" (6), but array indices 0-5 are the E-cores and 6-9 are the P-cores. Verified both ways by pinning spin loops at `.background` (landed 0-3) and `.userInteractive` (landed 6-9) QoS.

3. **`ps` RSS and `phys_footprint` are different measurements, and the ratio varies per process** (0.89x to 11.6x measured here: Safari 68 MB RSS vs 800 MB footprint). So ranking on RSS is not "the same list scaled down", it is the **wrong order** with the multi-gigabyte processes missing entirely. Activity Monitor shows footprint.

4. **Benchmark the phase where it runs, not in isolation.** A standalone loop measured the disk call at 0.7 ms and completely missed the real cost, because the second iteration hits a warm cache. Only in-app per-phase timing revealed 15-26 ms. This is why the instrumentation earned its place.

5. **`sample` (the profiler) pointed at the wrong thing.** It blamed SwiftUI layout; the real cost was a blocking framework call whose time is spent in another process. Threads showing `__workq_kernreturn` are parked, not busy. When `sample` and `ps`/`top` disagree, trust cumulative CPU time (`ps -o time`) - it cannot lie about what was consumed.

6. **`df /` reports 51% while the data volume is at 98%.** On APFS, `/` is a read-only system snapshot. Any disk figure must come from the data volume (`volumeAvailableCapacityForImportantUsage` on a path in `$HOME`, which is what Finder shows). Reading `/` gives a clean, plausible, wrong answer.

7. **macOS has no "purgeable space" API.** It is `...ForImportantUsage` minus `...AvailableCapacity` = 751 MB here.

8. **A tolerance larger than the value it checks tests nothing.** A 1 GB tolerance on a 0.75 GB figure let two planted defects through while looking rigorous.

9. **`--pin-panel` disables every dismissal path** (ESC, click-outside, focus loss, status-item toggle). Launching Pulse with it looks exactly like the app hanging. This confused Joel twice; it is documented in `PanelController.swift` now.

---

## 6. State of the Pulse repo

Committed this session:
- `1f095d9` machine-stats sidebar
- `3b0122c` memory sparkline + reclaimable-cache figure
- `c1c71a9` P/E core split
- `bc8767a` phys_footprint for process memory, dropped the secondary metric column

**Uncommitted in `SystemMonitor.swift`:** the `ps` -> sysctl replacement, the disk cache, the 3 s interval, the no-op publish guard, and the `--trace-ticks` instrumentation. The verifier (`scripts/verify-system-stats.sh`) is at **20 planted defects, all caught**, and includes a benchmark assertion that fails if a subprocess spawn returns to the tick path.

Verifier command: `bash scripts/verify-system-stats.sh` (~2 min; `swift test` cannot run on this machine - no Xcode, so the `Testing` module is unavailable and every test file fails to compile).

Other repo files touched: `Sources/Pulse/UI/System/SystemColumn.swift`, `Sources/Pulse/Core/Services/Formatters.swift`, `Sources/Pulse/UI/Charts/Sparkline.swift`, `scripts/system-stats-harness.swift`.
