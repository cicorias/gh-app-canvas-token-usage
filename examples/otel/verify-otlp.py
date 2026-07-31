#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "opentelemetry-sdk>=1.27",
#   "opentelemetry-exporter-otlp-proto-http>=1.27",
# ]
# ///
"""Prove that a TLS OTLP endpoint really accepts telemetry.

Copilot CLI fails quietly here: if TLS, trust, or the protocol is wrong it
disables export and only mentions it in its own process log. This script does
the same thing Copilot does — emit a real span over OTLP/HTTP protobuf with a
custom CA — but reports the outcome loudly, so the setup can be validated
without starting an agent session and reading logs afterwards.

Run it through uv so the OpenTelemetry SDK is resolved on demand:

    uv run examples/otel/verify-otlp.py
    uv run examples/otel/verify-otlp.py --endpoint https://localhost:4318 \
        --certificate ./.otel-certs/ca.crt
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

DEFAULT_ENDPOINT = "https://localhost:4318"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send one test span to an OTLP/HTTP endpoint and report whether it was accepted.",
    )
    parser.add_argument(
        "--endpoint",
        default=os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", DEFAULT_ENDPOINT),
        help=f"OTLP base endpoint. Default: $OTEL_EXPORTER_OTLP_ENDPOINT, else {DEFAULT_ENDPOINT}",
    )
    parser.add_argument(
        "--certificate",
        default=os.environ.get("OTEL_EXPORTER_OTLP_CERTIFICATE"),
        help="PEM file with the CA to trust. Default: $OTEL_EXPORTER_OTLP_CERTIFICATE, "
        "else ./.otel-certs/ca.crt when it exists.",
    )
    parser.add_argument(
        "--service-name",
        default="otlp-verify",
        help="Service name to report. Default: otlp-verify",
    )
    parser.add_argument(
        "--cert-dir",
        default=os.environ.get("OTEL_CERT_DIR", "./.otel-certs"),
        help="Directory to look in for ca.crt. Default: $OTEL_CERT_DIR, else ./.otel-certs",
    )
    return parser.parse_args()


def resolve_certificate(args: argparse.Namespace) -> str | None:
    if args.certificate:
        return args.certificate
    candidate = Path(args.cert_dir) / "ca.crt"
    return str(candidate) if candidate.is_file() else None


def main() -> int:
    args = parse_args()

    if args.endpoint.startswith("http://"):
        print(
            f"error: {args.endpoint} is cleartext http.\n"
            "Copilot disables OTLP export rather than send it unencrypted, so this\n"
            "endpoint would silently receive nothing. Use an https:// endpoint.",
            file=sys.stderr,
        )
        return 2

    certificate = resolve_certificate(args)
    if certificate and not Path(certificate).is_file():
        print(f"error: certificate not found: {certificate}", file=sys.stderr)
        return 2

    # Import after the argument checks so --help stays fast.
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor

    # The SDK swallows export errors and logs them, so capture the log to decide
    # success rather than trusting the absence of an exception.
    failures: list[str] = []

    class _Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            if record.levelno >= logging.WARNING:
                failures.append(record.getMessage())

    handler = _Capture()
    for name in ("opentelemetry.exporter.otlp", "opentelemetry.sdk"):
        logging.getLogger(name).addHandler(handler)
    logging.getLogger().addHandler(handler)

    print(f"endpoint    {args.endpoint}", flush=True)
    print("protocol    http/protobuf", flush=True)
    print(f"certificate {certificate or '(system trust store)'}", flush=True)
    print(f"service     {args.service_name}", flush=True)
    print("\nsending one span...", flush=True)

    exporter = OTLPSpanExporter(
        endpoint=f"{args.endpoint.rstrip('/')}/v1/traces",
        certificate_file=certificate,
        timeout=10,
    )
    provider = TracerProvider(resource=Resource.create({"service.name": args.service_name}))
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    tracer = trace.get_tracer(__name__)
    with tracer.start_as_current_span("verify_otlp") as span:
        span.set_attribute("verify.source", "examples/otel/verify-otlp.py")

    provider.shutdown()

    if failures:
        # The SDK retries, so the same cause shows up several times.
        unique: list[str] = []
        for message in failures:
            if message not in unique:
                unique.append(message)
        print("\nFAILED — the endpoint did not accept the span:", file=sys.stderr)
        for message in unique[:3]:
            print(f"  {message}", file=sys.stderr)
        print(
            "\nCommon causes:\n"
            "  - the CA in --certificate is not the one that signed the server certificate\n"
            "  - the server presents its CA certificate instead of a leaf signed by it\n"
            "  - the hostname is missing from the certificate's subjectAltName\n"
            "  - nothing is listening on that port",
            file=sys.stderr,
        )
        return 1

    print("\nOK — the span was accepted. It should now appear in the dashboard.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
