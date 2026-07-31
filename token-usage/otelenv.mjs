import { existsSync, readFileSync, writeFileSync, renameSync, unlinkSync, chmodSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { artifactsDir } from "./paths.mjs";

/**
 * Desired-state management for the Copilot CLI's OpenTelemetry environment.
 *
 * The CLI reads OTel configuration from environment variables *at startup*, so
 * nothing here can switch telemetry on for the session this code runs inside.
 * What it can do is put the variables somewhere the next launch will pick them
 * up — including launches from Finder or the Dock, which never source a shell
 * profile.
 *
 * On macOS that place is the per-user launchd domain (`launchctl setenv`),
 * which LaunchServices hands to every GUI-launched app. Those values are lost
 * on logout, so we also install a LaunchAgent that replays them at login.
 *
 * This is deliberately independent of token accounting: usage totals come from
 * session-store.db and live-usage.jsonl whether or not OTel is ever enabled.
 */

export const LAUNCH_AGENT_LABEL = "com.github.copilot.token-usage.otel-env";

const DEFAULT_FILE_NAME = "otel.jsonl";

/**
 * Every variable this extension is willing to manage. Sourced from
 * `copilot help monitoring`. `hint` is shown verbatim in the settings UI, so it
 * should describe what the CLI does with the value, not what the field is.
 */
export const VAR_INFO = [
    {
        key: "COPILOT_OTEL_ENABLED",
        label: "Enable OpenTelemetry",
        hint: 'Explicitly turns OTel on. Defaults to "false". Set automatically while the checkbox above is ticked.',
        managed: true,
    },
    {
        key: "COPILOT_OTEL_FILE_EXPORTER_PATH",
        label: "File exporter path",
        hint: "Writes every span and metric to this file as JSON-lines. Setting it also auto-enables OTel and auto-selects the file exporter. No collector required.",
        mode: "file",
        placeholder: "$HOME/.copilot/extensions/token-usage/artifacts/otel.jsonl",
    },
    {
        key: "OTEL_EXPORTER_OTLP_ENDPOINT",
        label: "OTLP endpoint",
        hint: "Collector URL, e.g. https://collector.example.com:4318. Setting it auto-enables OTel.",
        mode: "otlp",
        placeholder: "http://localhost:4318",
    },
    {
        key: "OTEL_EXPORTER_OTLP_PROTOCOL",
        label: "OTLP protocol",
        hint: 'How the otlp-http exporter encodes payloads: "http/json" (CLI default) or "http/protobuf". "grpc" is not supported and falls back with a warning.',
        mode: "otlp",
        choices: ["", "http/json", "http/protobuf"],
    },
    {
        key: "OTEL_EXPORTER_OTLP_HEADERS",
        label: "OTLP headers",
        hint: 'Auth headers for the collector, comma-separated, e.g. "Authorization=Bearer <token>". Stored on disk in a file only you can read — prefer a short-lived token.',
        mode: "otlp",
        secret: true,
        placeholder: "Authorization=Bearer ...",
    },
    {
        key: "OTEL_EXPORTER_OTLP_CERTIFICATE",
        label: "CA certificate",
        hint: "PEM file with extra CA certificate(s) to trust for an https:// collector, e.g. a corporate CA. Merged with the OS trust store. Ignored by the file exporter.",
        mode: "otlp",
        advanced: true,
        placeholder: "/etc/otel/ca.pem",
    },
    {
        key: "OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE",
        label: "Client certificate (mTLS)",
        hint: "Client certificate PEM for mutual TLS. Must be set together with the client key, and only applies to an https:// endpoint.",
        mode: "otlp",
        advanced: true,
        placeholder: "/etc/otel/client.pem",
    },
    {
        key: "OTEL_EXPORTER_OTLP_CLIENT_KEY",
        label: "Client key (mTLS)",
        hint: "Unencrypted private key PEM matching the client certificate. Passphrase-protected keys are not supported.",
        mode: "otlp",
        advanced: true,
        placeholder: "/etc/otel/client.key",
    },
    {
        key: "OTEL_SERVICE_NAME",
        label: "Service name",
        hint: 'Service name in the resource attributes. The CLI defaults to "github-copilot" when unset.',
        mode: "both",
        placeholder: "github-copilot",
    },
    {
        key: "COPILOT_OTEL_SOURCE_NAME",
        label: "Instrumentation scope",
        hint: 'Instrumentation scope name. The CLI defaults to "github.copilot" when unset.',
        mode: "both",
        advanced: true,
        placeholder: "github.copilot",
    },
    {
        key: "OTEL_RESOURCE_ATTRIBUTES",
        label: "Resource attributes",
        hint: "Extra resource attributes as comma-separated key=value pairs, percent-encoded where needed. Handy for tagging a machine or team.",
        mode: "both",
        advanced: true,
        placeholder: "host.name=laptop,team=platform",
    },
    {
        key: "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",
        label: "Capture message content",
        hint: "Captures full prompts, responses, system instructions and tool arguments. This includes your code and file contents — only enable on a collector you trust. Defaults to false.",
        mode: "both",
        boolean: true,
    },
    {
        key: "OTEL_LOG_LEVEL",
        label: "OTel diagnostic log level",
        hint: "Diagnostics for the exporter itself, not the CLI --log-level. One of NONE, ERROR, WARN, INFO, DEBUG, VERBOSE, ALL. Use DEBUG when export appears to do nothing.",
        mode: "both",
        advanced: true,
        choices: ["", "NONE", "ERROR", "WARN", "INFO", "DEBUG", "VERBOSE", "ALL"],
    },
];

/**
 * Keys we take ownership of. Anything in here is removed on disable, so that
 * turning the checkbox off genuinely returns the environment to stock.
 */
export const MANAGED_KEYS = VAR_INFO.map((v) => v.key);

export function defaultFilePath() {
    return join(artifactsDir(), DEFAULT_FILE_NAME);
}

function configPath() {
    return join(artifactsDir(), "otel-env.json");
}

function envFilePath() {
    return join(artifactsDir(), "otel.env");
}

function agentScriptPath() {
    return join(artifactsDir(), "otel-env-launchagent.sh");
}

function plistPath() {
    return join(homedir(), "Library", "LaunchAgents", `${LAUNCH_AGENT_LABEL}.plist`);
}

export function defaultConfig() {
    return {
        enabled: false,
        exporter: "file",
        vars: {},
        updatedAt: null,
    };
}

export function loadOtelConfig() {
    try {
        if (!existsSync(configPath())) return defaultConfig();
        const parsed = JSON.parse(readFileSync(configPath(), "utf8"));
        return normalizeConfig(parsed);
    } catch {
        return defaultConfig();
    }
}

function normalizeConfig(input) {
    const base = defaultConfig();
    if (!input || typeof input !== "object") return base;
    const vars = {};
    for (const info of VAR_INFO) {
        if (info.key === "COPILOT_OTEL_ENABLED") continue; // derived, never stored
        const value = input.vars && input.vars[info.key];
        if (value !== undefined && value !== null && String(value).trim() !== "") {
            vars[info.key] = String(value).trim();
        }
    }
    return {
        enabled: Boolean(input.enabled),
        exporter: input.exporter === "otlp" ? "otlp" : "file",
        vars,
        updatedAt: input.updatedAt || base.updatedAt,
    };
}

export function saveOtelConfig(input) {
    const next = normalizeConfig(input);
    next.updatedAt = new Date().toISOString();
    const tmp = `${configPath()}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`, "utf8");
    renameSync(tmp, configPath());
    return next;
}

