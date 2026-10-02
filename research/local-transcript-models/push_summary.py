"""Summarize the user-authorized expanded 9B test; retain earlier aborted attempts."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
results = json.loads((ROOT / "results.json").read_text())
runs = {r["label"]: r for r in results["runs"]}

def decisions(label):
    return [r for r in map(json.loads, (ROOT / f"{label}.jsonl").read_text().splitlines()) if r["event"] == "decision"]

four = decisions("4b-homophones")
nine = decisions("9b-push-homophones")
assert len(four) == len(nine) == 24
four_by_key = {(r["case"], r["mode"]): r for r in four}
for row in nine:
    other = four_by_key[row["case"], row["mode"]]
    assert row["prompt_sha256"] == other["prompt_sha256"]
    assert row["expected"] == other["expected"]
smoke = decisions("9b-push-startup")
assert len(smoke) == 6
assert all(r["choice"] in ("keep", "replace") for r in nine + smoke)
assert all(runs[label]["completion"]["exit_code"] == 0 for label in ["9b-push-startup", "9b-push-homophones"])

monitor = [json.loads(line) for line in (ROOT / "9b-push-homophones.monitor.jsonl").read_text().splitlines()]
before = next(r for r in monitor if r["event"] == "before")
after = next(r for r in monitor if r["event"] == "after")
assert before["swapout_bytes_cumulative"] == after["swapout_bytes_cumulative"]

outcome = {
    "date": "2026-10-02",
    "authorization": "User explicitly requested pushing the 9B test farther on the existing 16 GiB machine",
    "supersedes": "Initial 9B load-abort assessment in outcome.json; those aborted attempts remain recorded",
    "conclusion": "9B completed offline synthetic decisions on Koza within the expanded safety envelope; not proof of non-intrusiveness during normal developer work",
    "scope": "Same pinned public 4-bit weights, same isolated runtime, invented examples only; no extra models or private meetings",
    "comparability": "All 24 homophone prompt hashes and expected labels matched between 4B and 9B",
    "nine_b": {
        "completed_decisions": 30,
        "valid_json_decisions": 30,
        "smoke_correct": sum(r["correct"] for r in smoke),
        "smoke_total": len(smoke),
        "homophone_run": runs["9b-push-homophones"],
        "smoke_run": runs["9b-push-startup"],
        "physical_footprint_sample": "5.3G current / 5.8G peak as reported by sample; not a continuous footprint measurement",
        "full_homophone_run_new_swapout_bytes": 0,
        "homophone_misses": [{"case": r["case"], "mode": r["mode"], "choice": r["choice"], "expected": r["expected"]}
                             for r in nine if not r["correct"]]
    },
    "four_b_comparator": runs["4b-homophones"],
    "safety": {
        "extra_swap_allowance_mb": 4096,
        "rss_allowance_gib": 10,
        "sample_seconds": 2,
        "warning_pressure_stop_seconds": 120,
        "critical_pressure": "Immediate stop at next sample",
        "heavy_swapping_stop": "Combined swap-in/out over 128 MiB/s sustained for 15 seconds after 60-second startup grace",
        "responsiveness_proxy_stop": "Two system probe batches each taking over two seconds",
        "system_wired_limit_or_other_global_settings_changed": False,
        "these_are_experiment_stop_conditions_not_universal_usability_thresholds": True
    },
    "limitations": [
        "No fixed swap-GB threshold determines usability; pressure and active swapping matter",
        "System swap and page rates include unrelated processes",
        "Command probes are not a foreground UI, editor, VM or Docker responsiveness test",
        "Only about 650 context words and six generated JSON tokens; not full-meeting rewriting",
        "Tiny invented examples with explicit contextual clues and repeated padding; not an accuracy estimate or general model ranking",
        "The 9B quantized conversion and non-thinking greedy prompt combination is what was tested",
        "Two identical short requests per homophone pair are not independent samples",
        "GPU duty cycle and long-duration thermal/battery performance were not measured",
        "Earlier initial 2.6 GB swap increase and safety aborts must not be erased from the assessment"
    ],
    "running_app_or_repository_modified": False,
    "recommendation": "Memory feasibility is established for this bounded 9B workload. Keep 4B as the leading candidate until a human-scored private-corpus test establishes a larger-model quality benefit."
}
(ROOT / "push-outcome.json").write_text(json.dumps(outcome, indent=2) + "\n")
print(json.dumps({"verification": "Matched 24 prompts; 30 valid 9B decisions; both expanded runs exited cleanly; full homophone run had no new swapouts",
                  "nine_b_homophone_modes": outcome["nine_b"]["homophone_run"]["modes"],
                  "nine_b_peak_mlx_gb": outcome["nine_b"]["homophone_run"]["peak_mlx_gb"]}, indent=2))
