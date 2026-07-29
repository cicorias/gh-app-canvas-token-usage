# Token usage &amp; spend — a Copilot CLI canvas extension

Track **token usage, AI units (AIU) and estimated cost per session** inside GitHub Copilot,
with a rate card you can edit and persist by provider, model and reasoning effort.

Repo: [`cicorias/gh-app-canvas-token-usage`](https://github.com/cicorias/gh-app-canvas-token-usage) ·
Extension source: [`token-usage/`](token-usage/)

---

## Quick start

**1. Install** (pick one — the folder-URL route is easiest):

Ask Copilot:

> Install the extension from `https://github.com/cicorias/gh-app-canvas-token-usage/tree/main/token-usage`

or from a clone:

```sh
git clone https://github.com/cicorias/gh-app-canvas-token-usage.git
cd gh-app-canvas-token-usage
./install.sh
```

**2. Reload** — ask Copilot to reload extensions, or restart the CLI.

**3. Open the canvas** — ask Copilot:

> Open the token usage canvas

**4. Set your prices** — go to the **Rate card** tab, click **Add models seen in usage**, then
enter your USD-per-AIU rate and per-million-token prices. Until you do, the token and cost
columns read zero by design: no list prices are shipped or guessed on your behalf.

That's it. Usage from your existing sessions appears immediately — there is nothing to
configure and no telemetry to enable.

---

## What you get

| Tab | Contents |
| --- | --- |
| **Sessions** | Every session with recorded usage — repo, branch, summary, calls, input/output/cache tokens, AIU, cost from AIU, cost from your rate card. Click a row for the per-model-call breakdown. |
| **Models** | Rollup by provider × model × reasoning effort. |
| **Rate card** | Editable prices per 1M tokens (input, output, cache read, cache write, reasoning) plus a global USD-per-AIU rate. Saved to disk, `*` wildcards supported. |
| **Telemetry** | Live OpenTelemetry status, the exact env-var snippets to enable it, and ingestion of the OTel file exporter's output. |

You can also drive it from chat — the canvas exposes `get_summary`, `get_session_usage`,
`set_rate`, `seed_rate_card`, `otel_status` and `refresh` to the agent, so
*"what has this session cost me so far?"* just works.

---

## Requirements

- GitHub Copilot CLI with canvas support
- **Node 22+** — the extension uses the built-in `node:sqlite` module

There are **no dependencies to install**. `@github/copilot-sdk` is resolved by the CLI, so do
not add a `package.json` or `node_modules`.

---

## Installation in detail

### Choose a scope

| Scope | Destination | Who gets it |
| --- | --- | --- |
| **User** | `$COPILOT_HOME/extensions/token-usage/` (default `~/.copilot/extensions/`) | you, in every project |
| **Project** | `<repo>/.github/extensions/token-usage/` | anyone working in that repo, with no install step |
| **Session** | `$COPILOT_HOME/session-state/<sessionId>/extensions/token-usage/` | the current session only |

> A **project**-scope copy shadows a **user**-scope copy of the same name — the user one is
> dropped at discovery time. Don't install both.

### Option 1 — from this repository (recommended)

Ask Copilot to install it, or use the `install_extension` tool, with this folder URL:

```
https://github.com/cicorias/gh-app-canvas-token-usage/tree/main/token-usage
```

You'll be asked which scope to install into. This is the best route for other people:
versioned, reviewable, and easy to update by re-running the install.

### Option 2 — install script

```sh
git clone https://github.com/cicorias/gh-app-canvas-token-usage.git
cd gh-app-canvas-token-usage

./install.sh                            # user scope (default)
./install.sh --project /path/to/repo    # into that repo's .github/extensions/
./install.sh --session <session-id>      # current session only
```

The script warns if Node is older than 22 and prints the destination it used.

### Option 3 — vendor it into your team's repo

```sh
mkdir -p /path/to/repo/.github/extensions
cp -R token-usage /path/to/repo/.github/extensions/
```

Commit it, and everyone working in that repo gets the canvas with **no install step at all**.
Discovery only scans immediate subdirectories of `.github/extensions/`, so keep the folder
exactly one level deep.

### Option 4 — private gist

Run **Share extension as gist…** from the Copilot command palette (or use the
`share_extension` tool), then **Install extension from gist…** on the other machine. Good for
syncing your own machines; use options 1–3 for teams, since a gist isn't reviewable or
versioned.

### Manual copy

Copy the `token-usage/` folder to the destination for your chosen scope. The entry point must
be named exactly `extension.mjs` and sit at the top of that folder.

### Verify

After reloading, ask Copilot to list extensions — `token-usage` should show as **ready**. If
it shows **failed**, ask it to inspect the extension; the output includes the log file path
and a tail of the log.

---

## Updating

Re-run whichever install route you used, then reload extensions. Your rate card and captured
usage are stored outside the extension folder (see below), so they survive updates and
reinstalls.

## Uninstalling

Delete the installed folder for your scope, e.g. `rm -rf ~/.copilot/extensions/token-usage`,
and reload. To also remove your data, delete
`~/.copilot/extensions/token-usage/artifacts/`.

---

## Where your data lives

Everything user-owned is written to `$COPILOT_HOME/extensions/token-usage/artifacts/`,
**outside any repository**, regardless of the scope the extension is installed at — so a
project-scope install never commits pricing data.

| File | Contents |
| --- | --- |
| `rate-card.json` | Rate card entries, USD-per-AIU, cache-accounting flag |
| `live-usage.jsonl` | Captured `assistant.usage` events |
| `settings.json` | Path to an OTel file-exporter JSONL to ingest |

Nothing is sent anywhere. The canvas is served by a loopback HTTP server on an ephemeral
port and reads only local files.

---

## How usage is measured

1. **`$COPILOT_HOME/session-store.db` → `assistant_usage_events`**, read-only via
   `node:sqlite`. Gives full retroactive history across every session and project with zero
   configuration. This schema is internal to the Copilot app, so access is defensive: a
   missing database, table or column yields no rows rather than an error.
2. **The live `assistant.usage` session event.** It is `ephemeral: true` and never reaches the
   session event log, so the extension persists its own normalized copy. This keeps the
   current session accurate before the app flushes rows to the store, and survives a schema
   change in that internal store.
3. **OpenTelemetry file exporter (optional)** for span and tool-execution detail.

The first two are merged and deduplicated on the tuple that identifies a model call, then
pushed to the open canvas over Server-Sent Events.

### Two cost numbers, on purpose

Copilot bills in **AI units**, not raw tokens, and usage rows carry `total_nano_aiu`:

- **Cost from AIU** — `AIU × your USD-per-AIU rate`. Tracks how you are actually billed.
- **Cost from rate card** — a modelled token cost from your per-1M prices. Useful for
  comparing providers or for BYOK endpoints.

> **Cache tokens.** In observed data, `inputTokens` already *includes* cache-read and
> cache-write tokens, so the rate card defaults `cacheTokensIncludedInInput` to on and
> subtracts them from billable input. Turn it off if your provider reports them separately.

---

## Optional: OpenTelemetry

OTel is configured by environment variables read at **CLI startup**, so it cannot be switched
on for a session that is already running — set these and relaunch. The Telemetry tab shows
current status and hands you these snippets.

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

Point the Telemetry tab at that JSONL file to see spans and tool-execution timings. An OTLP
collector endpoint is reported but not ingested: that would require a receiver process
outliving every session, for data the local stores already provide.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Extension not discovered | The entry file must be named `extension.mjs`, one level deep inside `extensions/` |
| Extension shows **failed** | Ask Copilot to inspect it — the log path and tail are the primary debugging surface |
| No history, only live rows | Node is older than 22, so `node:sqlite` is unavailable; the Sessions tab notes when the store can't be read |
| Cost columns are zero | Set your USD-per-AIU and per-model prices on the **Rate card** tab |
| Canvas is blank after an update | Re-open the canvas to reload the iframe against the new port |

---

## Layout

```
.
├── install.sh                   user / project / session installer
└── token-usage/
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
