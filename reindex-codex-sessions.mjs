#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { basename, join, relative, sep } from "node:path";

const args = process.argv.slice(2);
let codexHome = "";
let pathStyle = "posix";
let dryRun = false;
let repairPaths = false;

for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === "--codex-home") {
    codexHome = args[++index] ?? "";
  } else if (arg === "--path-style") {
    pathStyle = args[++index] ?? "posix";
  } else if (arg === "--dry-run") {
    dryRun = true;
  } else if (arg === "--repair-paths") {
    repairPaths = true;
  } else {
    throw new Error(`Unsupported argument: ${arg}`);
  }
}

if (!codexHome) {
  throw new Error("Missing --codex-home");
}

const stateDb = join(codexHome, "state_5.sqlite");
if (!existsSync(stateDb)) {
  console.log("considered=0 missing=0 inserted=0 skipped=no-state-db");
  process.exit(0);
}

const runSqlite = (sql) => {
  const result = spawnSync("sqlite3", [stateDb], {
    input: sql,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });

  if (result.status !== 0) {
    throw new Error(
      `sqlite3 failed for ${stateDb}: ${result.stderr || result.stdout}`,
    );
  }

  return result.stdout;
};

const tableColumns = new Set(
  runSqlite("PRAGMA table_info(threads);\n")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => line.split("|")[1]),
);

const hasThreadSpawnEdges = runSqlite(
  "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'thread_spawn_edges';\n",
).trim() === "thread_spawn_edges";

const existingIds = new Set(
  runSqlite("SELECT id FROM threads;\n").trim().split("\n").filter(Boolean),
);

const readSessionIndex = () => {
  const indexPath = join(codexHome, "session_index.jsonl");
  const byId = new Map();

  if (!existsSync(indexPath)) {
    return byId;
  }

  for (const line of readFileSync(indexPath, "utf8").split(/\r?\n/)) {
    if (!line.trim()) {
      continue;
    }

    try {
      const entry = JSON.parse(line);
      if (typeof entry.id === "string") {
        byId.set(entry.id, entry);
      }
    } catch {
      // The rollout file is authoritative; malformed index rows should not
      // block repairing the local thread table.
    }
  }

  return byId;
};

const walkJsonl = (root) => {
  if (!existsSync(root)) {
    return [];
  }

  const entries = [];
  for (const dirent of readdirSync(root, { withFileTypes: true })) {
    const fullPath = join(root, dirent.name);
    if (dirent.isDirectory()) {
      entries.push(...walkJsonl(fullPath));
    } else if (dirent.isFile() && dirent.name.endsWith(".jsonl")) {
      entries.push(fullPath);
    }
  }
  return entries;
};

const parseIdFromPath = (filePath) => {
  const match = basename(filePath).match(
    /rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i,
  );
  return match?.[1] ?? null;
};

const toSeconds = (iso, fallbackMillis = 0) => {
  const millis = Date.parse(iso);
  return Number.isFinite(millis)
    ? Math.floor(millis / 1000)
    : Math.floor(fallbackMillis / 1000);
};

const toMillis = (iso, fallbackMillis = 0) => {
  const millis = Date.parse(iso);
  return Number.isFinite(millis) ? millis : fallbackMillis;
};

const stableSource = (source) => {
  if (typeof source === "string" && source) {
    return source;
  }

  if (source && typeof source === "object") {
    return JSON.stringify(source);
  }

  return "unknown";
};

const textFromContent = (content) => {
  if (typeof content === "string") {
    return content;
  }

  if (!Array.isArray(content)) {
    return "";
  }

  return content
    .map((part) => {
      if (typeof part === "string") {
        return part;
      }
      return part?.text ?? part?.input_text ?? "";
    })
    .filter(Boolean)
    .join("\n");
};

