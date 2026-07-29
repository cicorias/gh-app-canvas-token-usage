import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { rateCardPath } from "./paths.mjs";

const WILDCARD = "*";

const PROVIDER_RULES = [
    [/^claude/i, "Anthropic"],
    [/^(gpt|o[134]|text-|davinci)/i, "OpenAI"],
    [/^gemini/i, "Google"],
    [/^grok/i, "xAI"],
    [/^(mai|phi)/i, "Microsoft"],
    [/^(llama|meta)/i, "Meta"],
    [/^(mistral|mixtral|codestral)/i, "Mistral"],
    [/^(deepseek)/i, "DeepSeek"],
];

export function inferProvider(model) {
    if (!model) return "unknown";
    for (const [re, name] of PROVIDER_RULES) {
        if (re.test(model)) return name;
    }
    return "unknown";
}

export function normalizeEffort(effort) {
    if (effort === null || effort === undefined || effort === "") return WILDCARD;
    return String(effort).toLowerCase();
}

function emptyCard() {
    return {
        version: 1,
        currency: "USD",
        // Copilot bills in AI units; usage rows carry total_nano_aiu (1e-9 AIU).
        usdPerAiu: 0,
        // When true, cacheReadTokens/cacheWriteTokens are assumed to be already
        // counted inside inputTokens, so input cost is reduced by them.
        cacheTokensIncludedInInput: true,
        entries: [],
        updatedAt: new Date().toISOString(),
    };
}

function normalizeEntry(raw) {
    const num = (v) => {
        const n = Number(v);
        return Number.isFinite(n) ? n : 0;
    };
    return {
        id: raw.id || randomUUID(),
        provider: (raw.provider || WILDCARD).trim() || WILDCARD,
        model: (raw.model || WILDCARD).trim() || WILDCARD,
        effort: normalizeEffort(raw.effort),
        // All prices are USD per 1,000,000 tokens.
        input: num(raw.input),
        output: num(raw.output),
        cacheRead: num(raw.cacheRead),
        cacheWrite: num(raw.cacheWrite),
        // null/empty means reasoning tokens are assumed to be billed as output
        // tokens and are therefore not charged again.
        reasoning: raw.reasoning === null || raw.reasoning === undefined || raw.reasoning === "" ? null : num(raw.reasoning),
        notes: raw.notes ? String(raw.notes) : "",
    };
}

export function loadRateCard() {
    const path = rateCardPath();
    if (!existsSync(path)) return emptyCard();
    try {
        const parsed = JSON.parse(readFileSync(path, "utf8"));
        const card = { ...emptyCard(), ...parsed };
        card.entries = Array.isArray(parsed.entries) ? parsed.entries.map(normalizeEntry) : [];
        card.usdPerAiu = Number(card.usdPerAiu) || 0;
        card.cacheTokensIncludedInInput = Boolean(card.cacheTokensIncludedInInput);
        return card;
    } catch {
        return emptyCard();
    }
}

export function saveRateCard(card) {
    const next = { ...emptyCard(), ...card };
    next.entries = (Array.isArray(card.entries) ? card.entries : []).map(normalizeEntry);
    next.usdPerAiu = Number(card.usdPerAiu) || 0;
    next.cacheTokensIncludedInInput = Boolean(card.cacheTokensIncludedInInput);
    next.currency = card.currency || "USD";
    next.version = 1;
    next.updatedAt = new Date().toISOString();

    const path = rateCardPath();
    const tmp = `${path}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`, "utf8");
    renameSync(tmp, path);
    return next;
}

/**
 * Add a zero-priced placeholder row for every (provider, model, effort) combo
 * seen in usage data that has no matching rate. Prices are never invented.
 */
export function seedMissingEntries(card, combos) {
    const added = [];
    let working = { ...card, entries: [...card.entries] };
    for (const combo of combos) {
        if (matchRate(working, combo.provider, combo.model, combo.effort)) continue;
        const entry = normalizeEntry({
            provider: combo.provider,
            model: combo.model,
            effort: combo.effort,
            notes: "auto-added from observed usage — prices not set",
        });
        working.entries.push(entry);
        added.push(entry);
    }
    return { card: working, added };
}

function score(entry, provider, model, effort) {
    if (entry.model !== WILDCARD && entry.model !== model) return -1;
    if (entry.provider !== WILDCARD && entry.provider !== provider) return -1;
    if (entry.effort !== WILDCARD && entry.effort !== effort) return -1;
    let s = 0;
    if (entry.model !== WILDCARD) s += 4;
    if (entry.provider !== WILDCARD) s += 2;
    if (entry.effort !== WILDCARD) s += 1;
    return s;
}

export function matchRate(card, provider, model, effort) {
    const e = normalizeEffort(effort);
    let best = null;
    let bestScore = -1;
    for (const entry of card.entries) {
        const s = score(entry, provider, model, e);
        if (s > bestScore) {
            bestScore = s;
            best = entry;
        }
    }
    return bestScore >= 0 ? best : null;
}

export function isPriced(entry) {
    if (!entry) return false;
    return Boolean(entry.input || entry.output || entry.cacheRead || entry.cacheWrite || entry.reasoning);
}

const PER_MILLION = 1_000_000;

/**
 * Cost for a single usage record. Returns both the token-priced estimate and
 * the AIU-derived cost, because Copilot actually bills in AI units.
 */
export function costForRecord(card, rec) {
    const provider = rec.provider || inferProvider(rec.model);
    const entry = matchRate(card, provider, rec.model, rec.effort);
    const input = rec.inputTokens || 0;
    const output = rec.outputTokens || 0;
    const cacheRead = rec.cacheReadTokens || 0;
    const cacheWrite = rec.cacheWriteTokens || 0;
    const reasoning = rec.reasoningTokens || 0;

    let tokenCost = 0;
    if (entry) {
        const billableInput = card.cacheTokensIncludedInInput ? Math.max(0, input - cacheRead - cacheWrite) : input;
        tokenCost += (billableInput * entry.input) / PER_MILLION;
        tokenCost += (output * entry.output) / PER_MILLION;
        tokenCost += (cacheRead * entry.cacheRead) / PER_MILLION;
        tokenCost += (cacheWrite * entry.cacheWrite) / PER_MILLION;
        if (entry.reasoning !== null) {
            tokenCost += (reasoning * entry.reasoning) / PER_MILLION;
        }
    }

    const aiu = (rec.totalNanoAiu || 0) / 1e9;
    const aiuCost = aiu * (card.usdPerAiu || 0);

    return {
        rateEntryId: entry ? entry.id : null,
        priced: isPriced(entry),
        tokenCost,
        aiu,
        aiuCost,
    };
}
