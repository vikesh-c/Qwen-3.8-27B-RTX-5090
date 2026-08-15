# Security notes

- The launcher creates a random one-line API key under `%LOCALAPPDATA%\Qwen3.8-27B-RTX-5090` and applies a protected user/SYSTEM/Administrators ACL. If `LLAMA_SERVER_API_KEY_FILE` is overridden, keep it outside the repository and protect it equivalently.
- The default and only directly supported bind address is `127.0.0.1`. An API key over plain HTTP is not transport encryption; use an authenticated encrypted tunnel or TLS proxy for deliberate remote access.
- The lifecycle scripts identify the exact executable and model before stopping a process. They never stop unrelated llama.cpp servers or delete model/runtime data.
- Do not commit GGUF weights, CUDA/runtime binaries, API keys, local profiles, slot state, prompt caches, raw logs, prompt transcripts, or machine-specific paths.
- Bootstrap pins model/template revisions and SHA-256 values. Review any revision or hash change before downloading replacement bytes.
- If a credential is committed, revoke it immediately and remove it from repository history.

Report vulnerabilities privately through GitHub's security channel or directly to the repository owner. Do not publish credentials or exploit details in a public issue.
