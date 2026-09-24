# Minecraft post-training

`tools/export_posttrain.nim` plays ten complete native games per certified
variant. At each command turn it captures the exact hosted system prompt and
fogged seat observation. The shipped miner and scrounger policies supply
plans accepted by the production parser. The native driver expands each plan
into primitives, then the simulator advances. Whole games stay in one split.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/minecraft-posttrain tools/export_posttrain.nim
python3 tools/test_posttrain.py /tmp/minecraft-posttrain
/tmp/minecraft-posttrain /tmp/minecraft-data 10 standard
```

The other certified variant is `deepcut`. Ten games yielded 355 training and
74 validation decisions for `standard`, and 244 and 58 for `deepcut`. The
largest examples used 2,935 and 2,955 tokens with a local Qwen2.5 tokenizer,
within 4,096 tokens. One CPU optimizer step on a tiny local model reduced
validation loss from 5.5775 to 5.4679 and 5.4713 to 5.3728, respectively.
These short runs verify the training path, not policy quality.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/minecraft-data --output /tmp/minecraft-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

The exporter preserves fog: the prompt contains only visited cells and the
current local view. Numeric Metta RL and PufferLib training need a bounded
codec for plans and primitives.
