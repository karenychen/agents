# Copilot API Local Gateway

This stack runs a local `copilot-api` gateway on `http://127.0.0.1:4000`.

## Start

```sh
./scripts/up.sh
```

## Authentication

Initial setup requires a GitHub device login:

```sh
./scripts/auth.sh
./scripts/up.sh
```

Routine daily re-auth is not expected. The running `copilot-api` service reads the persisted GitHub token from the Docker volume and refreshes short-lived Copilot access tokens in the background before they expire.

Run `./scripts/auth.sh` again only when the persisted GitHub token is no longer valid, the OAuth authorization was revoked, the Docker volume was deleted, or incident response requires credential rotation.

## Codex streaming stability

Keep `useResponsesApiWebSocket` set to `false` in `/data/config.json`. This avoids a known Codex/copilot-api failure mode where the upstream Responses WebSocket stream closes before `response.completed`, often after `internal_chat_message_metadata_passthrough` or transient `service_unavailable` errors.

The ingress proxy also sanitizes Codex `/responses` and `/v1/responses` JSON requests before forwarding them to `copilot-api`. It strips `internal_chat_message_metadata_passthrough`, drops stale encrypted `reasoning` / `compaction` state items, and strips the optional `id` / `status` fields from echoed `custom_tool_call` items, matching known upstream issue workarounds for rejected Codex conversation state.

## Validate

```sh
./scripts/hardening.sh
./scripts/smoke.sh
./scripts/regression-encrypted-content.sh
./scripts/regression-internal-metadata.sh
./scripts/regression-custom-tool-call-id.sh
```

`hardening.sh` confirms only ingress publishes a loopback port and only `copilot-api` mounts auth state. `smoke.sh` confirms `/v1/models`, `/v1/responses`, and `/v1/messages` work through the local endpoint.
