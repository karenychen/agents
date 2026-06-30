---
name: copilot-api-container
description: >
  Use when setting up copilot-api as a local containerized proxy on a new
  machine, or upgrading an existing copilot-api Podman or Docker container
  without losing persisted GitHub Copilot auth, proxy keys, or config.
allowed-tools:
  - bash
  - read
  - grep
  - glob
  - question
---

# copilot-api Container Setup and Upgrade

Set up or upgrade `copilot-api` as a loopback-only local proxy while preserving persistent state. Podman on macOS is the primary validated path; Docker/Linux is supported as a variant with the same volume and verification rules.

## When to Use

- User asks to install, set up, run, or rebuild `copilot-api` on a new machine.
- User asks to upgrade an existing `copilot-api` container to the latest release.
- User needs a local OpenAI-compatible proxy for GitHub Copilot models at `http://localhost:4141`.
- User mentions Podman, Docker, `copilot-data`, `localhost/copilot-api:local`, or preserving Copilot auth/config.

## Non-Negotiables

| Rule | Why |
| --- | --- |
| Preserve the state volume | It contains `config.json`, proxy API keys, SQLite state, and GitHub Copilot auth token. |
| Bind only to `127.0.0.1:4141` | Avoid exposing Copilot access on the LAN. |
| Do not assume `.env`, Compose, or `GH_TOKEN` | The validated container falls back to the token persisted in the volume. |
| Do not blindly pull `latest` | Update the repo, identify the release/tag, then rebuild the local image. |
| Tag rollback image before rebuilding | Enables quick recovery if the new image fails. |
| Verify with raw `curl` | Wrappers may format output and break JSON parsing. |
| Avoid banned Claude variants in tests | Never use `claude-opus-4.7[1m]` or `claude-opus-4.7-1m-internal`. |

## Defaults

| Setting | Value |
| --- | --- |
| Repo | `~/projects/copilot-api` |
| Image | `localhost/copilot-api:local` |
| Container | `copilot-api` |
| Volume | `copilot-data` |
| URL | `http://localhost:4141` |
| API base | `http://localhost:4141/v1` |
| Runtime | Podman on macOS, Docker on Linux when requested |

## New Machine Setup

1. Confirm runtime and repo location.

   ```sh
   command -v podman || command -v docker
   # macOS if Podman is missing:
   brew install podman
   podman machine init
   podman machine start

   mkdir -p ~/projects
   git clone https://github.com/caozhiyuan/copilot-api.git ~/projects/copilot-api
   cd ~/projects/copilot-api
   git fetch --tags origin
   git checkout dev
   git pull --ff-only
   git describe --tags --exact-match HEAD || git describe --tags --abbrev=0
   ```

2. Build the local image.

   ```sh
   podman build -t localhost/copilot-api:local .
   # Docker variant:
   docker build -t localhost/copilot-api:local .
   ```

3. Create or reuse the persistent volume.

   ```sh
   podman volume create copilot-data
   # Docker variant:
   docker volume create copilot-data
   ```

4. Run one interactive auth flow if the volume does not already contain a token.

   ```sh
   podman run --rm -it -v copilot-data:/root/.local/share/copilot-api localhost/copilot-api:local --auth
   # Docker variant:
   docker run --rm -it -v copilot-data:/root/.local/share/copilot-api localhost/copilot-api:local --auth
   ```

5. Start the hardened proxy.

   ```sh
   podman run -d \
     --name copilot-api \
     --restart unless-stopped \
     -p 127.0.0.1:4141:4141 \
     -v copilot-data:/root/.local/share/copilot-api \
     --read-only \
     --tmpfs /tmp \
     --cap-drop=ALL \
     --security-opt=no-new-privileges \
     --memory=512m \
     --cpus=1.0 \
     --pids-limit=200 \
     localhost/copilot-api:local \
     start --oauth-app=opencode
   ```

   Docker uses the same flags on Linux:

   ```sh
   docker run -d \
     --name copilot-api \
     --restart unless-stopped \
     -p 127.0.0.1:4141:4141 \
     -v copilot-data:/root/.local/share/copilot-api \
     --read-only \
     --tmpfs /tmp \
     --cap-drop=ALL \
     --security-opt=no-new-privileges \
     --memory=512m \
     --cpus=1.0 \
     --pids-limit=200 \
     localhost/copilot-api:local \
     start --oauth-app=opencode
   ```

