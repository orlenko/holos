"""Bound a single owned synthetic benchmark process; never signal the app."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent

def status(pid=None):
    probe_start = time.monotonic()
    pressure = subprocess.check_output(["memory_pressure", "-Q"], text=True, timeout=10)
    percent = int(re.search(r"free percentage: (\d+)%", pressure)[1])
    swap = subprocess.check_output(["sysctl", "vm.swapusage"], text=True, timeout=10)
    used_mb = float(re.search(r"used = ([\d.]+)M", swap)[1])
    pressure_level = int(subprocess.check_output(
        ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], text=True, timeout=10))
    # sysctl exports dispatch flags (not the kernel's internal 0..4 enum):
    # normal=1, warning=2, critical=4. Verified against Apple XNU conversion
    # and the installed SDK dispatch/source.h; read-only, no sysctl writes.
    stats = subprocess.check_output(["vm_stat"], text=True, timeout=10)
    page_bytes = int(re.search(r"page size of (\d+) bytes", stats)[1])
    swapin_bytes = int(re.search(r"Swapins:\s+(\d+)", stats)[1]) * page_bytes
    swapout_bytes = int(re.search(r"Swapouts:\s+(\d+)", stats)[1]) * page_bytes
    rss = 0
    cpu_percent = None
    if pid:
        result = subprocess.run(["ps", "-o", "rss=,%cpu=", "-p", str(pid)], text=True, capture_output=True, timeout=10)
        if result.stdout.strip():
            resident, percent_cpu = result.stdout.split()
            rss = int(resident) * 1024
            cpu_percent = float(percent_cpu)
    return {"free_percent": percent, "swap_used_mb": used_mb, "child_rss_bytes": rss,
            "child_cpu_percent": cpu_percent, "kernel_pressure_dispatch": pressure_level,
            "swapin_bytes_cumulative": swapin_bytes, "swapout_bytes_cumulative": swapout_bytes,
            "probe_seconds": time.monotonic() - probe_start}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--model-path", required=True)
parser.add_argument("--case-limit", type=int, default=12)
parser.add_argument("--label", required=True)
parser.add_argument("--suite", choices=["toy", "homophones"], default="toy")
parser.add_argument("--timeout", type=int, default=600)
parser.add_argument("--swap-growth-limit-mb", type=float, default=512)
parser.add_argument("--rss-limit-gib", type=float, default=8)
parser.add_argument("--min-free-percent", type=int, default=15)
parser.add_argument("--sample-seconds", type=float, default=5)
parser.add_argument("--warning-seconds", type=float, default=20)
parser.add_argument("--swap-rate-limit-mib-s", type=float, default=128)
parser.add_argument("--swap-rate-seconds", type=float, default=15)
parser.add_argument("--startup-grace-seconds", type=float, default=60)
args = parser.parse_args()
if min(args.swap_growth_limit_mb, args.rss_limit_gib, args.sample_seconds,
       args.warning_seconds, args.swap_rate_limit_mib_s, args.swap_rate_seconds, args.timeout) <= 0:
    raise ValueError("All resource limits and time bounds must be positive")
if not re.fullmatch(r"[a-zA-Z0-9_-]+", args.label):
    raise ValueError("Unsafe output label")
before = status()
if before["free_percent"] < 25:
    raise RuntimeError("Insufficient memory headroom to start a benchmark")
if before["kernel_pressure_dispatch"] != 1:
    raise RuntimeError("Refusing to start while kernel pressure is non-normal")
print(json.dumps({"event": "before", **before}), flush=True)
command = ["/usr/sbin/taskpolicy", "-c", "utility", sys.executable, "-u", str(ROOT / "evaluate.py"),
           "--model-path", args.model_path, "--case-limit", str(args.case_limit), "--suite", args.suite]
with (ROOT / f"{args.label}.jsonl").open("x") as output, (ROOT / f"{args.label}.stderr").open("x") as errors, \
     (ROOT / f"{args.label}.monitor.jsonl").open("x") as monitor:
    child = subprocess.Popen(command, stdout=output, stderr=errors)
    print(json.dumps({"event": "child", "pid": child.pid, "label": args.label}), flush=True)
    started = time.monotonic()
    reason = None
    previous = {"seconds": 0, **before}
    warning_since = None
    swapping_since = None
    slow_probe_count = 0
    last_print = 0
    monitor.write(json.dumps({"event": "before", **before}) + "\n")
    monitor.write(json.dumps({"event": "guard_config", **vars(args)}) + "\n")
    monitor.flush()
    try:
        while child.poll() is None:
            try:
                child.wait(timeout=args.sample_seconds)
                break
            except subprocess.TimeoutExpired:
                pass
            sample = {"event": "memory", "seconds": time.monotonic() - started, **status(child.pid)}
            elapsed = sample["seconds"] - previous["seconds"]
            sample["swapin_mib_s"] = max(0, sample["swapin_bytes_cumulative"] - previous["swapin_bytes_cumulative"]) / 1024**2 / elapsed
            sample["swapout_mib_s"] = max(0, sample["swapout_bytes_cumulative"] - previous["swapout_bytes_cumulative"]) / 1024**2 / elapsed
            warning_since = (warning_since if warning_since is not None else sample["seconds"]) if sample["kernel_pressure_dispatch"] == 2 else None
            heavy_swapping = sample["swapin_mib_s"] + sample["swapout_mib_s"] > args.swap_rate_limit_mib_s
            swapping_since = (swapping_since if swapping_since is not None else sample["seconds"]) if heavy_swapping and sample["seconds"] > args.startup_grace_seconds else None
            slow_probe_count = slow_probe_count + 1 if sample["probe_seconds"] > 2 else 0
            monitor.write(json.dumps(sample) + "\n")
            monitor.flush()
            if sample["seconds"] - last_print >= 10 or sample["kernel_pressure_dispatch"] != previous["kernel_pressure_dispatch"]:
                print(json.dumps(sample), flush=True)
                last_print = sample["seconds"]
            if sample["kernel_pressure_dispatch"] not in (1, 2):
                reason = "critical or unknown kernel memory pressure"
            elif warning_since is not None and sample["seconds"] - warning_since >= args.warning_seconds:
                reason = "sustained kernel warning pressure"
            elif swapping_since is not None and sample["seconds"] - swapping_since >= args.swap_rate_seconds:
                reason = "sustained heavy swapping after startup grace"
            elif slow_probe_count >= 2:
                reason = "two slow system probes; possible responsiveness deterioration"
            elif sample["free_percent"] < args.min_free_percent:
                reason = "system memory free percentage below configured floor"
            elif sample["swap_used_mb"] - before["swap_used_mb"] > args.swap_growth_limit_mb:
                reason = "system swap growth exceeded configured limit (global, not necessarily benchmark-only)"
            elif sample["child_rss_bytes"] > args.rss_limit_gib * 1024**3:
                reason = "child RSS above configured limit"
            elif sample["seconds"] > args.timeout:
                reason = "hard benchmark deadline"
            if reason:
                child.terminate()  # Only the exact subprocess we own.
                break
            previous = sample
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        after = {"event": "after", "exit_code": child.returncode, "stop_reason": reason,
                 "seconds": time.monotonic() - started, **status()}
        monitor.write(json.dumps(after) + "\n")
        print(json.dumps(after), flush=True)
sys.exit(child.returncode if child.returncode and child.returncode > 0 else (1 if reason or child.returncode else 0))
