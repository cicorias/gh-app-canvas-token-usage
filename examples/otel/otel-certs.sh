#!/usr/bin/env bash
#
# Create a local certificate authority and a TLS server certificate for an OTLP
# endpoint on localhost.
#
# Why this exists: GitHub Copilot CLI refuses to send OTLP over cleartext
# http://, and its exporter uses a Rust TLS stack that rejects a self-signed CA
# certificate presented as the server's own leaf. So "just make a self-signed
# cert" does not work — you need a real two-certificate chain, which is what
# this script produces.
#
# Rerunnable: existing certificates are kept unless they are invalid, expiring,
# or missing a requested hostname. Use --force to regenerate regardless.

set -euo pipefail

DEFAULT_DIR="${OTEL_CERT_DIR:-./.otel-certs}"
CERT_DIR="$DEFAULT_DIR"
DAYS=825
RENEW_WINDOW_DAYS=30
FORCE=0
RELAX_KEY_PERMS=0
HOSTS=()
CN="localhost"

usage() {
    cat <<'EOF'
Usage: otel-certs.sh [options]

Creates, in the certificate directory:
  ca.crt / ca.key            the local certificate authority
  otlp.crt / otlp.key        the server certificate and its key
  otlp-fullchain.crt         leaf + CA, what the OTLP server should present

Options:
  -d, --cert-dir DIR    Where to write the certificates.
                        Default: $OTEL_CERT_DIR, else ./.otel-certs
                        Relative paths are resolved against the current directory.
  -H, --host NAME       Extra hostname to include as a SAN. Repeatable.
                        "localhost" is always included.
      --cn NAME         Subject common name for the leaf. Default: localhost
      --days N          Validity in days. Default: 825
  -f, --force           Regenerate even if usable certificates already exist.
      --relax-key-perms Make the server key world-readable (0644) instead of
                        0600. Needed only when a native Linux container runtime
                        runs the server as a different uid and cannot read the
                        key. Docker Desktop does not need this.
  -h, --help            Show this help.

Examples:
  otel-certs.sh
  otel-certs.sh --cert-dir ./certs --host host.docker.internal
  otel-certs.sh --force
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d | --cert-dir)
            [ $# -ge 2 ] || die "$1 requires a value"
            CERT_DIR="$2"
            shift 2
            ;;
        -H | --host)
            [ $# -ge 2 ] || die "$1 requires a value"
            HOSTS+=("$2")
            shift 2
            ;;
        --cn)
            [ $# -ge 2 ] || die "$1 requires a value"
            CN="$2"
            shift 2
            ;;
        --days)
            [ $# -ge 2 ] || die "$1 requires a value"
            DAYS="$2"
            shift 2
            ;;
        -f | --force)
            FORCE=1
            shift
            ;;
        --relax-key-perms)
            RELAX_KEY_PERMS=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"

# Always cover localhost; keep the caller's order otherwise, without duplicates.
ALL_HOSTS=("localhost")
for h in ${HOSTS[@]+"${HOSTS[@]}"}; do
    seen=0
    for existing in "${ALL_HOSTS[@]}"; do
        [ "$existing" = "$h" ] && seen=1 && break
    done
    [ "$seen" -eq 0 ] && ALL_HOSTS+=("$h")
done

mkdir -p "$CERT_DIR"
CERT_DIR="$(cd "$CERT_DIR" && pwd)"

CA_CRT="$CERT_DIR/ca.crt"
CA_KEY="$CERT_DIR/ca.key"
LEAF_CRT="$CERT_DIR/otlp.crt"
LEAF_KEY="$CERT_DIR/otlp.key"
FULLCHAIN="$CERT_DIR/otlp-fullchain.crt"

san_entries() {
    local out=""
    for h in "${ALL_HOSTS[@]}"; do
        out="${out}DNS:${h},"
    done
    echo "${out}IP:127.0.0.1,IP:::1"
}

