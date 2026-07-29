import { existsSync, readFileSync, writeFileSync, statSync, renameSync } from "node:fs";
import { join } from "node:path";
import { artifactsDir } from "./paths.mjs";

/**
 * OpenTelemetry integration.
 *
 * Copilot CLI activates OTel when COPILOT_OTEL_ENABLED=true, or when
 * OTEL_EXPORTER_OTLP_ENDPOINT or COPILOT_OTEL_FILE_EXPORTER_PATH is set. All of
 * those must be present in the environment *before* the CLI starts, so this
 * canvas can only report status and hand back the exact snippet to use — it
 * cannot enable OTel for the session it is running inside.
 *
 * We only ingest the file exporter (JSON-lines). An OTLP collector would mean
 * running a receiver that outlives every session, for data the local stores
 * already give us.
 */

const ENV_KEYS = [
    "COPILOT_OTEL_ENABLED",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "COPILOT_OTEL_EXPORTER_TYPE",
    "COPILOT_OTEL_FILE_EXPORTER_PATH",
    "COPILOT_OTEL_SOURCE_NAME",
    "OTEL_SERVICE_NAME",
    "OTEL_RESOURCE_ATTRIBUTES",
    "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",
];

function settingsPath() {
    return join(artifactsDir(), "settings.json");
}

export function loadSettings() {
    try {
        if (!existsSync(settingsPath())) return { otelFilePath: "" };
        const parsed = JSON.parse(readFileSync(settingsPath(), "utf8"));
        return { otelFilePath: parsed.otelFilePath || "" };
    } catch {
        return { otelFilePath: "" };
    }
}

