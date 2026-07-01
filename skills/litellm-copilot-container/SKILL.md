---
name: litellm-copilot-container
description: >
  Use when setting up or repairing a local LiteLLM container proxy for Codex
  app/CLI or Claude Code to GitHub Copilot, especially with Podman, Docker,
  gpt-5.5, Claude models, missing LITELLM_MASTER_KEY, hidden Codex chats, or
  Copilot/LiteLLM Responses API errors.
allowed-tools:
  - bash
  - read
  - grep
  - glob
  - question
---

# LiteLLM Copilot Container

Set up `litellm/` as a loopback-only LiteLLM proxy to GitHub Copilot with a small compromise blast radius. Docker is the primary supported path.

## When to Use

- User asks to set up LiteLLM for Codex or Claude Code using GitHub Copilot.
- User needs a local proxy at `http://127.0.0.1:4000`.
- User mentions Podman, Docker, `gpt-5.5`, `claude-sonnet-5`, `LITELLM_MASTER_KEY`, hidden Codex chats, `internal_chat_message_metadata_passthrough`, or Copilot Responses API errors.

## Non-Negotiables

| Rule | Why |
| --- | --- |
| Keep Codex `model_provider = "copilot"` | Existing Codex chats are keyed by provider id; renaming it hides active/archived chats. |
| Bind only `127.0.0.1:4000` | Avoid exposing Copilot access on the LAN. |
| Use the ingress sanitizer | Codex sends `internal_chat_message_metadata_passthrough`; Copilot rejects it unless stripped. |
| Keep LiteLLM on an internal network | LiteLLM should not have direct internet egress. |
| Verify with raw `curl` | Client wrappers can hide JSON bodies and status codes. |
| Do not commit `.env`, master keys, auth volumes, or pycache | They contain local state or generated files. |

## Runtime Topology

| Container | Purpose | Network |
| --- | --- | --- |
| `litellm-copilot` | LiteLLM proxy, no published port | `litellm_internal` only |
| `litellm-copilot-egress` | tinyproxy allowlisted egress to GitHub/Copilot | `litellm_egress` + `litellm_internal` |
| `litellm-copilot-ingress` | loopback ingress + Codex metadata sanitizer | `litellm_ingress` + `litellm_internal` |

The proxy uses a named auth volume `litellm_copilot_auth`. Podman uses secret `litellm_master_key`; Docker reads `~/.config/litellm/master_key` into the container env because standalone Docker has no `docker run` secret equivalent.

## Fresh Machine Setup

1. Install a runtime.

   ```sh
   # macOS Podman
   brew install podman
   podman machine init
   podman machine set --memory 4096
   podman machine start

   # Or Docker: install Docker Desktop / docker engine.
   ```

2. Clone/update this repo and choose runtime.

   ```sh
   git clone <agents-repo-url> agents
   cd agents/litellm
   cp .env.example .env
   ```

3. Authenticate Copilot into the isolated volume.

   ```sh
   ./auth.sh
   ```

   Complete the GitHub device-code prompt. If `python` is treated as a LiteLLM subcommand, `auth.sh` is stale; it must use `--entrypoint python`.

4. Start and verify.

   ```sh
   ./setup.sh
   ./test/smoke.sh
   ./test/hardening.sh
   ./test/egress.sh
   ```

5. Verify real models.

   ```sh
   KEY=$(sed -n '1p' ~/.config/litellm/master_key)
   curl -fsS http://127.0.0.1:4000/v1/responses \
     -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
     -d '{"model":"gpt-5.5","input":"Reply with exactly: ok","max_output_tokens":50}'

   curl -fsS http://127.0.0.1:4000/v1/messages \
     -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
     -d '{"model":"claude-sonnet-5","max_tokens":20,"messages":[{"role":"user","content":"Reply with exactly: ok"}]}'
   ```

## Client Setup

### Codex

Merge into `~/.codex/config.toml`; preserve the provider id:

```toml
model = "gpt-5.5"
model_provider = "copilot"

[model_providers.copilot]
name = "OpenAI"
base_url = "http://127.0.0.1:4000"
env_key = "LITELLM_MASTER_KEY"
requires_openai_auth = false
supports_websockets = false
wire_api = "responses"
request_max_retries = 3
stream_max_retries = 1
stream_idle_timeout_ms = 300000
```

Set GUI/terminal environment:

```sh
KEY=$(~/.local/bin/litellm-master-key)
launchctl setenv LITELLM_MASTER_KEY "$KEY"       # macOS GUI apps
export LITELLM_MASTER_KEY="$KEY"                 # shell-launched Codex
```

If active/archived chats disappear, query `~/.codex/state_5.sqlite`; existing threads probably still use `model_provider='copilot'`. Do not create a new provider id.

### Claude Code

Use an API key helper instead of hardcoding the key:

```json
{
  "apiKeyHelper": "<absolute-path-to-home>/.local/bin/litellm-master-key",
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
    "ANTHROPIC_MODEL": "claude-sonnet-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4.8"
  }
}
```

For macOS GUI launches:

```sh
KEY=$(~/.local/bin/litellm-master-key)
launchctl setenv ANTHROPIC_AUTH_TOKEN "$KEY"
launchctl setenv ANTHROPIC_BASE_URL "http://127.0.0.1:4000"
launchctl setenv ANTHROPIC_MODEL "claude-sonnet-5"
```

## Troubleshooting

| Symptom | Root cause | Fix |
| --- | --- | --- |
| `Missing environment variable: LITELLM_MASTER_KEY` | Codex app lacks launch env | `launchctl setenv LITELLM_MASTER_KEY "$(~/.local/bin/litellm-master-key)"`, then restart Codex. |
| Chats vanish in Codex UI | Provider id changed away from `copilot` | Restore `model_provider = "copilot"` and `[model_providers.copilot]`. |
| `internal_chat_message_metadata_passthrough` error | Codex internal metadata reached Copilot | Ensure ingress sanitizer image is current: `./setup.sh`. |
| Host `127.0.0.1:4000` hangs | Published directly from internal network | Use `litellm-copilot-ingress`; LiteLLM itself must have no published port. |
| `gpt-5.5` says chat endpoint inaccessible | Wildcard routed it to chat | Keep exact `gpt-5.5` route with `model_info.mode: responses`. |
| Egress positive test fails from proxy loopback | Test path is wrong | Test CONNECT from `litellm-copilot` to `litellm-copilot-egress`, not from inside the proxy container. |

## Incident Response

Run:

```sh
cd litellm
./incident-response.sh
```

Then revoke the GitHub OAuth/Copilot authorization, re-run `./auth.sh`, `./setup.sh`, and all tests. Treat prompts/responses and the old Copilot auth volume as exposed.

## Verification Checklist

Before claiming success:

```sh
cd litellm
find . -name '*.sh' -exec bash -n {} \;
python3 -m py_compile ingress/sanitize_proxy.py
./setup.sh
./test/smoke.sh
./test/hardening.sh
./test/egress.sh
```

Confirm:

- `litellm-copilot` has no published port.
- `litellm-copilot-ingress` publishes `127.0.0.1:4000`.
- `gpt-5.5` `/v1/responses` returns content.
- `claude-sonnet-5` `/v1/messages` returns content.
