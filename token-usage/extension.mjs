// Extension: token-usage
//
// Per-session token usage and spend tracking with an editable rate card.
//
// Data sources, in order of authority:
//   1. ~/.copilot/session-store.db -> assistant_usage_events (full history, read-only)
//   2. the live `assistant.usage` session event, persisted to our own JSONL
//      because that event is ephemeral and never lands in the session event log
//   3. optional OpenTelemetry file-exporter JSONL, for tool/trace level detail
//
// See otel.mjs for why the OTLP collector path is reported but not ingested.

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { joinSession, createCanvas, CanvasError } from "@github/copilot-sdk/extension";

import { buildReport, sessionDetail } from "./aggregate.mjs";
import { loadRateCard, saveRateCard, seedMissingEntries, normalizeEffort, inferProvider } from "./ratecard.mjs";
import { recordLiveUsage } from "./live.mjs";
import { otelStatus, summarizeOtel, loadSettings, saveSettings } from "./otel.mjs";
import {
    VAR_INFO,
    defaultFilePath,
    loadOtelConfig,
    saveOtelConfig,
    loginEnvStatus,
    applyToLoginEnv,
    removeFromLoginEnv,
} from "./otelenv.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const UI_PATH = join(HERE, "ui.html");

const servers = new Map(); // instanceId -> { server, url }
const sseClients = new Set();

function broadcast(event, payload) {
    const frame = `event: ${event}\ndata: ${JSON.stringify(payload || {})}\n\n`;
    for (const res of sseClients) {
        try {
            res.write(frame);
        } catch {
            sseClients.delete(res);
        }
    }
}

function sendJson(res, status, body) {
    res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
    res.end(JSON.stringify(body));
}

async function readBody(req) {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    if (chunks.length === 0) return {};
    try {
        return JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
        return {};
    }
}

function otelPayload() {
    const config = loadOtelConfig();
    return {
        status: otelStatus(),
        settings: loadSettings(),
        spans: summarizeOtel(),
        config,
        env: loginEnvStatus(config),
        vars: VAR_INFO,
        defaultFilePath: defaultFilePath(),
    };
}

function seedFromUsage() {
    const report = buildReport();
    const { card, added } = seedMissingEntries(loadRateCard(), report.combos);
    const saved = saveRateCard(card);
    return { card: saved, added: added.length };
}

function upsertRate(input) {
    const card = loadRateCard();
    const provider = String(input.provider || inferProvider(input.model)).trim();
    const model = String(input.model || "*").trim();
    const effort = normalizeEffort(input.effort);
    const idx = card.entries.findIndex((e) => e.provider === provider && e.model === model && e.effort === effort);
    const next = { ...(idx >= 0 ? card.entries[idx] : {}), provider, model, effort };
    for (const field of ["input", "output", "cacheRead", "cacheWrite", "reasoning", "notes"]) {
        if (input[field] !== undefined) next[field] = input[field];
    }
    if (idx >= 0) card.entries[idx] = next;
    else card.entries.push(next);
    if (input.usdPerAiu !== undefined) card.usdPerAiu = Number(input.usdPerAiu) || 0;
    return saveRateCard(card);
}