const userMessageFromEvent = (event) => {
  const payload = event.payload;
  if (payload?.type === "user_message" && typeof payload.message === "string") {
    return payload.message;
  }

  if (payload?.type === "message" && payload.role === "user") {
    return textFromContent(payload.content);
  }

  return "";
};

const normalizeApprovalMode = (value) => {
  if (typeof value !== "string" || !value) {
    return null;
  }

  return value.replaceAll("_", "-").toLowerCase();
};

const normalizeHistoryMode = (value) => {
  if (value === "paginated" || value === "legacy") {
    return value;
  }
  return "legacy";
};

const toWindowsPath = (value) => {
  if (typeof value !== "string" || !value) {
    return value ?? "";
  }

  if (/^[A-Za-z]:[\\/]/.test(value) || value.startsWith("\\\\")) {
    return value.replaceAll("/", "\\");
  }

  if (value.startsWith("/mnt/") && value.length > "/mnt/x".length) {
    const drive = value.slice("/mnt/".length, "/mnt/".length + 1);
    const rest = value.slice("/mnt/x".length);
    return `${drive.toUpperCase()}:\\${rest.replaceAll("/", "\\").replace(/^\\/, "")}`;
  }

  if (value.startsWith("/")) {
    const distro = process.env.WSL_DISTRO_NAME || "Ubuntu";
    return `\\\\wsl.localhost\\${distro}${value.replaceAll("/", "\\")}`;
  }

  return value;
};

const toPosixPath = (value) => {
  if (typeof value !== "string" || !value) {
    return value ?? "";
  }

  const driveMatch = value.match(/^([A-Za-z]):[\\/](.*)$/);
  if (driveMatch) {
    return `/mnt/${driveMatch[1].toLowerCase()}/${driveMatch[2].replaceAll("\\", "/")}`;
  }

  const uncPrefix = /^\\\\wsl(?:\.localhost)?\\([^\\]+)(\\.*)?$/i;
  const uncMatch = value.match(uncPrefix);
  if (uncMatch) {
    const rest = (uncMatch[2] ?? "").replaceAll("\\", "/");
    return rest.startsWith("/") ? rest : `/${rest}`;
  }

  return value.replaceAll("\\", "/");
};

const toNativePath = (value) => {
  return pathStyle === "windows" ? toWindowsPath(value) : toPosixPath(value);
};

const nativeRolloutPath = (filePath) => toNativePath(filePath);

const parseRollout = (filePath) => {
  const idFromPath = parseIdFromPath(filePath);
  const fallbackMillis = statSync(filePath).mtimeMs;
  let meta = null;
  let firstUserMessage = "";
  let lastTimestamp = "";
  let tokensUsed = 0;
  let model = null;
  let reasoningEffort = null;
  let approvalMode = null;
  let sandboxPolicy = null;

  for (const line of readFileSync(filePath, "utf8").split(/\r?\n/)) {
    if (!line.trim()) {
      continue;
    }

    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }

    if (typeof event.timestamp === "string") {
      lastTimestamp = event.timestamp;
    }

    if (event.type === "session_meta" && event.payload && !meta) {
      meta = event.payload.meta ?? event.payload;
    }

    if (event.type === "turn_context" && event.payload) {
      model = event.payload.model ?? model;
      reasoningEffort =
        event.payload.reasoning_effort ??
        event.payload.effort ??
        event.payload.collaboration_mode?.settings?.reasoning_effort ??
        reasoningEffort;
      approvalMode =
        normalizeApprovalMode(event.payload.approval_policy) ?? approvalMode;
      sandboxPolicy =
        event.payload.permission_profile ??
        event.payload.sandbox_policy ??
        sandboxPolicy;
    }

    if (!firstUserMessage) {
      firstUserMessage = userMessageFromEvent(event);
    }

    const totalTokens = event.payload?.info?.total_token_usage?.total_tokens;
    if (typeof totalTokens === "number") {
      tokensUsed = totalTokens;
    }
  }

  const id = meta?.id ?? meta?.session_id ?? idFromPath;
  if (!id) {
    return null;
  }

  const createdIso = meta?.timestamp ?? lastTimestamp;
  const updatedIso = lastTimestamp || createdIso;
  const source = stableSource(meta?.source);
  const git = meta?.git ?? {};

  return {
    id,
    createdAt: toSeconds(createdIso, fallbackMillis),
    updatedAt: toSeconds(updatedIso, fallbackMillis),
    createdAtMs: toMillis(createdIso, fallbackMillis),
    updatedAtMs: toMillis(updatedIso, fallbackMillis),
    source,
    modelProvider: meta?.model_provider ?? "openai",
    cwd: toNativePath(meta?.cwd ?? ""),
    cliVersion: meta?.cli_version ?? "",
    firstUserMessage,
    agentNickname: meta?.agent_nickname ?? null,
    agentRole: meta?.agent_role ?? null,
    model,
    reasoningEffort,
    agentPath: meta?.agent_path ? toNativePath(meta.agent_path) : null,
    threadSource: meta?.thread_source ?? null,
    tokensUsed,
    sandboxPolicy: JSON.stringify(sandboxPolicy ?? { type: "read-only" }),
    approvalMode: approvalMode ?? "on-request",
    historyMode: normalizeHistoryMode(meta?.history_mode),
    gitSha: git.commit_hash ?? null,
    gitBranch: git.branch ?? null,
    gitOriginUrl: git.repository_url ?? null,
  };
};