/**
 * Turn the saved config into the exact variables the next CLI launch should
 * see. Returns an empty map when disabled, which is what makes "untick the box,
 * apply" a full teardown.
 */
export function buildEnvPlan(config = loadOtelConfig()) {
    if (!config.enabled) return {};
    const out = { COPILOT_OTEL_ENABLED: "true" };
    const relevant = (info) => info.mode === "both" || info.mode === config.exporter;

    for (const info of VAR_INFO) {
        if (info.key === "COPILOT_OTEL_ENABLED" || !relevant(info)) continue;
        const value = config.vars[info.key];
        if (value) out[info.key] = value;
    }

    // The file exporter is selected implicitly by the path, and only while
    // COPILOT_OTEL_EXPORTER_TYPE is unset, so we deliberately never set it.
    if (config.exporter === "file" && !out.COPILOT_OTEL_FILE_EXPORTER_PATH) {
        out.COPILOT_OTEL_FILE_EXPORTER_PATH = defaultFilePath();
    }
    return out;
}

/** Path the CLI would write spans to, if the current config were applied. */
export function configuredFilePath(config = loadOtelConfig()) {
    if (config.exporter !== "file") return "";
    return config.vars.COPILOT_OTEL_FILE_EXPORTER_PATH || (config.enabled ? defaultFilePath() : "");
}

