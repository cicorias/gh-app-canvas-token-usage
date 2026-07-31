# Local OpenTelemetry for Copilot CLI

Scripts to stand up a local [.NET Aspire dashboard](https://aspire.dev/dashboard/standalone/)
that Copilot CLI will actually export traces to, including the TLS certificates it
requires.

📝 Background and walkthrough:
[**Metering the Agent: a Copilot CLI canvas extension for token usage**](https://www.cicoria.com/metering-the-agent-a-copilot-cli-canvas-extension-for-token-usage/)

## Why this is not just `docker run`

Copilot CLI **refuses to export over cleartext `http://`**. It does not fail loudly —
it disables the exporter and writes a warning to `$COPILOT_HOME/logs`, which is
suppressed entirely at `--log-level error`. So the Aspire quickstart's
`http://localhost:4318` looks like it is working while dropping every span.

That means the dashboard needs a real TLS certificate, which means a certificate
authority Copilot can be told to trust. These scripts generate both, correctly, and
are safe to re-run.

Two details that are easy to get wrong and cost real debugging time:

- **A single self-signed certificate does not work.** Copilot's TLS stack rejects a CA
  certificate presented as the server's own leaf; you get only
  `[rust:otel] HTTP export failed: network error`. A two-certificate chain (CA signs
  leaf) is required.
- **The leaf needs an Authority Key Identifier.** Copilot tolerates its absence; OpenSSL 3
  clients — including anything using Python's `ssl` — reject the chain with
  `certificate verify failed: Missing Authority Key Identifier`.

## Quick start

With [mise](https://mise.jdx.dev):

```sh
mise run otel:up        # certificates + dashboard, prints the settings and login URL
mise run otel:verify    # sends one real span over TLS and confirms it was accepted
mise run otel:down      # stop
```

Or call the scripts directly — they have no dependency on mise:

```sh
./examples/otel/aspire-up.sh
```

```powershell
./examples/otel/aspire-up.ps1
```

Then set these in Copilot (the extension's **Settings** tab has a button that fills
them in), and **restart Copilot** — the OTLP variables are read once at process start,
so a running session can never be switched on:

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_CERTIFICATE=<cert-dir>/ca.crt
```

`NODE_EXTRA_CA_CERTS` has no effect here; the transport is native Rust, not Node.

## Where do the certificates go?

Anywhere you like. The default is `./.otel-certs` relative to the current directory
(and it is gitignored). `/certs` appears in these scripts only as the *container-side*
mount target of `-v host:container` — it is arbitrary and never touches your machine.

```sh
./examples/otel/otel-certs.sh --cert-dir ~/.otel/certs
OTEL_CERT_DIR=~/.otel/certs ./examples/otel/aspire-up.sh
```

The only real constraints: Docker needs an absolute host path (the scripts resolve
it for you), and the container has to be able to *read* the key.

## Scripts

| Script | Purpose |
| --- | --- |
| `otel-certs.sh` / `.ps1` | Generate the CA and server certificate. Idempotent. |
| `aspire-up.sh` / `.ps1` | Generate certs if needed, start the dashboard, wait for the TLS listener, print settings. |
| `aspire-down.sh` / `.ps1` | Stop it. `--purge-certs` also deletes the certificates. |
| `aspire-login-url.sh` / `.ps1` | Re-print the dashboard login URL (the token is logged only once, at startup). |
| `verify-otlp.py` | Send one real span end to end. |

Common options (bash `--kebab-case`, PowerShell `-PascalCase`):

- `--cert-dir` / `-CertDir` — where certificates live. Also `$OTEL_CERT_DIR`.
- `--force` / `-Force` — regenerate certificates, replace a running container.
- `--host` / `-CertHost` — extra SAN entries, repeatable. Add
  `host.docker.internal` if something inside a container needs to reach the dashboard.
- `--relax-key-perms` / `-RelaxKeyPerms` — see below.

### Re-run behaviour

`otel-certs.sh` regenerates only when something is actually wrong: files missing, the
chain fails to verify, expiry within 30 days, no Authority Key Identifier, or a
requested hostname is not in the SAN. Otherwise it does nothing. `--force` overrides.

Generation happens in a temporary directory and is installed into place at the end, so
an interrupted run never leaves a half-written key behind.

### `verify-otlp.py`

A [PEP 723](https://peps.python.org/pep-0723/) script — dependencies are declared inline
and [uv](https://docs.astral.sh/uv/) resolves them into a throwaway environment:

```sh
uv run examples/otel/verify-otlp.py
```

It exists because the OpenTelemetry SDK swallows export failures by default; the script
captures the SDK's warning log to tell success from silence. It is stricter than Copilot
about certificates, which is a feature: it caught the missing Authority Key Identifier
described above.

### `--relax-key-perms`

Private keys are written `0600`. Docker Desktop ignores host file ownership, so this is
fine; native Linux Docker and rootless Podman do not, and the dashboard will fail to
read the key. `aspire-up.sh` detects that failure and tells you to re-run with
`--force --relax-key-perms`, which widens the key to `0644` — acceptable for a
throwaway local development certificate, not for anything else.

## Notes

- macOS ships **LibreSSL**, not OpenSSL. `openssl x509 -ext` does not exist there, so
  these scripts stick to portable invocations.
- The dashboard's OTLP endpoint is unauthenticated (`AuthMode` defaults to `Unsecured`);
  TLS here is about Copilot's export policy, not access control.
- Container internals: UI `18888`, OTLP/gRPC `18889`, OTLP/HTTP `18890`. Copilot only
  speaks OTLP over HTTP, so `18890` is the one published (to `4318` by default).
