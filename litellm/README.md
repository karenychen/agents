# LiteLLM GitHub Copilot Proxy

This folder runs LiteLLM in Docker as a local-only proxy for Claude Code and Codex, backed by GitHub Copilot. The runtime is intentionally narrow: a read-only LiteLLM container, a default-deny egress proxy, a no-secret localhost ingress proxy, a local LiteLLM master-key file, and one named Docker volume for the Copilot auth cache.

## Layout

- `config/config.yaml` exposes an exact Codex Responses API route plus a wildcard Copilot route, so all Copilot model names route through `github_copilot/*` by default.
- `proxy/` builds a tinyproxy egress sidecar with a host allowlist.
- `ingress/` builds a no-secret local ingress sidecar used for host port publishing. It also strips Codex-only `internal_chat_message_metadata_passthrough` fields from Responses requests because Copilot rejects that internal client metadata.
- `auth.sh` bootstraps the GitHub Copilot token cache into a named Docker volume.
- `setup.sh` builds/starts the hardened runtime.
- `clients/` contains shell env helpers and config snippets for Claude Code and Codex.
- `test/` contains local verification scripts.

## Bootstrap

```bash
cd litellm
./auth.sh
./setup.sh
./test/smoke.sh
./test/hardening.sh
./test/egress.sh
```

`./auth.sh` may print a GitHub device-code prompt. Complete that flow in the browser and wait for the command to print `ok`.

The scripts default to Docker:

```bash
cp .env.example .env
```

Standalone Docker does not provide `docker run` secrets, so the script passes `LITELLM_MASTER_KEY` through the container environment from the local `0600` key file at `~/.config/litellm/master_key`.

## Claude Code

For one shell:

```bash
source ./clients/claude-code.env.sh
claude
```

Or run a single command with the proxy env applied:

```bash
./clients/claude-code.env.sh claude
```

The default Claude Code model is `claude-sonnet-5`, with `claude-opus-4.8` as the Opus default. Both were verified against this Copilot account through the local proxy. Because `config/config.yaml` has a wildcard route, other Copilot model names can be selected without adding a new config entry unless that model needs endpoint-specific metadata.

If you prefer Claude settings, copy the non-secret values from `clients/claude-code.settings.example.json`, then set `ANTHROPIC_AUTH_TOKEN` from `~/.config/litellm/master_key` in your launch environment.

## Codex

Add the provider block from `clients/codex.config.example.toml` to `~/.codex/config.toml`, then launch Codex with:

```bash
source ./clients/codex.env.sh
codex
```

The provider uses the OpenAI-compatible Responses API and the `gpt-5.5` model alias from `config/config.yaml`.

`gpt-5.5` and `gpt-5.3-codex` are kept as exact routes because they use the Responses API. Other model names fall through to the wildcard `github_copilot/*` route.

`gpt-5.5` is the default for Codex. `gpt-5.3-codex` remains available as an explicit Responses route.

## Security Shape

- `litellm-copilot` runs as the calling user's unprivileged UID by default, and `litellm-copilot-egress` runs as numeric non-root UID `10001`.
- `litellm-copilot-ingress` publishes `127.0.0.1:4000` and forwards requests to LiteLLM over the internal network.
- Both containers drop all Linux capabilities, enable `no-new-privileges`, use read-only root filesystems, and have pids, memory, and CPU ceilings.
- Only the ingress sidecar is published on `127.0.0.1`; LiteLLM itself has no published port.
- LiteLLM has no direct internet network attachment. It can only reach the egress sidecar over the internal network and uses `HTTP_PROXY`/`HTTPS_PROXY`.
- The egress sidecar default-denies destinations except GitHub OAuth/API and GitHub Copilot hosts.
- The only persistent runtime write path is the named Copilot auth volume.
- The LiteLLM master key is stored at `~/.config/litellm/master_key` with mode `0600` for local client wiring.

Runtime state intentionally lives outside this repository directory: Docker stores the auth cache in the `litellm_copilot_auth` volume, and the bearer key lives at `~/.config/litellm/master_key`.

## Incident Response

If you suspect the LiteLLM stack or egress sidecar was compromised, treat it as both a credential incident and a prompt/response exposure event:

```bash
cd litellm
./incident-response.sh
```

The helper collects host-side container evidence, stops the stack, exports and removes the Copilot auth volume, and rotates the LiteLLM master key. It does not exec into the compromised containers. Afterward, revoke the GitHub OAuth/Copilot authorization used by LiteLLM, then rebuild and re-authenticate from trusted pins:

```bash
./auth.sh
./setup.sh
./test/smoke.sh
./test/hardening.sh
./test/egress.sh
```

## Refresh Pins

When refreshing dependencies, update `.env.example` after verifying:

```bash
gh release view --repo BerriAI/litellm --json tagName,publishedAt,isPrerelease,isDraft
docker manifest inspect ghcr.io/berriai/litellm:<tag>
docker run --rm <alpine-image> sh -lc 'apk update >/dev/null && apk policy tinyproxy'
```

Keep arch-specific LiteLLM digests pinned in `.env.example`; `setup.sh` selects the digest for the local Docker architecture.
