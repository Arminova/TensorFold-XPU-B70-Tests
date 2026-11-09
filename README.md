# TensorFold on the Intel Arc Pro B70: test runs

Test scripts for [TensorFold](https://github.com/ashhart/TensorFold)'s Intel XPU backend on Battlemage (Arc Pro B70).
Each run is one script you can read before you run it. It builds TensorFold from its public repository, runs checks
on one of your cards, and packs the results into a single file to send back.

## Run 1: TensorFold v1.2.5 as released

Everything run 1 builds and runs is TensorFold as published (ashhart/TensorFold) at the release tag `v1.2.5`. Every
check is one that release ships itself. The script only drives it and collects the results.

### What it runs

1. **Your machine, as text.** Kernel and distro, GPU kernel driver and versions of the compute runtime, Level Zero
   and `ocloc`, Zig, the card's name and PCI id and memory, CPU and RAM. Your user name, host name, IP and MAC
   addresses, and your home directory path, are replaced with `USER`, `HOST`, `IP`, `MAC` and `~` before anything is
   written to the result file.
2. **The build**, as the project's B70 recipe describes it: `zig build xpu-qwen27 xpu-qwen27-tests` and the
   kernel-contract runner, all for `-Dxpu-device=bmg`.
3. **The project's own checks on one card** (`--device N`, default 0):
   - `tf-xpu-contract-run`: the XPU kernel contract, gates 1-4 over the registered kernels, the five planted controls,
     and gate 5 live (the card's properties and every kernel against the release's recorded limits). It prints one
     `SUMMARY` line; that line is what matters.
   - `tf-xpu-qwen27-means-test`: the 4-bit GEMMs' group means against FP64, no checkpoint needed.
4. **Only if you pass a checkpoint you already have** (`--model DIR`, a Qwen3.8-27B in GPTQ int4 group-128 as the
   recipe's section 2 describes): `tf-xpu-qwen27-seam-test` (a prompt cut at 64, at 1024 and fed whole must give the
   same logits, bit for bit), `tf-xpu-qwen27-close-test` (three opens give the card back), and a speed table: prompt
   tok/s and decode tok/s at 2K, 4K, 8K, 16K, 32K, 64K, 128K tokens (one cold run each, a first look rather than a
   benchmark), with a size that does not fit recorded as such. Nothing is downloaded.
5. **Card numbers, only from tools already on your machine**: `clpeak` and `ze_peak` if they are installed, skipped
   otherwise. Nothing is installed.
6. **The GPU lines of your kernel log** during the run (`journalctl -k`, or `dmesg` if that is readable), scrubbed
   the same way. Skipped when not readable.

Every step has its own timeout and its own log file. A step that fails is recorded and the rest still run, so a
failure in one place never costs you the whole run.

### What it never does

- No `sudo`, no package install, no download of models or data.
- It writes only inside one folder: `./tf-b70-run1` by default, or the directory you pass with `--work`.
- It never flashes firmware, changes driver settings, power limits or clocks, and never touches another user's files.
- It uploads nothing. The only output is one `.tar.gz` you send back yourself.

### How long it takes

About 25 minutes without a checkpoint (the build is most of it; a first build compiles six OpenCL images and ten
generated GEMMs). About 45-60 minutes with the speed table. The script prints its estimate at the start. Each speed
size stops after 20 minutes at most, so a size that runs badly cannot hold the machine for hours.

### What to do

The tools it needs are the ones in the project's B70 recipe, section 1 ("What you need"): Zig 0.17, `ocloc`
(package `intel-ocloc`), a C++17 compiler, and oneDNN's nGEN headers. If the headers are not somewhere the script
looks, pass the directory that holds `ngen.hpp`.

```sh
git clone https://github.com/Arminova/TensorFold-XPU-B70-Tests.git
cd TensorFold-XPU-B70-Tests

./run1.sh --dry-run                     # print the plan, run nothing
./run1.sh --ngen /path/to/ngen          # the run, no checkpoint
./run1.sh --ngen /path/to/ngen --model /models/Qwen3.8-27B-GPTQ-g128    # with the speed table

# on a machine with two cards, pick the one to use:
./run1.sh --ngen /path/to/ngen --device 1
```

If a tool is missing the script stops before building and prints what each one is. `--dry-run` never creates or
builds anything.

### What to send back

One file: `run1-results.tar.gz`, written where you started the script (and the `sha256` it prints). Attach it to an
issue in this repository, or send it however is easiest. It holds:

- `summary.txt`: pass or fail and the seconds for every step, plus the contract's `SUMMARY` line and the speed table;
- `logs/`: one log per step, the environment report, and the GPU lines of the kernel log.

### How to stop it

Press Ctrl-C. It removes nothing, so the folder `./tf-b70-run1` stays for a look at what ran; delete it whenever you
like. Nothing outside that folder was touched.

### If something fails

The log of the failed step says why: `logs/build.log` for the build, `logs/contract.log` for the kernel contract,
`logs/bench-<size>.log` for one prompt size. A failed contract gate is interesting rather than fatal: that is what
the run is for. Send the whole archive either way.

## Licence

Apache-2.0 (`LICENSE`). TensorFold is Apache-2.0 too (`LICENSE` and `NOTICE` in the repository the script clones);
these scripts only drive it.
