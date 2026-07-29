# Token usage &amp; spend

A GitHub Copilot CLI **canvas extension** that tracks token usage, AI units (AIU) and
estimated cost per session, with an editable rate card by provider, model and reasoning
effort.

![scope: user, project or session](https://img.shields.io/badge/scope-user%20%7C%20project%20%7C%20session-blue)

## What it shows

| Tab | Contents |
| --- | --- |
| **Sessions** | Every session with recorded usage — repo, branch, summary, calls, input/output/cache tokens, AIU, cost from AIU, cost from the rate card. Click a row for the per-model-call breakdown. |
| **Models** | Rollup by provider × model × reasoning effort. |
| **Rate card** | Editable prices per 1M tokens (input, output, cache read, cache write, reasoning) plus a global USD-per-AIU rate. Persisted to disk. |
| **Telemetry** | Live OpenTelemetry status, the exact env-var snippets to enable it, and ingestion of the OTel file exporter's JSON-lines output. |

## Where the data comes from

1. **`$COPILOT_HOME/session-store.db` → `assistant_usage_events`** (read-only, via `node:sqlite`).
   Full retroactive history across every session and project, with zero configuration.
   This schema is internal to the Copilot app, so every access degrades gracefully:
   a missing database, table or column yields no rows rather than an error.
2. **The live `assistant.usage` session event.** It is marked `ephemeral: true` and never
   reaches the session event log, so the extension persists its own normalized copy to
   `artifacts/live-usage.jsonl`. This keeps the current session accurate before the app
   flushes rows to the store, and survives a schema change in that internal store.
3. **OpenTelemetry file exporter (optional).** If `COPILOT_OTEL_FILE_EXPORTER_PATH` is set —
   or a path is configured in the Telemetry tab — the JSON-lines output is parsed into a
   span and tool-execution summary.

The first two sources are merged and deduplicated on the value tuple that identifies a
model call, then pushed to the open canvas over Server-Sent Events.

An OTLP collector (`OTEL_EXPORTER_OTLP_ENDPOINT`) is deliberately **not** ingested: it would
require a receiver process outliving every session, for data the local stores already
provide. The Telemetry tab still reports collector configuration and hands back the snippet.

## Costs: two numbers, on purpose

Copilot bills in **AI units**, not raw tokens. Usage rows carry `total_nano_aiu`, so the
canvas shows:

- **Cost from AIU** — `AIU × your USD-per-AIU rate`. This tracks how you are actually billed.
- **Cost from rate card** — a modelled token cost using your per-1M prices. Useful for
  comparing providers or for BYOK endpoints.

No list prices ship with the extension; nothing is invented on your behalf. Use
**Add models seen in usage** on the Rate card tab to create zero-priced rows for every
provider/model/effort combination observed, then fill in your own numbers.

> **Note on cache tokens.** In observed data, `inputTokens` already *includes* cache-read and
> cache-write tokens. The rate card therefore defaults `cacheTokensIncludedInInput` to on,
> which subtracts them from the billable input count so they are not charged twice. Turn it
> off if your provider reports them separately.

## Installation

See the [repository README](https://github.com/cicorias/gh-app-canvas-token-usage#installation-in-detail)
for the full walkthrough. In short, the extension is a single directory of ES modules with no
dependencies to install — `@github/copilot-sdk` is resolved by the CLI, and `node:sqlite` is
built into Node 22+.

### From this repository

Ask the agent to install it, or use the `install_extension` tool with this folder URL:

```
https://github.com/cicorias/gh-app-canvas-token-usage/tree/main/token-usage
```

### With the install script

```sh
git clone https://github.com/cicorias/gh-app-canvas-token-usage.git
cd gh-app-canvas-token-usage
./install.sh                            # user scope
./install.sh --project /path/to/repo    # project scope
./install.sh --session <session-id>      # session scope
```

### From a gist

Run **Install extension from gist…** from the Copilot command palette, or ask the agent to
install it. Choose the scope when prompted.

### Manually

Copy the `token-usage/` folder to one of:

| Scope | Destination | Who gets it |
| --- | --- | --- |
| **User** | `$COPILOT_HOME/extensions/token-usage/` (default `~/.copilot/extensions/`) | you, in every project |
| **Project** | `<repo>/.github/extensions/token-usage/` | anyone working in that repo, no install step |
| **Session** | `$COPILOT_HOME/session-state/<sessionId>/extensions/token-usage/` | the current session only |

Then reload extensions (or restart the CLI) and open the **Token usage & spend** canvas.

A project-scope copy shadows a user-scope copy with the same name — the user one is dropped
at discovery time, so don't install both.

## Storage

Everything user-owned lives in `$COPILOT_HOME/extensions/token-usage/artifacts/`, outside
any repo:

| File | Contents |
| --- | --- |
| `rate-card.json` | Rate card entries, USD-per-AIU, cache-accounting flag |
| `live-usage.jsonl` | Captured `assistant.usage` events |
| `settings.json` | Path to an OTel file-exporter JSONL to ingest |

This path is used regardless of which scope the extension itself is installed at, so a
project-scope install never writes pricing data into the repo.

## Agent actions

The canvas exposes these to the agent via `invoke_canvas_action`:

| Action | Purpose |
| --- | --- |
| `get_summary` | Aggregate usage, AIU and cost across all sessions |
| `get_session_usage` | Per-call breakdown for one session (defaults to the current one) |
| `set_rate` | Create or update a single rate card entry |
| `seed_rate_card` | Add zero-priced rows for every unpriced model seen |
| `otel_status` | OTel environment, snippets and ingested span summary |
| `refresh` | Re-read the stores and push an update to the open canvas |

## Enabling OpenTelemetry

OTel is configured by environment variables read at CLI startup, so it cannot be switched on
for a session that is already running — set these and relaunch.

```sh
# Local collector
COPILOT_OTEL_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=github-copilot
```

```sh
# File exporter — no collector required, and ingestible by this canvas
COPILOT_OTEL_FILE_EXPORTER_PATH="$HOME/.copilot/extensions/token-usage/artifacts/otel.jsonl"
OTEL_SERVICE_NAME=github-copilot
```

## Requirements

- GitHub Copilot CLI with canvas support
- Node 22+ (for the built-in `node:sqlite` module)

## Layout

```
token-usage/
├── copilot-extension.json   manifest (required for gist install)
├── extension.mjs            wiring: joinSession, canvas, HTTP server, SSE
├── aggregate.mjs            merge + dedupe sources, build rollups
├── ratecard.mjs             rate card load/save/match and cost computation
├── usagedb.mjs              read-only session-store.db reader
├── live.mjs                 assistant.usage capture and JSONL store
├── otel.mjs                 OTel env detection, settings, JSONL ingest
├── paths.mjs                COPILOT_HOME and artifact path resolution
└── ui.html                  canvas renderer
```
