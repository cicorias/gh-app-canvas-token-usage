import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { sessionStoreDbPath } from "./paths.mjs";
import { inferProvider, normalizeEffort } from "./ratecard.mjs";

/**
 * Reader for the CLI's local session store. The schema is internal to the
 * Copilot app, so every access is defensive: missing db, missing table, and
 * missing columns all degrade to "no rows" rather than throwing.
 */

function openDb() {
    const path = sessionStoreDbPath();
    if (!existsSync(path)) return null;
    try {
        return new DatabaseSync(path, { readOnly: true });
    } catch {
        return null;
    }
}

function tableColumns(db, table) {
    try {
        return new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((r) => r.name));
    } catch {
        return new Set();
    }
}

export function readUsageRows() {
    const db = openDb();
    if (!db) return { available: false, reason: "session-store.db not found", rows: [] };
    try {
        const cols = tableColumns(db, "assistant_usage_events");
        if (cols.size === 0) {
            return { available: false, reason: "assistant_usage_events table not present", rows: [] };
        }
        const pick = (name, fallback = "NULL") => (cols.has(name) ? name : `${fallback} AS ${name}`);
        const sql = `
            SELECT
                id,
                session_id,
                ${pick("turn_index")},
                ${pick("agent_id")},
                model,
                ${pick("input_tokens")},
                ${pick("output_tokens")},
                ${pick("cache_read_tokens")},
                ${pick("cache_write_tokens")},
                ${pick("reasoning_tokens")},
                ${pick("total_nano_aiu")},
                ${pick("request_multiplier")},
                ${pick("duration_ms")},
                ${pick("initiator")},
                ${pick("api_endpoint")},
                ${pick("reasoning_effort")},
                ${pick("finish_reason")},
                ${pick("created_at")}
            FROM assistant_usage_events
            ORDER BY id ASC
        `;
        const rows = db.prepare(sql).all().map((r) => ({
            source: "db",
            id: `db:${r.id}`,
            sessionId: r.session_id,
            turnIndex: r.turn_index,
            agentId: r.agent_id || null,
            model: r.model,
            provider: inferProvider(r.model),
            effort: normalizeEffort(r.reasoning_effort),
            inputTokens: r.input_tokens || 0,
            outputTokens: r.output_tokens || 0,
            cacheReadTokens: r.cache_read_tokens || 0,
            cacheWriteTokens: r.cache_write_tokens || 0,
            reasoningTokens: r.reasoning_tokens || 0,
            totalNanoAiu: r.total_nano_aiu || 0,
            requestMultiplier: r.request_multiplier ?? null,
            durationMs: r.duration_ms || 0,
            initiator: r.initiator || null,
            apiEndpoint: r.api_endpoint || null,
            finishReason: r.finish_reason || null,
            timestamp: r.created_at || null,
        }));
        return { available: true, reason: null, rows };
    } catch (err) {
        return { available: false, reason: String(err && err.message ? err.message : err), rows: [] };
    } finally {
        try {
            db.close();
        } catch {
            /* ignore */
        }
    }
}

export function readSessionMeta() {
    const db = openDb();
    if (!db) return new Map();
    try {
        const cols = tableColumns(db, "sessions");
        if (cols.size === 0) return new Map();
        const want = ["id", "cwd", "repository", "branch", "summary", "created_at", "updated_at"];
        const select = want.filter((c) => cols.has(c));
        if (!select.includes("id")) return new Map();
        const rows = db.prepare(`SELECT ${select.join(", ")} FROM sessions`).all();
        const map = new Map();
        for (const r of rows) {
            map.set(r.id, {
                id: r.id,
                cwd: r.cwd || null,
                repository: r.repository || null,
                branch: r.branch || null,
                summary: r.summary || null,
                createdAt: r.created_at || null,
                updatedAt: r.updated_at || null,
            });
        }
        return map;
    } catch {
        return new Map();
    } finally {
        try {
            db.close();
        } catch {
            /* ignore */
        }
    }
}
