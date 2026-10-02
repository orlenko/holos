"""Download only explicitly approved pinned public weights; never read account credentials."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
os.environ["HF_HOME"] = str(ROOT / "hf-cache")
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_XET"] = "1"
from huggingface_hub import snapshot_download

manifest = json.loads((ROOT / "models.json").read_text())
approved = [m for m in manifest["models"] if m.get("approved")]
assert [m["repo"] for m in approved] == [
    "mlx-community/Qwen3.5-4B-4bit", "mlx-community/Qwen3.5-9B-MLX-4bit"]
if not (ROOT / "runtime-freeze.txt").exists():
    with (ROOT / "runtime-freeze.txt").open("x") as output:
        subprocess.run(["uv", "pip", "freeze", "--python", sys.executable], stdout=output, check=True)
with (ROOT / "downloads.jsonl").open("a") as log:
    for model in approved:
        directory = ROOT / "weights" / model["repo"].split("/")[-1]
        start = time.perf_counter()
        print(json.dumps({"event": "download_start", "repo": model["repo"], "revision": model["revision"]}), flush=True)
        snapshot_download(model["repo"], revision=model["revision"], local_dir=directory,
                          allow_patterns=["*.json", "*.jinja", "*.safetensors", "*.txt", "*.model", "README.md", "LICENSE*"],
                          token=False, max_workers=2)
        weights = list(directory.glob("*.safetensors"))
        total = sum(p.stat().st_size for p in weights)
        if total != model["weight_bytes"]:
            raise RuntimeError(f"Weight byte count mismatch for {model['repo']}: {total}")
        row = {"event": "download_complete", "repo": model["repo"], "revision": model["revision"],
               "directory": str(directory), "weight_bytes": total, "seconds": time.perf_counter() - start}
        print(json.dumps(row), flush=True)
        log.write(json.dumps(row) + "\n")
        log.flush()