# Returns 0 when the existing material is complete, chains correctly, is not
# about to expire, and already covers every requested hostname.
certs_are_usable() {
    local f
    for f in "$CA_CRT" "$CA_KEY" "$LEAF_CRT" "$LEAF_KEY" "$FULLCHAIN"; do
        [ -s "$f" ] || return 1
    done
    openssl verify -CAfile "$CA_CRT" "$LEAF_CRT" >/dev/null 2>&1 || return 1
    openssl x509 -checkend $((RENEW_WINDOW_DAYS * 86400)) -noout -in "$LEAF_CRT" >/dev/null 2>&1 || return 1
    openssl x509 -checkend $((RENEW_WINDOW_DAYS * 86400)) -noout -in "$CA_CRT" >/dev/null 2>&1 || return 1

    # `openssl x509 -ext` is unavailable on the LibreSSL that ships with macOS,
    # so read the extensions out of the text dump instead.
    local text
    text="$(openssl x509 -in "$LEAF_CRT" -noout -text 2>/dev/null)"

    # OpenSSL 3 clients refuse to build a chain without these, so certificates
    # generated before they were added must be replaced.
    case "$text" in
        *"Authority Key Identifier"*) ;;
        *) return 1 ;;
    esac

    local san
    san="$(printf '%s\n' "$text" | awk '/X509v3 Subject Alternative Name/{getline; print; exit}')"
    local h
    for h in "${ALL_HOSTS[@]}"; do
        case "$san" in
            *"DNS:$h,"* | *"DNS:$h "* | *"DNS:$h") ;;
            *) return 1 ;;
        esac
    done
    return 0
}

print_result() {
    local action="$1"
    local not_after
    not_after="$(openssl x509 -in "$LEAF_CRT" -noout -enddate | cut -d= -f2-)"
    cat <<EOF

$action
  directory   $CERT_DIR
  hostnames   ${ALL_HOSTS[*]}
  expires     $not_after

Server (for example the Aspire dashboard) should present:
  certificate $FULLCHAIN
  private key $LEAF_KEY

Copilot CLI should trust:
  OTEL_EXPORTER_OTLP_CERTIFICATE=$CA_CRT
EOF
}

if [ "$FORCE" -eq 0 ] && certs_are_usable; then
    print_result "Existing certificates are still usable; nothing to do (use --force to regenerate)."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. The certificate authority. Copilot is pointed at this, and only this.
openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
    -keyout "$WORK/ca.key" -out "$WORK/ca.crt" \
    -subj "/CN=Local OTLP development CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" 2>/dev/null

# 2. The server certificate, signed by that CA. It must be a leaf — CA:FALSE
#    with serverAuth — or the Rust TLS stack in the exporter rejects it.
openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout "$WORK/otlp.key" -out "$WORK/otlp.csr" \
    -subj "/CN=$CN" 2>/dev/null

cat >"$WORK/leaf.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$(san_entries)
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF

openssl x509 -req -in "$WORK/otlp.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/otlp.crt" -days "$DAYS" -sha256 \
    -extfile "$WORK/leaf.ext" 2>/dev/null

cat "$WORK/otlp.crt" "$WORK/ca.crt" >"$WORK/otlp-fullchain.crt"

openssl verify -CAfile "$WORK/ca.crt" "$WORK/otlp.crt" >/dev/null ||
    die "generated certificate failed verification"

# Only replace the real files once everything above succeeded.
install -m 0644 "$WORK/ca.crt" "$CA_CRT"
install -m 0600 "$WORK/ca.key" "$CA_KEY"
install -m 0644 "$WORK/otlp.crt" "$LEAF_CRT"
install -m 0644 "$WORK/otlp-fullchain.crt" "$FULLCHAIN"
if [ "$RELAX_KEY_PERMS" -eq 1 ]; then
    install -m 0644 "$WORK/otlp.key" "$LEAF_KEY"
else
    install -m 0600 "$WORK/otlp.key" "$LEAF_KEY"
fi

print_result "Generated a new certificate authority and server certificate."
