// Thread ownership belongs to a worktree; repository identity spans its clones.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

function git(root, args) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "ignore"],
  });
  return result.status === 0 ? result.stdout.trim() : null;
}

function identity(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function canonicalOrigin(value) {
  if (!value) return null;
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    const scp = /^(?:[^@/:]+@)?([^/:]+):(.+)$/.exec(value);
    if (!scp) return null;
    try {
      parsed = new URL(`ssh://${scp[1]}/${scp[2]}`);
    } catch {
      return null;
    }
  }
  if (!["https:", "http:", "ssh:", "git:"].includes(parsed.protocol))
    return null;
  const host = parsed.hostname.toLowerCase();
  let project = parsed.pathname.replace(/^\/+|\/+$/g, "").replace(/\.git$/, "");
  if (!host || !project) return null;
  if (host === "github.com") project = project.toLowerCase();
  const defaultPort = { "ssh:": "22", "git:": "9418" }[parsed.protocol];
  const port =
    parsed.port && parsed.port !== defaultPort ? `:${parsed.port}` : "";
  // Authentication and query parameters never enter a receipt or identity.
  return `${host}${port}/${project}`;
}

function validateThreadId(value) {
  if (
    typeof value !== "string" ||
    !value ||
    value.length > 128 ||
    value.trim() !== value ||
    Array.from(value).some((character) => {
      const code = character.charCodeAt(0);
      return code < 32 || code === 127;
    })
  )
    throw new Error(
      "Thread ID must contain 1–128 printable characters without surrounding whitespace",
    );
  return value;
}

function readOwner(location) {
  let bytes;
  try {
    bytes = fs.readFileSync(location, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
  const owner = JSON.parse(bytes);
  if (
    owner.schema !== "pragma.thread-owner" ||
    owner.schema_version !== 1 ||
    typeof owner.repository !== "string" ||
    !path.isAbsolute(owner.repository) ||
    typeof owner.worktree !== "string" ||
    !path.isAbsolute(owner.worktree) ||
    typeof owner.created_at !== "string" ||
    !Number.isFinite(Date.parse(owner.created_at))
  )
    throw new Error(`Unsupported or invalid thread owner record: ${location}`);
  validateThreadId(owner.thread_id);
  return owner;
}

function getThreadContext(directory, environment = process.env) {
  const root = git(directory, ["rev-parse", "--show-toplevel"]);
  const common = git(directory, [
    "rev-parse",
    "--path-format=absolute",
    "--git-common-dir",
  ]);
  const gitDir = git(directory, ["rev-parse", "--absolute-git-dir"]);
  const ownerPath = git(directory, [
    "rev-parse",
    "--path-format=absolute",
    "--git-path",
    "pragma/thread.json",
  ]);
  const owner = ownerPath ? readOwner(ownerPath) : null;
  if (
    owner &&
    (owner.repository !== fs.realpathSync(common) ||
      owner.worktree !== fs.realpathSync(root))
  )
    throw new Error(
      `Thread owner record does not match this worktree: ${ownerPath}`,
    );
  const source = environment.PRAGMA_THREAD_ID
    ? "PRAGMA_THREAD_ID"
    : environment.CODEX_THREAD_ID
      ? "CODEX_THREAD_ID"
      : null;
  const requested = source ? validateThreadId(environment[source]) : null;
  if (owner && requested && owner.thread_id !== requested)
    throw new Error(
      `Worktree belongs to thread ${owner.thread_id}; thread ${requested} must use its own worktree. Run Pragma's tools/thread-worktree.js for that thread.`,
    );
  const origin = canonicalOrigin(
    git(directory, ["config", "--get", "remote.origin.url"]),
  );
  return {
    thread_id: requested || owner?.thread_id || null,
    thread_source: source || (owner ? "worktree-owner" : null),
    repository_id: identity(
      origin
        ? `origin:${origin}`
        : `local:${common ? fs.realpathSync(common) : fs.realpathSync(directory)}`,
    ),
    worktree_id: gitDir ? identity(fs.realpathSync(gitDir)) : null,
    owner,
  };
}

module.exports = { canonicalOrigin, getThreadContext, validateThreadId };

if (require.main === module) {
  try {
    const [command, root = ".", ...extra] = process.argv.slice(2);
    if (command !== "check" || extra.length)
      throw new Error("Usage: thread-context.js check [repository]");
    getThreadContext(root);
  } catch (error) {
    console.error(`Pragma thread guard: ${error.message}`);
    process.exitCode = 1;
  }
}