export function saveSettings(next) {
    const value = { otelFilePath: next && next.otelFilePath ? String(next.otelFilePath) : "" };
    const tmp = `${settingsPath()}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    renameSync(tmp, settingsPath());
    return value;
}

export function resolveOtelFilePath() {
    const settings = loadSettings();
    return settings.otelFilePath || process.env.COPILOT_OTEL_FILE_EXPORTER_PATH || "";
}

export function otelStatus() {
    const env = {};
    for (const key of ENV_KEYS) {
        if (process.env[key] !== undefined) env[key] = process.env[key];
    }
    const active =
        String(process.env.COPILOT_OTEL_ENABLED || "").toLowerCase() === "true" ||
        Boolean(process.env.OTEL_EXPORTER_OTLP_ENDPOINT) ||
        Boolean(process.env.COPILOT_OTEL_FILE_EXPORTER_PATH);

    const filePath = resolveOtelFilePath();
    let file = null;
    if (filePath) {
        try {
            const st = statSync(filePath);
            file = { path: filePath, exists: true, bytes: st.size, modifiedAt: st.mtime.toISOString() };
        } catch {
            file = { path: filePath, exists: false, bytes: 0, modifiedAt: null };
        }
    }

    return {
        active,
        env,
        file,
        // Note: cleartext http:// endpoints are rejected by the otlp-http
        // exporter for anything but the local default, so the snippet uses the
        // documented local collector form.
        snippets: {
            collector: [
                "COPILOT_OTEL_ENABLED=true",
                "OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318",
                "OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf",
                "OTEL_SERVICE_NAME=github-copilot",
            ].join("\n"),
            file: [
                `COPILOT_OTEL_FILE_EXPORTER_PATH=${filePath || "$HOME/.copilot/extensions/token-usage/artifacts/otel.jsonl"}`,
                "OTEL_SERVICE_NAME=github-copilot",
            ].join("\n"),
        },
    };
}

function attrValue(v) {
    if (v === null || v === undefined) return null;
    if (typeof v !== "object") return v;
    if ("stringValue" in v) return v.stringValue;
    if ("intValue" in v) return Number(v.intValue);
    if ("doubleValue" in v) return Number(v.doubleValue);
    if ("boolValue" in v) return v.boolValue;
    if ("arrayValue" in v) return (v.arrayValue.values || []).map(attrValue);
    return null;
}

function normalizeAttributes(attrs) {
    const out = {};
    if (!attrs) return out;
    if (Array.isArray(attrs)) {
        for (const a of attrs) {
            if (a && a.key !== undefined) out[a.key] = attrValue(a.value);
        }
        return out;
    }
    for (const [k, v] of Object.entries(attrs)) out[k] = attrValue(v);
    return out;
}

function collectSpans(node, out) {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) {
        for (const item of node) collectSpans(item, out);
        return;
    }
    if (Array.isArray(node.spans)) {
        for (const span of node.spans) {
            if (span && typeof span === "object") out.push(span);
        }
    }
    for (const key of ["resourceSpans", "scopeSpans", "instrumentationLibrarySpans", "resource_spans", "scope_spans"]) {
        if (node[key]) collectSpans(node[key], out);
    }
}

/**
 * Parse the OTel file exporter's JSON-lines output into a span summary. Kept
 * tolerant of both OTLP wire shapes (attribute arrays and plain objects) since
 * the exact serialization is not part of a stable contract.
 */
export function readOtelSpans(limitBytes = 8 * 1024 * 1024) {
    const path = resolveOtelFilePath();
    if (!path || !existsSync(path)) {
        return { available: false, reason: path ? "file not found" : "no file exporter path configured", spans: [] };
    }
    let text = "";
    try {
        const st = statSync(path);
        if (st.size > limitBytes) {
            const buf = readFileSync(path);
            text = buf.subarray(buf.length - limitBytes).toString("utf8");
            const nl = text.indexOf("\n");
            if (nl >= 0) text = text.slice(nl + 1);
        } else {
            text = readFileSync(path, "utf8");
        }
    } catch (err) {
        return { available: false, reason: String(err && err.message ? err.message : err), spans: [] };
    }

    const raw = [];
    for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
            collectSpans(JSON.parse(trimmed), raw);
        } catch {
            /* skip partial lines */
        }
    }

    const spans = raw.map((s) => {
        const attrs = normalizeAttributes(s.attributes);
        const startNs = Number(s.startTimeUnixNano || s.start_time_unix_nano || 0);
        const endNs = Number(s.endTimeUnixNano || s.end_time_unix_nano || 0);
        return {
            name: s.name || "",
            traceId: s.traceId || s.trace_id || null,
            spanId: s.spanId || s.span_id || null,
            durationMs: endNs > startNs ? (endNs - startNs) / 1e6 : 0,
            startedAt: startNs ? new Date(startNs / 1e6).toISOString() : null,
            model: attrs["gen_ai.response.model"] || attrs["gen_ai.request.model"] || null,
            tool: attrs["gen_ai.tool.name"] || attrs["github.copilot.tool.name"] || null,
            inputTokens: Number(attrs["gen_ai.usage.input_tokens"] || 0),
            outputTokens: Number(attrs["gen_ai.usage.output_tokens"] || 0),
            attrs,
        };
    });

    return { available: true, reason: null, spans };
}

export function summarizeOtel() {
    const { available, reason, spans } = readOtelSpans();
    if (!available) return { available, reason, spanCount: 0, byName: [], tools: [], tokens: { input: 0, output: 0 } };

    const byName = new Map();
    const tools = new Map();
    let input = 0;
    let output = 0;
    for (const s of spans) {
        const nameKey = s.name.split(" ")[0] || s.name;
        const n = byName.get(nameKey) || { name: nameKey, count: 0, totalMs: 0 };
        n.count += 1;
        n.totalMs += s.durationMs;
        byName.set(nameKey, n);

        if (s.tool) {
            const t = tools.get(s.tool) || { tool: s.tool, count: 0, totalMs: 0 };
            t.count += 1;
            t.totalMs += s.durationMs;
            tools.set(s.tool, t);
        }
        input += s.inputTokens;
        output += s.outputTokens;
    }

    return {
        available: true,
        reason: null,
        spanCount: spans.length,
        byName: [...byName.values()].sort((a, b) => b.count - a.count),
        tools: [...tools.values()].sort((a, b) => b.count - a.count).slice(0, 50),
        tokens: { input, output },
    };
}
