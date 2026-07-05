# Copilot API Local Gateway

This stack runs a local `copilot-api` gateway on `http://127.0.0.1:44141`.

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

## Validate

```sh
./scripts/hardening.sh
./scripts/smoke.sh
```

`hardening.sh` confirms only ingress publishes a loopback port and only `copilot-api` mounts auth state. `smoke.sh` confirms `/v1/models`, `/v1/responses`, and `/v1/messages` work through the local endpoint.
