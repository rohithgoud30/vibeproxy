# Cursor Setup Guide (Codex Proxy for Cursor)

This guide explains how to use VibeProxy with Cursor through the built-in **Codex Proxy for Cursor** — an authenticated public relay that lets Cursor reach your local VibeProxy.

## Overview

Cursor routes custom-API-key requests through Cursor's backend, so it **cannot** reach `http://localhost:8317` directly. The Codex Proxy for Cursor solves this natively:

```
Cursor → Cloudflare quick tunnel (HTTPS) → relay :8319 (API-key auth) → VibeProxy :8317
```

- **Relay server** (port 8319, loopback only): rejects any request without your API key, then forwards to the local proxy — all providers and models on 8317 work through it.
- **Cloudflare quick tunnel**: run by the `cloudflared` binary **bundled inside the app** (`Contents/Resources/cloudflared`) — nothing to install, and the app never uses a system-installed cloudflared.
- **Model aliases**: `-extra` variants force maximum reasoning effort (see below).

## Prerequisites

- VibeProxy installed and running
- A Cursor plan that allows custom OpenAI API keys

## Setup

### 1. Turn on the relay

Menu bar → **Turn On Cursor Proxy**. After a few seconds the tunnel comes up and the base URL is **copied to your clipboard automatically** (you'll also get a notification).

### 2. Configure Cursor

In Cursor → Settings → Models → OpenAI API Key:

- **Override OpenAI Base URL**: paste the copied URL, e.g. `https://xxxx-xxxx.trycloudflare.com/v1`
- **OpenAI API Key**: menu bar → **Copy API Key**, paste it

### 3. Pick a model

Use any model your VibeProxy serves, e.g. `gpt-5.5`, or an alias:

| Alias in Cursor | Upstream model | Effect |
|---|---|---|
| `gpt-5.5-extra` | `gpt-5.5` | `reasoning_effort: xhigh` |
| `gpt-5.4-extra` | `gpt-5.4` | `reasoning_effort: xhigh` |
| `gpt-5.4-mini-extra` | `gpt-5.4-mini` | `reasoning_effort: xhigh` |
| `<model>-fast` | `<model>` | strips Cursor's `fast` suffix and uses the model default effort |
| `<model>-<effort>-fast` | `<model>` | strips Cursor's `fast` suffix and sets `reasoning_effort` |

Supported effort aliases follow each model's API support:

| Model | Supported effort aliases |
|---|---|
| `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-5.2`, other `gpt-5.x` frontier/mini/nano models | `none`, `low`, `medium`, `high`, `xhigh` |
| `gpt-5.5-pro`, `gpt-5.4-pro`, `gpt-5.2-pro` | `medium`, `high`, `xhigh` |
| `gpt-5.3-codex`, `gpt-5.2-codex`, `gpt-5.1-codex-max` | `low`, `medium`, `high`, `xhigh` |
| `gpt-5.1-codex`, `gpt-5.1-codex-mini`, `gpt-5-codex` | `low`, `medium`, `high` |
| `gpt-5.1` | `none`, `low`, `medium`, `high` |
| `gpt-5` | `minimal`, `low`, `medium`, `high` |
| `gpt-5.3-codex-spark` | `fast` suffix only |

Clients that can set `reasoning_effort` themselves don't need aliases — the relay passes the field through unchanged for non-alias models. `fast` is not sent to OpenAI as an API parameter; it is a Cursor/client suffix that the relay strips before forwarding.

## Menu reference

| Item | What it does |
|---|---|
| Turn On/Off Cursor Proxy | Starts/stops the relay + tunnel. State persists across restarts. |
| Copy Cursor URL | Copies the current base URL (`…/v1`). |
| Copy API Key | Copies the relay API key. |
| Regenerate API Key | Generates a new key and copies it — update Cursor afterwards. |

## Important notes

- **The URL changes on every relay start** (quick tunnels are ephemeral). The new URL is auto-copied; just re-paste it into Cursor. The API key never changes unless you regenerate it.
- **Keep the API key secret.** Anyone with the URL *and* key can use your subscriptions. Without the key, the relay returns 401.
- Cursor custom keys only cover standard chat models — Cursor-native features (Tab, Apply, etc.) still use Cursor's own models.

## Updating the bundled cloudflared

The bundled binary lives at `src/Sources/Resources/cloudflared` (arm64, same pattern as `cli-proxy-api-plus`). To bump it:

```bash
# 1. Download the latest official release (check the version tag)
gh release download --repo cloudflare/cloudflared --pattern "cloudflared-darwin-arm64.tgz" -D /tmp/cf
tar -xzf /tmp/cf/cloudflared-darwin-arm64.tgz -C /tmp/cf

# 2. Replace the bundled binary
cp /tmp/cf/cloudflared src/Sources/Resources/cloudflared
chmod 755 src/Sources/Resources/cloudflared
./src/Sources/Resources/cloudflared --version   # verify

# 3. Rebuild and reinstall
make install
```

`create-app-bundle.sh` copies it into `Contents/Resources/` and signs it automatically when a Developer ID is available (required for notarized releases).

Current bundled version: **2026.6.0**

## Troubleshooting

- **"Cursor Proxy Failed" notification** — the tunnel couldn't start. Check `Console.app` for `[TunnelManager]` / `[CursorRelay]` logs.
- **401 in Cursor** — the API key in Cursor doesn't match. Menu bar → Copy API Key and re-paste.
- **Old URL stopped working** — the relay restarted; copy the new URL from the menu.
- **Models missing in Cursor** — make sure the relevant provider is connected in VibeProxy Settings; the relay exposes whatever `:8317/v1/models` returns (plus aliases).