6. Configure clients to send the proxy bearer key with `COPILOT_API_KEY`. The key is client-side; do not inject it into the container environment.

   ```sh
   podman run --rm -v copilot-data:/data:ro node:22-alpine node -e '
   const fs = require("fs");
   const cfg = JSON.parse(fs.readFileSync("/data/config.json", "utf8"));
   console.log(cfg.auth?.apiKeys?.[0]?.key || cfg.auth?.apiKeys?.[0] || "");'
   ```

   Export that value on the host for smoke tests and client configuration only.

7. Add client configuration. Merge these snippets into existing files; do not replace unrelated settings and do not commit the bearer key.

   Codex CLI reads the bearer key from `COPILOT_API_KEY` and uses the Responses API wire format:

   ```toml
   # ~/.codex/config.toml
   model_provider = "copilot"

   [model_providers.copilot]
   name = "copilot"
   base_url = "http://127.0.0.1:4141/v1"
   env_key = "COPILOT_API_KEY"
   wire_api = "responses"
   ```

   Claude Code should point at the local proxy in `~/.claude/settings.local.json`, and read the bearer token from the shell environment:

   ```json
   {
     "env": {
       "ANTHROPIC_BASE_URL": "http://localhost:4141"
     }
   }
   ```

   ```sh
   export ANTHROPIC_AUTH_TOKEN="$COPILOT_API_KEY"
   ```

## Upgrade Existing Container

1. Inspect current state before changing anything.

   ```sh
   cd ~/projects/copilot-api
   git status --short --branch
   git fetch --tags origin
   git pull --ff-only
   git describe --tags --exact-match HEAD || git describe --tags --abbrev=0
   podman ps --filter name=copilot-api
   podman inspect copilot-api --format '{{json .Mounts}}'
   podman inspect copilot-api --format '{{.Image}} {{.HostConfig.RestartPolicy.Name}} {{.HostConfig.ReadonlyRootfs}}'
   ```

   If the state mount is not the default `copilot-data` volume, preserve the actual mounted volume or stop and ask before recreating the container.

2. Confirm the persisted volume exists and contains expected config.

   ```sh
   podman run --rm -v copilot-data:/data:ro node:22-alpine node -e '
   const fs = require("fs");
   const cfg = JSON.parse(fs.readFileSync("/data/config.json", "utf8"));
   console.log(JSON.stringify({
     useResponsesApiWebSocket: cfg.useResponsesApiWebSocket,
     useMessagesApi: cfg.useMessagesApi,
     apiKeyCount: cfg.auth?.apiKeys?.length ?? 0,
     hasAuthAdminApiKey: Boolean(cfg.auth?.adminApiKey)
   }));'
   ```

   Do not use `alpine jq` unless `jq` is installed in that image.

3. Tag the current image for rollback before rebuilding.

   ```sh
   TS=$(date +%Y%m%d-%H%M%S)
   podman tag localhost/copilot-api:local localhost/copilot-api:rollback-$TS
   ```

4. Rebuild the local image from the updated repo. If `git describe --tags --exact-match HEAD` did not return a release tag, say so; do not claim a stable release upgrade.

   ```sh
   podman build -t localhost/copilot-api:local .
   ```

5. Recreate the container without touching the volume.

   ```sh
   podman stop copilot-api
   podman rm copilot-api
   podman run -d \
     --name copilot-api \
     --restart unless-stopped \
     -p 127.0.0.1:4141:4141 \
     -v copilot-data:/root/.local/share/copilot-api \
     --read-only \
     --tmpfs /tmp \
     --cap-drop=ALL \
     --security-opt=no-new-privileges \
     --memory=512m \
     --cpus=1.0 \
     --pids-limit=200 \
     localhost/copilot-api:local \
     start --oauth-app=opencode
   ```

