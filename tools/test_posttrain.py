"""Check complete, seed-separated Minecraft post-training games."""

import json
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


for variant in ("standard", "deepcut"):
    with TemporaryDirectory() as temporary:
        output = Path(temporary) / variant
        subprocess.run([sys.argv[1], str(output), "10", variant], check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert len(manifest["runs"]) == 10
        assert manifest["train_examples"] == len(train) > 0
        assert manifest["validation_examples"] == len(validation) > 0
        assert {row["seed"] for row in train}.isdisjoint({row["seed"] for row in validation})
        assert all(run["reason"] == "complete" for run in manifest["runs"])
        for row in train + validation:
            assert row["game"] == "minecraft"
            assert [part["role"] for part in row["prompt"]] == ["system", "user"]
            observation = json.loads(row["prompt"][1]["content"])
            assert "agent" in observation and "view" in observation and "milestones" in observation
            completion = json.loads(row["completion"][0]["content"])
            assert 0 < len(completion["actions"]) <= 12
            assert all("act" in action for action in completion["actions"])
        print(f"{variant}: {len(train)} train, {len(validation)} validation decisions")