async function handleRequest(req, res) {
    const url = new URL(req.url, "http://127.0.0.1");
    const path = url.pathname;

    if (req.method === "GET" && (path === "/" || path === "/index.html")) {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
        res.end(readFileSync(UI_PATH, "utf8"));
        return;
    }

    if (req.method === "GET" && path === "/events") {
        res.writeHead(200, {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-store",
            Connection: "keep-alive",
        });
        res.write(": connected\n\n");
        sseClients.add(res);
        const keepAlive = setInterval(() => {
            try {
                res.write(": ping\n\n");
            } catch {
                /* closed */
            }
        }, 25000);
        req.on("close", () => {
            clearInterval(keepAlive);
            sseClients.delete(res);
        });
        return;
    }

    if (req.method === "GET" && path === "/api/report") {
        sendJson(res, 200, buildReport());
        return;
    }

    if (req.method === "GET" && path.startsWith("/api/session/")) {
        sendJson(res, 200, sessionDetail(decodeURIComponent(path.slice("/api/session/".length))));
        return;
    }

    if (req.method === "GET" && path === "/api/otel") {
        sendJson(res, 200, otelPayload());
        return;
    }

    if (req.method === "POST" && path === "/api/ratecard") {
        const saved = saveRateCard(await readBody(req));
        broadcast("usage", { reason: "ratecard" });
        sendJson(res, 200, saved);
        return;
    }

    if (req.method === "POST" && path === "/api/ratecard/seed") {
        const result = seedFromUsage();
        broadcast("usage", { reason: "ratecard-seed" });
        sendJson(res, 200, result);
        return;
    }

    if (req.method === "POST" && path === "/api/settings") {
        sendJson(res, 200, saveSettings(await readBody(req)));
        return;
    }

    // Saving records intent only. Nothing reaches the environment until
    // /api/otel/apply, because the two have very different blast radius.
    if (req.method === "POST" && path === "/api/otel/config") {
        saveOtelConfig(await readBody(req));
        sendJson(res, 200, otelPayload());
        return;
    }

    if (req.method === "POST" && path === "/api/otel/apply") {
        const config = saveOtelConfig(await readBody(req));
        const result = applyToLoginEnv(config);
        sendJson(res, 200, { result, ...otelPayload() });
        return;
    }

    if (req.method === "POST" && path === "/api/otel/remove") {
        const result = removeFromLoginEnv();
        saveOtelConfig({ ...loadOtelConfig(), enabled: false });
        sendJson(res, 200, { result, ...otelPayload() });
        return;
    }

    sendJson(res, 404, { error: "not found" });
}

