# Qwen3.8-27B RTX 5090 cache-warm decode benchmark

Complete strict run recorded 2026-08-15 on the live RTX 5090 profile. The server was llama.cpp b10434 with the revision-pinned Q4_K_XL MTP GGUF, F16 projector, official Qwen chat template, Q8 K/V cache, one slot, preserved reasoning, bundled MTP2, and a 262,144-token configured context.

Each point is three runs with a deterministic prompt, `temperature=0`, `top_p=1`, fixed seed `20260814`, `ignore_eos=true`, and exactly 500 completion tokens. Decode speed is the arithmetic mean. GPU values are request-boundary samples rather than a continuous peak. The sequential ladder reused prompt-cache prefixes, so client wall time is cache-affected and must not be interpreted as cold-prefill performance.

| Target context | Actual prompt | Run 1 / 2 / 3 tok/s | Average tok/s | Cache-affected wall s | Endpoint GPU samples MiB |
|---:|---:|---:|---:|---:|---:|
| 4,096 | 4,153 | 113.847 / 115.568 / 115.927 | **115.11** | 5.068 | 31,285-31,285 |
| 8,192 | 8,249 | 113.890 / 114.784 / 114.478 | **114.38** | 5.408 | 31,285-31,285 |
| 16,384 | 16,441 | 110.062 / 111.218 / 110.521 | **110.60** | 6.598 | 31,285-31,285 |
| 32,768 | 32,825 | 103.161 / 102.210 / 103.010 | **102.79** | 7.320 | 31,285-31,285 |
| 65,536 | 65,593 | 90.248 / 91.733 / 92.052 | **91.34** | 12.181 | 31,285-31,285 |
| 131,072 | 131,129 | 68.259 / 67.636 / 67.843 | **67.91** | 27.172 | 31,285-31,285 |
| 163,840 | 163,897 | 61.389 / 60.840 / 61.191 | **61.14** | 21.625 | 31,285-31,285 |

All 21 requests returned exactly 500 completion tokens. The maximum endpoint sample was 31,285 MiB. This benchmark measures the standard repository ladder; it does not extrapolate decode speed from a 261K active history.

Artifact identity, all run arrays, runner/source hashes, and profile flags are in [`qwen3.8-27b-rtx5090-b10434-3x500.json`](qwen3.8-27b-rtx5090-b10434-3x500.json).