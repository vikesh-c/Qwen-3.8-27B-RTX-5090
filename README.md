# Qwen3.8-27B · RTX 5090 · llama.cpp

A single-GPU serving recipe for [Qwen3.8-27B](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) (UD-Q4_K_XL) on an RTX 5090 (32 GiB): full 262K context, embedded MTP speculative decoding, vision, and thinking control. One command downloads everything, one command starts the server.

```powershell
.\scripts\bootstrap.ps1   # HF auth → model + latest llama.cpp, SHA-256 verified
.\scripts\start.ps1       # server up on 127.0.0.1:8080 (key auto-created on first run)
```

## Config

| | |
|---|---|
| Model | `Qwen3.8-27B-UD-Q4_K_XL.gguf` (17.9 GB, 79.3 bits/weight) |
| Context | 262,144 native, q8_0 KV cache, batch 256 |
| Speculative decoding | embedded MTP head, max 2 draft tokens |
| Vision | enabled, `mmproj-F16.gguf` |
| Chat template | GGUF-embedded Qwen3.8 template (thinking on + preserved by default; per-request `enable_thinking:false` / `reasoning_effort: low\|medium\|xhigh` in `chat_template_kwargs`) |
| API | authenticated loopback `127.0.0.1:8080`; key auto-created once under `%LOCALAPPDATA%\Qwen3.8-27B-RTX-5090\llama-server.key`, protected ACL, reused forever |
| llama.cpp runtime | Latest stable at bootstrap time, digest-verified (CUDA); **b10434** is the tested baseline — re-run benchmarks if you use a newer build |

Cold prompts verified through ~245K tokens; a 261K cold prefill exceeds a 10-minute measurement window, so treat ~245K as the practical cold-prompt ceiling. Cached (multi-turn) context decodes at the full 262K context.

## Performance (RTX 5090, b10434)

Cache-warm decode, 3 runs × 500 tokens, temp 0, seed pinned:

| Context | tok/s |
|------:|---:|
| 4K | 115.11 |
| 8K | 114.38 |
| 16K | 110.60 |
| 32K | 102.79 |
| 65K | 91.34 |
| 131K | 67.91 |
| 163K | 61.14 |

**Cold prefill** (unique prompts, no cache reuse, mean of 3):

| Prompt tokens | tok/s | Time to first token |
|---:|---:|---:|
| 8,192 | 2,767 | 2.9 s |
| 32,768 | 2,537 | 12.9 s |
| 131,072 | 1,450 | 90.3 s |
| 163,840 | 1,272 | 128.8 s |

Cold prompts verified through 245,760 tokens (~978 tok/s). MTP draft acceptance ~75–85% depending on workload (84.8% over the live-gate sample; longer mixed runs trend lower).

Full JSON receipts: [`results/`](results/).

## Repository map

```
scripts/    bootstrap, start, stop, status, probe, context-capacity, validate
benchmarks/ bench (decode ladder), prefill, prefill-near-limit
results/    measured receipts (JSON + summary)
config/     profile templates (copy → profile.json)
tests/      process discovery check
```

## Install notes

- **Hugging Face auth is required** for the 17.9 GB model download — bootstrap detects the `hf` CLI, installs it if missing, and walks you through login before downloading. Verified against `unsloth/Qwen3.8-27B-GGUF`.
- Bootstrap installs the **latest stable** llama.cpp with the release's published SHA-256 digests; it refuses to proceed if digests are missing. b10434 is the tested baseline; re-run benchmarks if you run newer.
- Rollback/second model: stop, point `config/profile.json` at another runtime/model, start. One model at a time.

## License

MIT for repository material. Model weights, projector, and llama.cpp binaries retain upstream terms; this repo does not redistribute them.