async function startServer() {
    const server = createServer((req, res) => {
        handleRequest(req, res).catch((err) => {
            try {
                sendJson(res, 500, { error: String(err && err.message ? err.message : err) });
            } catch {
                /* response already started */
            }
        });
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    return { server, url: `http://127.0.0.1:${port}/` };
}

const canvas = createCanvas({
    id: "token-usage",
    displayName: "Token usage & spend",
    description:
        "Track token usage, AI units and estimated cost per session, and edit the rate card by model, effort and provider.",
    inputSchema: {
        type: "object",
        properties: {
            sessionId: { type: "string", description: "Session to focus on open. Defaults to all sessions." },
            tab: {
                type: "string",
                enum: ["sessions", "models", "rates", "otel", "settings"],
                description: "Initial tab.",
            },
        },
        additionalProperties: false,
    },
    actions: [
        {
            name: "get_summary",
            description: "Return aggregate token usage, AI units and estimated cost across all recorded sessions.",
            handler: () => {
                const report = buildReport();
                return {
                    generatedAt: report.generatedAt,
                    sources: report.sources,
                    totals: report.totals,
                    unpricedCalls: report.unpricedCalls,
                    usdPerAiu: report.card.usdPerAiu,
                    models: report.models,
                    sessions: report.sessions.slice(0, 25),
                };
            },
        },
        {
            name: "get_session_usage",
            description: "Return the per-call usage and cost breakdown for one session. Defaults to the current session.",
            inputSchema: {
                type: "object",
                properties: { sessionId: { type: "string" } },
                additionalProperties: false,
            },
            handler: (ctx) => {
                const id = (ctx.input && ctx.input.sessionId) || currentSessionId;
                if (!id) throw new CanvasError("no_session", "No session id available");
                return sessionDetail(id);
            },
        },
        {
            name: "set_rate",
            description:
                "Create or update one rate card entry, matched on provider + model + effort. Prices are USD per 1,000,000 tokens.",
            inputSchema: {
                type: "object",
                properties: {
                    provider: { type: "string" },
                    model: { type: "string" },
                    effort: { type: "string" },
                    input: { type: "number" },
                    output: { type: "number" },
                    cacheRead: { type: "number" },
                    cacheWrite: { type: "number" },
                    reasoning: { type: ["number", "null"] },
                    usdPerAiu: { type: "number" },
                    notes: { type: "string" },
                },
                required: ["model"],
                additionalProperties: false,
            },
            handler: (ctx) => {
                const card = upsertRate(ctx.input || {});
                broadcast("usage", { reason: "ratecard" });
                return card;
            },
        },
        {
            name: "seed_rate_card",
            description: "Add a zero-priced rate card row for every provider/model/effort seen in usage but not yet priced.",
            handler: () => {
                const result = seedFromUsage();
                broadcast("usage", { reason: "ratecard-seed" });
                return { added: result.added, entries: result.card.entries.length };
            },
        },
        {
            name: "otel_status",
            description:
                "Report whether OpenTelemetry export is enabled for this process, the relevant environment variables, and any ingested span summary.",
            handler: () => otelPayload(),
        },
        {
            name: "configure_otel",
            description:
                "Turn Copilot's OpenTelemetry export on or off for future launches. Writes the variables into the macOS login environment so Finder/Dock launches inherit them; the current session is unaffected and the app must be restarted. Does not change how token usage is recorded.",
            inputSchema: {
                type: "object",
                properties: {
                    enabled: { type: "boolean", description: "Master switch. Defaults to off." },
                    exporter: { type: "string", enum: ["file", "otlp"], description: "Write JSON-lines to a file, or send OTLP to a collector." },
                    filePath: { type: "string", description: "File exporter path. Defaults to the extension's artifacts directory." },
                    endpoint: { type: "string", description: "OTLP collector endpoint." },
                    captureContent: { type: "boolean", description: "Capture full prompt and response content. Off by default." },
                    apply: { type: "boolean", description: "Apply to the login environment immediately. Defaults to true." },
                },
                additionalProperties: false,
            },
            handler: (ctx) => {
                const input = ctx.input || {};
                const config = loadOtelConfig();
                if (input.enabled !== undefined) config.enabled = Boolean(input.enabled);
                if (input.exporter) config.exporter = input.exporter;
                if (input.filePath) config.vars.COPILOT_OTEL_FILE_EXPORTER_PATH = input.filePath;
                if (input.endpoint) config.vars.OTEL_EXPORTER_OTLP_ENDPOINT = input.endpoint;
                if (input.captureContent !== undefined) {
                    if (input.captureContent) config.vars.OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true";
                    else delete config.vars.OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT;
                }
                const saved = saveOtelConfig(config);
                const result = input.apply === false ? null : applyToLoginEnv(saved);
                broadcast("otel", { reason: "configure" });
                return { config: saved, result, env: loginEnvStatus(saved) };
            },
        },
        {
            name: "refresh",
            description: "Re-read the usage stores and push an update to any open canvas.",
            handler: () => {
                broadcast("usage", { reason: "manual" });
                return { ok: true };
            },
        },
    ],
    open: async (ctx) => {
        let entry = servers.get(ctx.instanceId);
        if (!entry) {
            entry = await startServer();
            servers.set(ctx.instanceId, entry);
        }
        const report = buildReport();
        const params = new URLSearchParams();
        if (ctx.input && ctx.input.sessionId) params.set("sessionId", ctx.input.sessionId);
        if (ctx.input && ctx.input.tab) params.set("tab", ctx.input.tab);
        const query = params.toString();
        return {
            title: "Token usage & spend",
            status: `${report.sessions.length} sessions · ${report.totals.calls} calls`,
            url: query ? `${entry.url}?${query}` : entry.url,
        };
    },
    onClose: async (ctx) => {
        const entry = servers.get(ctx.instanceId);
        if (entry) {
            servers.delete(ctx.instanceId);
            await new Promise((resolve) => entry.server.close(() => resolve()));
        }
    },
});

const session = await joinSession({ canvases: [canvas] });
const currentSessionId = session.sessionId;

// `assistant.usage` is emitted per model call and marked ephemeral, so persist
// our own copy before it is dropped.
session.on("assistant.usage", (event) => {
    try {
        recordLiveUsage(currentSessionId, event.data || {}, event.timestamp);
        broadcast("usage", { reason: "assistant.usage" });
    } catch {
        /* never break the turn on telemetry capture */
    }
});