function shellQuote(value) {
    return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

export function exportSnippet(plan = buildEnvPlan()) {
    const keys = Object.keys(plan);
    if (!keys.length) return "# OpenTelemetry export is off — no variables to set.";
    return keys.map((k) => `export ${k}=${shellQuote(plan[k])}`).join("\n");
}

function isMac() {
    return process.platform === "darwin";
}

function launchctl(args) {
    return execFileSync("/bin/launchctl", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

function launchdValue(key) {
    if (!isMac()) return null;
    try {
        const out = launchctl(["getenv", key]);
        const trimmed = out.replace(/\n$/, "");
        return trimmed === "" ? null : trimmed;
    } catch {
        return null;
    }
}

function writeAgentFiles(plan) {
    const lines = [
        "#!/bin/sh",
        "# Generated by the token-usage canvas extension.",
        "# Replays the Copilot OpenTelemetry environment into the launchd GUI",
        "# domain at login so Finder/Dock launches inherit it.",
        "",
    ];
    for (const key of MANAGED_KEYS) {
        if (plan[key] === undefined) lines.push(`launchctl unsetenv ${key}`);
    }
    for (const [key, value] of Object.entries(plan)) {
        lines.push(`launchctl setenv ${key} ${shellQuote(value)}`);
    }
    lines.push("");
    writeFileSync(agentScriptPath(), lines.join("\n"), "utf8");
    chmodSync(agentScriptPath(), 0o700);

    const plist = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "    <key>Label</key>",
        `    <string>${LAUNCH_AGENT_LABEL}</string>`,
        "    <key>ProgramArguments</key>",
        "    <array>",
        "        <string>/bin/sh</string>",
        `        <string>${agentScriptPath()}</string>`,
        "    </array>",
        "    <key>RunAtLoad</key>",
        "    <true/>",
        "</dict>",
        "</plist>",
        "",
    ].join("\n");
    writeFileSync(plistPath(), plist, "utf8");
}

function writeEnvFile(plan) {
    const body = Object.entries(plan)
        .map(([k, v]) => `${k}=${v}`)
        .join("\n");
    writeFileSync(envFilePath(), body ? `${body}\n` : "", "utf8");
    chmodSync(envFilePath(), 0o600);
}

function reloadAgent() {
    const uid = typeof process.getuid === "function" ? process.getuid() : 0;
    try {
        launchctl(["bootout", `gui/${uid}/${LAUNCH_AGENT_LABEL}`]);
    } catch {
        /* not loaded yet */
    }
    launchctl(["bootstrap", `gui/${uid}`, plistPath()]);
}

/**
 * Push the saved config into the launchd session so the *next* app launch picks
 * it up, and persist it as a LaunchAgent so it survives logout. Existing
 * processes, including the one calling this, keep their original environment.
 */
export function applyToLoginEnv(config = loadOtelConfig()) {
    const plan = buildEnvPlan(config);
    writeEnvFile(plan);

    if (!isMac()) {
        return {
            ok: false,
            platform: process.platform,
            reason: "Automatic apply is only implemented for macOS launchd. The variables were written to the env file below; source it from your shell profile or your desktop session's environment.",
            envFile: envFilePath(),
            plan,
        };
    }

    const errors = [];
    for (const key of MANAGED_KEYS) {
        if (plan[key] !== undefined) continue;
        try {
            launchctl(["unsetenv", key]);
        } catch (err) {
            errors.push(`unsetenv ${key}: ${err && err.message ? err.message : err}`);
        }
    }
    for (const [key, value] of Object.entries(plan)) {
        try {
            launchctl(["setenv", key, value]);
        } catch (err) {
            errors.push(`setenv ${key}: ${err && err.message ? err.message : err}`);
        }
    }

    try {
        writeAgentFiles(plan);
        reloadAgent();
    } catch (err) {
        errors.push(`launch agent: ${err && err.message ? err.message : err}`);
    }

    return {
        ok: errors.length === 0,
        platform: process.platform,
        reason: errors.length ? errors.join("; ") : null,
        envFile: envFilePath(),
        plist: plistPath(),
        plan,
    };
}

/** Remove everything this extension installed, leaving no launchd residue. */
export function removeFromLoginEnv() {
    const errors = [];
    if (isMac()) {
        for (const key of MANAGED_KEYS) {
            try {
                launchctl(["unsetenv", key]);
            } catch (err) {
                errors.push(`unsetenv ${key}: ${err && err.message ? err.message : err}`);
            }
        }
        const uid = typeof process.getuid === "function" ? process.getuid() : 0;
        try {
            launchctl(["bootout", `gui/${uid}/${LAUNCH_AGENT_LABEL}`]);
        } catch {
            /* not loaded */
        }
    }
    for (const path of [plistPath(), agentScriptPath(), envFilePath()]) {
        try {
            if (existsSync(path)) unlinkSync(path);
        } catch (err) {
            errors.push(`remove ${path}: ${err && err.message ? err.message : err}`);
        }
    }
    return { ok: errors.length === 0, reason: errors.length ? errors.join("; ") : null };
}

function maskIfSecret(info, value) {
    if (!value) return value;
    if (!info || !info.secret) return value;
    return value.length <= 8 ? "••••" : `${value.slice(0, 4)}••••${value.slice(-2)}`;
}

/**
 * Compare three worlds: what the user asked for, what this process actually
 * received at startup, and what a future launch would receive. The gap between
 * the second and third is precisely "you need to restart the app".
 */
export function loginEnvStatus(config = loadOtelConfig()) {
    const plan = buildEnvPlan(config);
    const infoByKey = new Map(VAR_INFO.map((v) => [v.key, v]));
    const rows = [];
    let restartNeeded = false;

    for (const key of MANAGED_KEYS) {
        const info = infoByKey.get(key);
        const desired = plan[key] !== undefined ? plan[key] : "";
        const inProcess = process.env[key] !== undefined ? process.env[key] : "";
        const inLaunchd = launchdValue(key) || "";
        if (desired !== inProcess) restartNeeded = true;
        if (!desired && !inProcess && !inLaunchd) continue;
        rows.push({
            key,
            label: info ? info.label : key,
            desired: maskIfSecret(info, desired),
            process: maskIfSecret(info, inProcess),
            launchd: maskIfSecret(info, inLaunchd),
            matches: desired === inProcess,
        });
    }

    const agentInstalled = existsSync(plistPath());
    const activeInProcess =
        String(process.env.COPILOT_OTEL_ENABLED || "").toLowerCase() === "true" ||
        Boolean(process.env.OTEL_EXPORTER_OTLP_ENDPOINT) ||
        Boolean(process.env.COPILOT_OTEL_FILE_EXPORTER_PATH);

    const warnings = [];
    if (config.enabled && config.exporter === "otlp") {
        const endpoint = plan.OTEL_EXPORTER_OTLP_ENDPOINT || "";
        if (!endpoint) {
            warnings.push("No OTLP endpoint set — the CLI will not export anywhere.");
        } else if (endpoint.startsWith("http://")) {
            warnings.push(
                "Copilot refuses to send OTLP over cleartext http:// (including the default http://localhost:4318): export is disabled rather than sent unencrypted, and it only shows up as a warning in the CLI log. Use an https:// collector, or switch to the file exporter.",
            );
        }
        const cert = plan.OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE;
        const key = plan.OTEL_EXPORTER_OTLP_CLIENT_KEY;
        if (Boolean(cert) !== Boolean(key)) {
            warnings.push("Mutual TLS needs both the client certificate and the client key; set both or neither.");
        }
    }
    if (config.enabled && config.vars.OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT === "true") {
        warnings.push("Message content capture is on: prompts, responses, file contents and tool arguments will be exported.");
    }

    return {
        supported: isMac(),
        platform: process.platform,
        plan,
        rows,
        restartNeeded: restartNeeded && (config.enabled || activeInProcess),
        activeInProcess,
        agentInstalled,
        envFile: envFilePath(),
        plist: plistPath(),
        snippet: exportSnippet(plan),
        warnings,
    };
}
