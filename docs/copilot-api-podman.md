# Running `copilot-api` as a Hardened Podman Proxy

This documents the validated local `copilot-api` deployment on macOS with Podman. The proxy runs on `http://localhost:4141`, exposes an OpenAI-compatible API at `http://localhost:4141/v1`, and stores all durable auth/config state in the named volume `copilot-data`.

## Overview

| Property | Value |
| --- | --- |
| Container | `copilot-api` |
| Image | `localhost/copilot-api:local` |
| Bind | `127.0.0.1:4141:4141` |
| Volume | `copilot-data:/root/.local/share/copilot-api` |
| Build context | `~/projects/copilot-api` |
| Runtime | Podman remote (`podman machine`) |
| Verified release | `v1.13.11` (`a5361a4`) |

## Authentication Model

There are two credential layers:

1. GitHub Copilot auth upstream is persisted in the volume at `opencode/github_token`. It is created by the interactive `--auth` flow.
2. Proxy API keys downstream are stored in `config.json` under `auth.adminApiKey` and `auth.apiKeys`. Host clients send one key as `Authorization: Bearer $COPILOT_API_KEY`.

Do not inject `GH_TOKEN`, `COPILOT_API_KEY`, or proxy keys into the container environment. The container falls back to the persisted GitHub token, and host clients provide the proxy bearer key.

## Build

```sh
cd ~/projects/copilot-api
git fetch --tags origin
git checkout dev
git pull --ff-only
git describe --tags --exact-match HEAD || git describe --tags --abbrev=0
podman build -t localhost/copilot-api:local .
```

Before rebuilding an existing deployment, tag the current image for rollback:

```sh
TS=$(date +%Y%m%d-%H%M%S)
podman tag localhost/copilot-api:local localhost/copilot-api:rollback-$TS
```

## Initial Auth

Create the persistent volume and run the interactive auth flow once:

```sh
podman volume create copilot-data
podman run --rm -it \
  -v copilot-data:/root/.local/share/copilot-api \
  localhost/copilot-api:local \
  --auth
```

## Hardened Run Command

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

The loopback bind keeps the proxy off the LAN. The read-only root filesystem, tmpfs scratch path, dropped capabilities, no-new-privileges, memory/CPU limits, and PID cap reduce the impact of a compromised process.

## Persistent State

All durable state is in `copilot-data`:

| Path | Purpose |
| --- | --- |
| `config.json` | Proxy config and keys. |
| `copilot-api.sqlite*` | Proxy database. |
| `opencode/github_token` | Persisted GitHub Copilot token. |

Inspect config with `node:22-alpine`; do not assume Alpine has `jq` installed:

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

Final verified config snapshot after the v1.13.11 rebuild:

```json
{"useResponsesApiWebSocket":true,"useMessagesApi":true,"apiKeyCount":1,"hasAuthAdminApiKey":true}
```

## Safe Config Edits

Back up `config.json`, write through a temporary file, then restart:

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

`useResponsesApiWebSocket=false` was a temporary troubleshooting workaround for a prior streaming issue. The current rebuilt and verified deployment uses `useResponsesApiWebSocket=true`.

## Upgrade Existing Container

1. Inspect the current mounts before changing anything:

   ```sh
   podman ps --filter name=copilot-api
   podman inspect copilot-api --format '{{json .Mounts}}'
   podman inspect copilot-api --format '{{.Image}} {{.HostConfig.RestartPolicy.Name}} {{.HostConfig.ReadonlyRootfs}}'
   ```

2. Preserve the actual mounted state volume. If it is not `copilot-data`, use the actual volume name or stop and ask before recreating the container.
3. Update the repo and identify the release; do not blindly pull an image tagged `latest`.
4. Tag the current local image as `localhost/copilot-api:rollback-$TS` before rebuilding.
5. Stop and remove only the container, then recreate it with the same state volume and hardened run flags.

## Verification

Run fresh verification before claiming the proxy is healthy:

```sh
podman ps --filter name=copilot-api
podman inspect copilot-api --format '{{json .HostConfig}}'
podman logs --tail 80 copilot-api

/usr/bin/curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4141/v1/models

/usr/bin/curl -s http://localhost:4141/v1/models \
  -H "Authorization: Bearer $COPILOT_API_KEY" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s);console.log(JSON.stringify({count:j.data?.length, hasGpt55:j.data?.some(m=>m.id==="gpt-5.5"), bannedClaudeVariantPresent:j.data?.some(m=>/^claude-opus-4\.7(?:1m|-1m-internal)$/.test(m.id))}));})'

/usr/bin/curl -s http://localhost:4141/v1/responses \
  -H "Authorization: Bearer $COPILOT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-5.5","input":"Reply with exactly: ok","max_output_tokens":20}'
```

For `gpt-5.5`, `/v1/responses` is the valid smoke path. `/v1/chat/completions` can return `400` because that model is not available through the chat completions endpoint.

## Rollback

If the new container fails verification, retag the rollback image and recreate the container with the same state volume:

```sh
podman rm -f copilot-api
podman tag localhost/copilot-api:rollback-<timestamp> localhost/copilot-api:local
# rerun the hardened podman run command with copilot-data
```

Never delete or recreate `copilot-data` unless intentionally resetting auth/config.