const sqlString = (value) => {
  if (value === null || value === undefined) {
    return "NULL";
  }
  return `'${String(value).replaceAll("'", "''")}'`;
};

const sqlInteger = (value) => {
  return Number.isFinite(value) ? String(Math.trunc(value)) : "0";
};

const parentThreadIdFromSource = (source) => {
  try {
    const parsed = JSON.parse(source);
    const parent = parsed?.subagent?.thread_spawn?.parent_thread_id;
    return typeof parent === "string" ? parent : null;
  } catch {
    return null;
  }
};

const isWrongDialectPath = (value) => {
  if (typeof value !== "string" || !value) {
    return false;
  }

  if (pathStyle === "windows") {
    return value.startsWith("/");
  }

  return /^[A-Za-z]:[\\/]/.test(value) || value.startsWith("\\\\");
};

const repairStoredPaths = () => {
  if (!repairPaths) {
    return [];
  }

  const optionalColumns = ["rollout_path", "cwd", "agent_path"].filter((column) =>
    tableColumns.has(column),
  );
  if (optionalColumns.length === 0) {
    return [];
  }

  const rows = runSqlite(
    `SELECT id, ${optionalColumns.map((column) => `COALESCE(${column}, '')`).join(", ")} FROM threads;\n`,
  )
    .trim()
    .split("\n")
    .filter(Boolean);
  const updates = [];

  for (const row of rows) {
    const [id, ...values] = row.split("|");
    const assignments = [];

    optionalColumns.forEach((column, index) => {
      const value = values[index] ?? "";
      if (isWrongDialectPath(value)) {
        assignments.push(`${column} = ${sqlString(toNativePath(value))}`);
      }
    });

    if (assignments.length > 0) {
      updates.push(`UPDATE threads SET ${assignments.join(", ")} WHERE id = ${sqlString(id)};`);
    }
  }

  return updates;
};

const sessionIndex = readSessionIndex();
const rolloutFiles = [
  ...walkJsonl(join(codexHome, "sessions")),
  ...walkJsonl(join(codexHome, "archived_sessions")),
];

const statements = [];
let considered = 0;