Docker upgrade variant uses `docker` for the same inspect, tag, build, stop, rm, and run commands.

## Safe Config Edits

Back up the volume config before changing it, write through a temporary file, and restart the container.

```sh
mkdir -p ~/.local/state/copilot-api/backups
TS=$(date +%Y%m%d-%H%M%S)
podman run --rm -v copilot-data:/data:ro alpine cat /data/config.json \
  > ~/.local/state/copilot-api/backups/$TS-config.json

podman run --rm -v copilot-data:/data node:22-alpine node -e '
const fs = require("fs");
const path = "/data/config.json";
const cfg = JSON.parse(fs.readFileSync(path, "utf8"));
cfg.useResponsesApiWebSocket = true;
fs.writeFileSync(path + ".tmp", JSON.stringify(cfg, null, 2) + "\n");
fs.renameSync(path + ".tmp", path);'

podman restart copilot-api
```

Use Docker by replacing `podman` with `docker`.

## Verification

Run fresh verification before claiming success.

```sh
podman ps --filter name=copilot-api
podman inspect copilot-api --format '{{json .HostConfig}}'
podman logs --tail 80 copilot-api
```

Expected hardening values:

- `RestartPolicy.Name = unless-stopped`
- `ReadonlyRootfs = true`
- memory cap `536870912`
- one CPU (`NanoCpus = 1000000000` in Podman inspect)
- `PidsLimit = 200`

Verify API behavior with raw curl:

```sh
/usr/bin/curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4141/v1/models

/usr/bin/curl -s http://localhost:4141/v1/models \
  -H "Authorization: Bearer $COPILOT_API_KEY" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s);console.log(JSON.stringify({count:j.data?.length, hasGpt55:j.data?.some(m=>m.id==="gpt-5.5"), bannedClaudeVariantPresent:j.data?.some(m=>/^claude-opus-4\.7(?:-1m|-1m-internal)$/.test(m.id))}));})'

/usr/bin/curl -s http://localhost:4141/v1/responses \
  -H "Authorization: Bearer $COPILOT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-5.5","input":"Reply with exactly: ok","max_output_tokens":20}'
```

For `gpt-5.5`, `/v1/responses` is the smoke path. `/v1/chat/completions` may return `400` because the model is not accessible through that endpoint.

## Rollback

If the new container fails verification:

```sh
podman rm -f copilot-api
podman tag localhost/copilot-api:rollback-<timestamp> localhost/copilot-api:local
podman run -d \
  --name copilot-api \
  --restart unless-stopped \
  -p 127.0.0.1:4141:4141 \
  -v copilot-data:/root/.local/share/copilot-api \
  --read-only \
  --tmpfs /tmp \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --memory=512m \
  --cpus=1.0 \
  --pids-limit=200 \
  localhost/copilot-api:local \
  start --oauth-app=opencode
```

The rollback must reuse `copilot-data`; do not restore by creating a fresh volume unless the user explicitly asks to reset auth/config.

## Common Mistakes

| Mistake | Correction |
| --- | --- |
| Using `docker compose up` without repo support | Build from the Dockerfile and run with explicit volume/hardening flags. |
| Setting `GH_TOKEN` or proxy keys in container env | Let upstream auth come from the persisted token; clients send `COPILOT_API_KEY`. |
| Publishing `0.0.0.0:4141` | Bind `127.0.0.1:4141:4141`. |
| Deleting the old container before confirming persistence | Inspect mounts first; preserve `copilot-data`. |
| Pulling `latest` blindly | Update the repo, identify the latest release/tag, build `localhost/copilot-api:local`. |
| Testing only `/v1/chat/completions` | Use `/v1/responses` for `gpt-5.5`. |
