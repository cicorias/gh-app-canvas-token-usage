# gh-app-canvas-token-usage

Source repository for **Token usage &amp; spend**, a GitHub Copilot CLI canvas extension that
tracks token usage, AI units and estimated cost per session, with an editable rate card by
provider, model and reasoning effort.

The extension itself lives in [`token-usage/`](token-usage/) — see
[its README](token-usage/README.md) for what it does and how it works.

## Install

Pick a scope first:

| Scope | Destination | Who gets it |
| --- | --- | --- |
| **User** | `$COPILOT_HOME/extensions/token-usage/` (default `~/.copilot/extensions/`) | you, in every project |
| **Project** | `<repo>/.github/extensions/token-usage/` | anyone working in that repo, no install step |
| **Session** | `$COPILOT_HOME/session-state/<sessionId>/extensions/token-usage/` | the current session only |

A project-scope copy shadows a user-scope copy with the same name, so don't install both.

### Option 1 — from this repository (recommended for a team)

Ask Copilot to install it, or use the `install_extension` tool with this folder URL:

```
https://github.com/<owner>/gh-app-canvas-token-usage/tree/main/token-usage
```

### Option 2 — install script

```sh
git clone https://github.com/<owner>/gh-app-canvas-token-usage.git
cd gh-app-canvas-token-usage
./install.sh              # user scope (default)
./install.sh --project /path/to/repo   # into that repo's .github/extensions/
```

### Option 3 — vendor it into your repo

Copy `token-usage/` to `.github/extensions/token-usage/` and commit it. Everyone working in
that repo gets the canvas with no install step at all.

### Option 4 — private gist

Run **Share extension as gist…** from the Copilot command palette (or the `share_extension`
tool) to publish it, then **Install extension from gist…** on the other machine. Good for
personal use across your own machines; use options 1–3 for teams.

After installing, reload extensions (or restart the CLI) and open the
**Token usage &amp; spend** canvas.

## Requirements

- GitHub Copilot CLI with canvas support
- Node 22+ (the extension uses the built-in `node:sqlite` module)

There are no dependencies to install — `@github/copilot-sdk` is resolved by the CLI. Do not
add a `package.json` or `node_modules` for it.

## Data and privacy

All pricing and captured usage is written to
`$COPILOT_HOME/extensions/token-usage/artifacts/`, outside any repository, regardless of the
scope the extension is installed at. Nothing is sent anywhere: the canvas is served from a
loopback HTTP server on an ephemeral port and reads only local files.
