"""Read a few small norm tensors, without materializing model weights or importing MLX."""
import json
from pathlib import Path
import statistics
import struct

ROOT = Path(__file__).resolve().parent
rows = []
for directory in ["Qwen3.5-4B-4bit", "Qwen3.5-9B-MLX-4bit"]:
    for path in sorted((ROOT / "weights" / directory).glob("*.safetensors")):
        with path.open("rb") as handle:
            size = struct.unpack("<Q", handle.read(8))[0]
            if size > 10 * 1024**2:
                raise ValueError("Unreasonable safetensors header size")
            header = json.loads(handle.read(size))
            for key, tensor in header.items():
                if not (key.endswith("model.norm.weight") or key.endswith("layers.0.input_layernorm.weight")):
                    continue
                start, end = tensor["data_offsets"]
                if end - start > 65536:
                    raise ValueError("Diagnostic tensor unexpectedly large")
                handle.seek(8 + size + start)
                data = handle.read(end - start)
                if tensor["dtype"] == "BF16":
                    values = [struct.unpack("<f", struct.pack("<I", value << 16))[0]
                              for (value,) in struct.iter_unpack("<H", data)]
                elif tensor["dtype"] == "F16":
                    values = [value for (value,) in struct.iter_unpack("<e", data)]
                elif tensor["dtype"] == "F32":
                    values = [value for (value,) in struct.iter_unpack("<f", data)]
                else:
                    raise ValueError("Unsupported diagnostic norm dtype")
                rows.append({"model": directory, "key": key, "dtype": tensor["dtype"], "shape": tensor["shape"],
                             "min": min(values), "max": max(values), "mean": statistics.mean(values)})
result = {"purpose": "Limited conversion sanity check, not verification against original full-precision weights", "norms": rows}
(ROOT / "norm-sanity.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