for (const filePath of rolloutFiles) {
  const id = parseIdFromPath(filePath);
  if (!id || existingIds.has(id)) {
    continue;
  }

  const parsed = parseRollout(filePath);
  if (!parsed) {
    continue;
  }

  considered += 1;
  const indexed = sessionIndex.get(parsed.id);
  const title =
    indexed?.thread_name ??
    parsed.firstUserMessage.split(/\r?\n/)[0] ??
    parsed.id;
  const isArchived = relative(codexHome, filePath).startsWith(`archived_sessions${sep}`);
  const preview = parsed.firstUserMessage || "";

  const valuesByColumn = new Map([
    ["id", sqlString(parsed.id)],
    ["rollout_path", sqlString(nativeRolloutPath(filePath))],
    ["created_at", sqlInteger(parsed.createdAt)],
    ["updated_at", sqlInteger(parsed.updatedAt)],
    ["source", sqlString(parsed.source)],
    ["model_provider", sqlString(parsed.modelProvider)],
    ["cwd", sqlString(parsed.cwd)],
    ["title", sqlString(title)],
    ["sandbox_policy", sqlString(parsed.sandboxPolicy)],
    ["approval_mode", sqlString(parsed.approvalMode)],
    ["tokens_used", sqlInteger(parsed.tokensUsed)],
    ["has_user_event", parsed.firstUserMessage ? "1" : "0"],
    ["archived", isArchived ? "1" : "0"],
    ["archived_at", isArchived ? sqlInteger(parsed.updatedAt) : "NULL"],
    ["git_sha", sqlString(parsed.gitSha)],
    ["git_branch", sqlString(parsed.gitBranch)],
    ["git_origin_url", sqlString(parsed.gitOriginUrl)],
    ["cli_version", sqlString(parsed.cliVersion)],
    ["first_user_message", sqlString(parsed.firstUserMessage)],
    ["agent_nickname", sqlString(parsed.agentNickname)],
    ["agent_role", sqlString(parsed.agentRole)],
    ["memory_mode", sqlString("enabled")],
    ["model", sqlString(parsed.model)],
    ["reasoning_effort", sqlString(parsed.reasoningEffort)],
    ["agent_path", sqlString(parsed.agentPath)],
    ["created_at_ms", sqlInteger(parsed.createdAtMs)],
    ["updated_at_ms", sqlInteger(parsed.updatedAtMs)],
    ["thread_source", sqlString(parsed.threadSource)],
    ["preview", sqlString(preview)],
    ["recency_at", sqlInteger(parsed.updatedAt)],
    ["recency_at_ms", sqlInteger(parsed.updatedAtMs)],
    ["history_mode", sqlString(parsed.historyMode)],
  ]);

  const columns = [...valuesByColumn.keys()].filter((column) =>
    tableColumns.has(column),
  );
  const values = columns.map((column) => valuesByColumn.get(column));
  statements.push(
    `INSERT INTO threads (${columns.join(", ")}) VALUES (${values.join(", ")}) ON CONFLICT(id) DO NOTHING;`,
  );

  const parentThreadId = parentThreadIdFromSource(parsed.source);
  if (hasThreadSpawnEdges && parentThreadId) {
    statements.push(
      `INSERT INTO thread_spawn_edges (parent_thread_id, child_thread_id, status) VALUES (${sqlString(parentThreadId)}, ${sqlString(parsed.id)}, 'active') ON CONFLICT(child_thread_id) DO NOTHING;`,
    );
  }
}

const pathRepairStatements = repairStoredPaths();
const allStatements = [...statements, ...pathRepairStatements];

if (dryRun || allStatements.length === 0) {
  console.log(
    `considered=${considered} missing=${considered} inserted=0 repaired=${pathRepairStatements.length} dry_run=${dryRun ? 1 : 0}`,
  );
  process.exit(0);
}

runSqlite(`PRAGMA busy_timeout=5000;\nBEGIN IMMEDIATE;\n${allStatements.join("\n")}\nCOMMIT;\n`);
console.log(
  `considered=${considered} missing=${considered} inserted=${considered} repaired=${pathRepairStatements.length} dry_run=0`,
);
