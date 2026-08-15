# Cold-prefill benchmark results

Cold-prefill throughput with the exact recipe profile (UD-Q4_K_XL, q8_0 KV, context 262,144, batch 256, MTP, vision) on llama.cpp b10434, measured 2026-08-15 on a 32 GiB RTX 5090.

Every run uses a unique nonce-prefixed prompt (no prompt-cache reuse of the request body), one-token completion, temperature 0, and a pinned seed. Each run is validated for full token accounting (`cache_n + prompt_n = prompt_tokens`, with only the fixed ~42-token chat-template preamble eligible for cache). Values are the mean of three runs per context.

| Prompt tokens | Prefill tok/s (mean of 3) | Prefill tok/s (best) | Time to first token |
|---:|---:|---:|---:|
| 4,096 | 2,620 | 2,714 | 1.5 s |
| 8,192 | 2,767 | 2,786 | 2.9 s |
| 16,384 | 2,722 | 2,727 | 6.0 s |
| 32,768 | 2,537 | 2,540 | 12.9 s |
| 65,536 | 2,028 | 2,032 | 32.3 s |
| 131,072 | 1,450 | 1,451 | 90.3 s |
| 163,840 | 1,272 | 1,272 | 128.8 s |

- 2–2.7K tok/s through 32K context; **1,450 tok/s at 131K** and **1,272 tok/s at 163K**.
- Raw receipt: `qwen3.8-27b-rtx5090-b10434-prefill.json` (per-run timings, VRAM samples, validation states).
- Slot-erase is not implemented on this build (HTTP 501); coldness is guaranteed by nonce-prefixed prompts and the token-accounting validation above.
