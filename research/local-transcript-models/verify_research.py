"""Read-only verification of archived synthetic evidence; weights are strictly opt-in."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics

from evaluate import SYSTEM, examples, expected_choice, parse, self_test

ROOT = Path(__file__).resolve().parent


def read(name):
    return json.loads((ROOT / name).read_text())


def rows(name):
    return [json.loads(line) for line in (ROOT / name).read_text().splitlines()]


def verify_evidence():
    self_test()
    manifest = read("models.json")
    approved = [m for m in manifest["models"] if m.get("approved")]
    assert len(approved) == 2
    assert sum(m["weight_bytes"] for m in approved) == 8984521767
    report = {r["label"]: r for r in read("results.json")["runs"]}
    completed = {}
    for label, suite, limit in [("4b-toy-retry", "toy", 2), ("9b-push-startup", "toy", 2),
                                ("4b-homophones", "homophones", 8), ("9b-push-homophones", "homophones", 8)]:
        output = rows(label + ".jsonl")
        loaded = next(r for r in output if r["event"] == "loaded")
        assert loaded["system_prompt_sha256"] == hashlib.sha256(SYSTEM.encode()).hexdigest()
        decisions = [r for r in output if r["event"] == "decision"]
        assert len(decisions) == limit * 3
        cases = {c["id"]: c for c in list(examples(suite))[:limit]}
        assert {(r["case"], r["mode"]) for r in decisions} == {
            (case, mode) for case in cases for mode in ["short", "wide", "wide-ocr"]}
        for decision in decisions:
            assert decision["choice"] in ("keep", "replace")
            assert parse(decision["response"]) == decision["choice"]
            assert decision["expected"] == expected_choice(cases[decision["case"]], decision["mode"])
            assert decision["correct"] == (decision["choice"] == decision["expected"])
            assert decision["false_replacement"] == (decision["choice"] == "replace" and decision["expected"] == "keep")
        monitoring = rows(label + ".monitor.jsonl")
        finish = next(r for r in monitoring if r["event"] == "after")
        assert finish["exit_code"] == 0 and finish["stop_reason"] is None
        assert report[label]["completion"] == finish
        for mode in ["short", "wide", "wide-ocr"]:
            selected = [r for r in decisions if r["mode"] == mode]
            metric = report[label]["modes"][mode]
            assert metric["completed"] == len(selected)
            assert metric["correct_toy_labels"] == sum(r["correct"] for r in selected)
            # Artifact arithmetic consistency, not a wall-clock performance assertion.
            assert metric["wall_median_seconds"] == statistics.median(r["seconds"] for r in selected)
        completed[label] = {(r["case"], r["mode"]): r for r in decisions}
    for left, right in [("4b-toy-retry", "9b-push-startup"), ("4b-homophones", "9b-push-homophones")]:
        assert completed[left].keys() == completed[right].keys()
        for key in completed[left]:
            assert completed[left][key]["prompt_sha256"] == completed[right][key]["prompt_sha256"]
    for label in ["4b-toy-smoke", "9b-toy-smoke", "9b-push-smoke"]:
        assert not any(r["event"] == "decision" for r in rows(label + ".jsonl"))
        finish = next(r for r in rows(label + ".monitor.jsonl") if r["event"] == "after")
        assert finish["exit_code"] != 0 and finish["stop_reason"]
    monitoring = rows("9b-push-homophones.monitor.jsonl")
    begin = next(r for r in monitoring if r["event"] == "before")
    finish = next(r for r in monitoring if r["event"] == "after")
    assert begin["swapout_bytes_cumulative"] == finish["swapout_bytes_cumulative"]
    assert all(r["kernel_pressure_dispatch"] in (1, 2) for r in monitoring if r["event"] == "memory")
    current = read("push-outcome.json")
    assert current["nine_b"]["completed_decisions"] == current["nine_b"]["valid_json_decisions"] == 30
    assert current["nine_b"]["homophone_run"] == report["9b-push-homophones"]
    assert current["four_b_comparator"] == report["4b-homophones"]
    foundation = rows("foundation-smoke.jsonl")
    assert sum(r["event"] == "decision" for r in foundation) == 4
    assert foundation[-1]["event"] == "hard_timeout"
    print("Verified archived evidence: 60 completed local decisions, matched prompt hashes, three preserved aborts, incomplete native baseline, and zero new swap-outs in the full 9B run.")


def verify_weights():
    expected = read("verified-weights.json")["files"]
    for item in expected:
        path = ROOT / "weights" / item["model"] / item["file"]
        with path.open("rb") as handle:
            actual = hashlib.file_digest(handle, "sha256").hexdigest()
        if actual != item["sha256"]:
            raise ValueError(f"Digest mismatch: {item['model']}/{item['file']}")
        print(f"Verified weight digest: {item['model']}/{item['file']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-weights", action="store_true", help="Explicitly read and hash the already-downloaded local weights")
    args = parser.parse_args()
    verify_evidence()
    if args.verify_weights:
        verify_weights()
