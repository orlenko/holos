"""Produce machine-readable summaries, not accuracy claims about private meetings."""
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent
summary = {"scope": "Invented examples only; not real-meeting accuracy or a model ranking",
           "hardware": {"chip": "Apple M5", "memory_bytes": 17179869184}, "runs": []}
for path in sorted(ROOT.glob("*.monitor.jsonl")):
    label = path.name.removesuffix(".monitor.jsonl")
    monitor = [json.loads(line) for line in path.read_text().splitlines()]
    output = ROOT / f"{label}.jsonl"
    rows = [json.loads(line) for line in output.read_text().splitlines()]
    decisions = [r for r in rows if r["event"] == "decision"]
    modes = {}
    for mode in ["short", "wide", "wide-ocr"]:
        selected = [r for r in decisions if r["mode"] == mode]
        if not selected:
            continue
        modes[mode] = {"completed": len(selected), "correct_toy_labels": sum(r["correct"] for r in selected),
                       "invalid": sum(r["choice"] == "invalid" for r in selected),
                       "false_replacements": sum(r["false_replacement"] for r in selected),
                       "keep_expected_cases": sum(r["expected"] == "keep" for r in selected),
                       "wall_median_seconds": statistics.median(r["seconds"] for r in selected),
                       "wall_min_seconds": min(r["seconds"] for r in selected),
                       "wall_max_seconds": max(r["seconds"] for r in selected),
                       "ttft_median_seconds": statistics.median(r["first_token_seconds"] for r in selected),
                       "prompt_tokens_range": [min(r["prompt_tokens"] for r in selected), max(r["prompt_tokens"] for r in selected)]}
    measured = [r for r in monitor if r["event"] == "memory"]
    before = next((r for r in monitor if r["event"] == "before"), None)
    config = next((r for r in monitor if r["event"] == "guard_config"), None)
    after_startup = [r for r in measured if r.get("seconds", 0) >= 60]
    loaded = next((r for r in rows if r["event"] == "loaded"), None)
    completion = next((r for r in reversed(monitor) if r["event"] == "after"), None)
    summary["runs"].append({"label": label, "loaded": loaded, "completion": completion,
                            "running_or_interrupted": completion is None, "modes": modes,
                            "guard_config": config,
                            "max_swap_growth_mb": max((r["swap_used_mb"] - before["swap_used_mb"] for r in measured), default=None),
                            "end_swap_growth_mb": completion["swap_used_mb"] - before["swap_used_mb"] if completion and before else None,
                            "kernel_pressure_dispatch_values": sorted({r["kernel_pressure_dispatch"] for r in measured if "kernel_pressure_dispatch" in r}),
                            "max_probe_seconds": max((r["probe_seconds"] for r in measured if "probe_seconds" in r), default=None),
                            "post_60s_max_swapout_mib_s": max((r["swapout_mib_s"] for r in after_startup if "swapout_mib_s" in r), default=None),
                            "post_60s_median_swapout_mib_s": statistics.median(r["swapout_mib_s"] for r in after_startup if "swapout_mib_s" in r) if any("swapout_mib_s" in r for r in after_startup) else None,
                            "min_free_percent": min((r["free_percent"] for r in measured), default=None),
                            "max_sampled_rss_bytes": max((r["child_rss_bytes"] for r in measured), default=None),
                            "peak_mlx_gb": max((r["mlx_peak_gb"] for r in decisions), default=None),
                            "peak_process_rss_bytes": max((r["peak_rss_bytes_macos"] for r in decisions), default=None)})
text = json.dumps(summary, indent=2)
(ROOT / "results.json").write_text(text + "\n")
print(text)
