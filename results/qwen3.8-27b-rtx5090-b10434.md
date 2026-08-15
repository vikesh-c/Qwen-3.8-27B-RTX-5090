# Qwen3.8-27B UD-Q4_K_XL on RTX 5090 — final b10434 cutover

Measured 2026-08-14 with llama.cpp b10434 (`7e4c0a96880dae4fc4268ad441f8a6446bd5460a`, CUDA 13.3) on a 32 GiB RTX 5090. The final live profile is one loopback slot, q8_0 K/V, F16 projector, official template, and bundled two-token `draft-mtp`.

## Runtime and artifact identity

- Runtime binary SHA-256: `5f1f831bc21dcbff4ca40e05cb59dbcbc0802d20b2046540bbbf3bd45cd61610`.
- Model: Unsloth revision `430473d9d0e975450ce1f445642b6527cb4faea1`, SHA-256 `bee238bbeb3dc0a34bde4d0dedbaee1f98c009e8bb4226f03070054c12fb1372`.
- Projector: the same Unsloth revision, SHA-256 `cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e`.
- Template: official Qwen revision `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`, SHA-256 `c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`.

## Live request gates

- Thinking reasoning efforts: `xhigh`, `medium`, and `low` passed.
- Non-thinking with `preserve_thinking=false` passed without reasoning output.
- Vision, streaming, and tool initial-call gates passed.
- Tool continuation passed with the returned function call and a tool result.
- Three unique non-thinking smoke requests passed with `cacheTokens=0`.
- Bundled MTP remained enabled in the final service; 43 log records observed 509 accepted of 600 generated draft tokens (84.8333%, record range 66.667%–100%). No unsupported/unused MTP warnings were observed.

## Capacity boundary

A b10434 ladder verified cold prompts at 32,768 / 65,536 / 131,072 / 245,760 target tokens; ~245K is the practical cold-prompt ceiling (261K exceeds a 10-minute measurement window). The slot erase endpoint returned HTTP 501, so unique nonces and observed zero cache remain mandatory for cold-prefill measurements.
