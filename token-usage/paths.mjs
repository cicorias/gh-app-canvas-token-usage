import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync } from "node:fs";

export const EXTENSION_NAME = "token-usage";

export function copilotHome() {
    return process.env.COPILOT_HOME || join(homedir(), ".copilot");
}

export function artifactsDir() {
    const dir = join(copilotHome(), "extensions", EXTENSION_NAME, "artifacts");
    mkdirSync(dir, { recursive: true });
    return dir;
}

export function rateCardPath() {
    return join(artifactsDir(), "rate-card.json");
}

export function liveUsagePath() {
    return join(artifactsDir(), "live-usage.jsonl");
}

export function sessionStoreDbPath() {
    return join(copilotHome(), "session-store.db");
}
