import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { liveUsagePath } from "./paths.mjs";
import { inferProvider, normalizeEffort } from "./ratecard.mjs";

/**
 * The `assistant.usage` session event is ephemeral (never written to the
 * session event log), so we persist a normalized copy ourselves. This keeps
 * the current session accurate even before the app flushes rows into
 * session-store.db, and survives a schema change in that internal store.
 */

export function recordLiveUsage(sessionId, data, timestamp) {
    const rec = {
        source: "live",
        sessionId,
        turnIndex: null,
        agentId: data.agentId || null,
        model: data.model,
        provider: inferProvider(data.model),
        effort: normalizeEffort(data.reasoningEffort),
        inputTokens: data.inputTokens || 0,
        outputTokens: data.outputTokens || 0,
        cacheReadTokens: data.cacheReadTokens || 0,
        cacheWriteTokens: data.cacheWriteTokens || 0,
        reasoningTokens: data.reasoningTokens || 0,
        totalNanoAiu: data.copilotUsage ? data.copilotUsage.totalNanoAiu || 0 : 0,
        requestMultiplier: typeof data.cost === "number" ? data.cost : null,
        durationMs: data.duration || 0,
        initiator: data.initiator || null,
        apiEndpoint: data.apiEndpoint || null,
        finishReason: data.finishReason || null,
        apiCallId: data.apiCallId || null,
        timestamp: timestamp || new Date().toISOString(),
    };
    try {
        appendFileSync(liveUsagePath(), `${JSON.stringify(rec)}\n`, "utf8");
    } catch {
        /* never let telemetry capture break the session */
    }
    return rec;
}

export function readLiveUsage() {
    const path = liveUsagePath();
    if (!existsSync(path)) return [];
    let text = "";
    try {
        text = readFileSync(path, "utf8");
    } catch {
        return [];
    }
    const out = [];
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i += 1) {
        const line = lines[i].trim();
        if (!line) continue;
        try {
            const rec = JSON.parse(line);
            rec.source = "live";
            rec.id = `live:${i}`;
            out.push(rec);
        } catch {
            /* skip torn/partial lines from concurrent appends */
        }
    }
    return out;
}
