# Benchmark results

- `qwen3.8-27b-rtx5090-b10434-3x500.{json,md}` — cache-warm decode ladder: 7 context sizes, 3 runs × 500 tokens, temp 0, seed pinned. 115 tok/s at 4K → 61 tok/s at 163K.
- `qwen3.8-27b-rtx5090-b10434-prefill.{json,md}` — cold-prefill ladder: 7 context sizes × 3 runs, unique nonce prompts, cache validated. 2,767 tok/s at 8K → 1,272 tok/s at 163K prompt tokens.
- `qwen3.8-27b-rtx5090-b10434.{json,md}` — capacity + MTP receipts: cold prompts verified through 245,760 tokens (~978 tok/s at that size), MTP acceptance ~75–85% by workload.

Cold prompts are verified through ~245K tokens; a 261K cold prompt exceeds a 10-minute measurement window, so treat ~245K as the practical cold-prompt ceiling. Cache-warm decode covers the full 262K context.
