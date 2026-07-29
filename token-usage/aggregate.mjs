import { readUsageRows, readSessionMeta } from "./usagedb.mjs";
import { readLiveUsage } from "./live.mjs";
import { loadRateCard, costForRecord, inferProvider, normalizeEffort } from "./ratecard.mjs";

/**
 * Natural key used to reconcile the two sources. The live JSONL has no row id
 * that maps to session-store.db, so we match on the value tuple that uniquely
 * identifies a model call in practice.
 */
function dedupeKey(rec) {
    return [
        rec.sessionId,
        rec.model,
        rec.inputTokens || 0,
        rec.outputTokens || 0,
        rec.cacheReadTokens || 0,
        rec.cacheWriteTokens || 0,
        rec.reasoningTokens || 0,
        rec.totalNanoAiu || 0,
    ].join("|");
}

function emptyTotals() {
    return {
        calls: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        totalTokens: 0,
        aiu: 0,
        tokenCost: 0,
        aiuCost: 0,
        durationMs: 0,
    };
}

function accumulate(target, rec) {
    target.calls += 1;
    target.inputTokens += rec.inputTokens || 0;
    target.outputTokens += rec.outputTokens || 0;
    target.cacheReadTokens += rec.cacheReadTokens || 0;
    target.cacheWriteTokens += rec.cacheWriteTokens || 0;
    target.reasoningTokens += rec.reasoningTokens || 0;
    target.totalTokens += (rec.inputTokens || 0) + (rec.outputTokens || 0);
    target.aiu += rec.cost.aiu;
    target.tokenCost += rec.cost.tokenCost;
    target.aiuCost += rec.cost.aiuCost;
    target.durationMs += rec.durationMs || 0;
}

export function buildReport() {
    const card = loadRateCard();
    const db = readUsageRows();
    const live = readLiveUsage();
    const meta = readSessionMeta();

    const merged = new Map();
    for (const rec of db.rows) merged.set(dedupeKey(rec), rec);
    for (const rec of live) {
        const key = dedupeKey(rec);
        if (!merged.has(key)) merged.set(key, rec);
    }

    const records = [...merged.values()].map((rec) => {
        const provider = rec.provider || inferProvider(rec.model);
        const effort = normalizeEffort(rec.effort);
        const normalized = { ...rec, provider, effort };
        return { ...normalized, cost: costForRecord(card, normalized) };
    });
    records.sort((a, b) => String(a.timestamp || "").localeCompare(String(b.timestamp || "")));

    const sessions = new Map();
    const models = new Map();
    const totals = emptyTotals();
    const combos = new Map();

    for (const rec of records) {
        accumulate(totals, rec);

        const sid = rec.sessionId || "(unknown)";
        let s = sessions.get(sid);
        if (!s) {
            const m = meta.get(sid) || {};
            s = {
                sessionId: sid,
                repository: m.repository || null,
                branch: m.branch || null,
                cwd: m.cwd || null,
                summary: m.summary || null,
                createdAt: m.createdAt || null,
                firstAt: null,
                lastAt: null,
                models: new Set(),
                unpriced: 0,
                ...emptyTotals(),
            };
            sessions.set(sid, s);
        }
        accumulate(s, rec);
        s.models.add(rec.model);
        if (!rec.cost.priced) s.unpriced += 1;
        if (rec.timestamp) {
            if (!s.firstAt || rec.timestamp < s.firstAt) s.firstAt = rec.timestamp;
            if (!s.lastAt || rec.timestamp > s.lastAt) s.lastAt = rec.timestamp;
        }

        const mkey = `${rec.provider}|${rec.model}|${rec.effort}`;
        let mm = models.get(mkey);
        if (!mm) {
            mm = {
                key: mkey,
                provider: rec.provider,
                model: rec.model,
                effort: rec.effort,
                priced: rec.cost.priced,
                sessions: new Set(),
                ...emptyTotals(),
            };
            models.set(mkey, mm);
        }
        accumulate(mm, rec);
        mm.sessions.add(sid);
        mm.priced = mm.priced || rec.cost.priced;

        if (!combos.has(mkey)) {
            combos.set(mkey, { provider: rec.provider, model: rec.model, effort: rec.effort });
        }
    }

    const sessionList = [...sessions.values()]
        .map((s) => ({ ...s, models: [...s.models].sort() }))
        .sort((a, b) => String(b.lastAt || "").localeCompare(String(a.lastAt || "")));

    const modelList = [...models.values()]
        .map((m) => ({ ...m, sessionCount: m.sessions.size, sessions: undefined }))
        .sort((a, b) => b.totalTokens - a.totalTokens);

    return {
        generatedAt: new Date().toISOString(),
        sources: {
            db: { available: db.available, reason: db.reason, rows: db.rows.length },
            live: { available: true, reason: null, rows: live.length },
            merged: records.length,
        },
        card,
        totals,
        sessions: sessionList,
        models: modelList,
        combos: [...combos.values()],
        unpricedCalls: records.filter((r) => !r.cost.priced).length,
    };
}

export function sessionDetail(sessionId) {
    const card = loadRateCard();
    const db = readUsageRows();
    const live = readLiveUsage();

    const merged = new Map();
    for (const rec of db.rows) {
        if (rec.sessionId === sessionId) merged.set(dedupeKey(rec), rec);
    }
    for (const rec of live) {
        if (rec.sessionId !== sessionId) continue;
        const key = dedupeKey(rec);
        if (!merged.has(key)) merged.set(key, rec);
    }

    const records = [...merged.values()]
        .map((rec) => {
            const provider = rec.provider || inferProvider(rec.model);
            const effort = normalizeEffort(rec.effort);
            const normalized = { ...rec, provider, effort };
            return { ...normalized, cost: costForRecord(card, normalized) };
        })
        .sort((a, b) => String(a.timestamp || "").localeCompare(String(b.timestamp || "")));

    const totals = emptyTotals();
    for (const rec of records) accumulate(totals, rec);

    const meta = readSessionMeta().get(sessionId) || null;
    return { sessionId, meta, totals, records };
}
