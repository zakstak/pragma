#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { validateThreadId } = require("../lib/thread-context.js");

function hash(value) {
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 12);
}

function threadName(threadId) {
  const slug =
    threadId
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40) || "thread";
  return `${slug}-${hash(threadId)}`;
}

function git(repository, args) {
  const result = spawnSync("git", ["-C", repository, ...args], {
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error(
      result.error
        ? result.error.message
        : result.stderr.trim() || `git ${args[0]} failed`,
    );
  }
  return result.stdout.trim();
}

function canonicalGitDirectory(repository) {
  return fs.realpathSync(
    git(repository, [
      "rev-parse",
      "--path-format=absolute",
      "--git-common-dir",
    ]),
  );
}

function canonicalDestination(location) {
  let existing = path.resolve(location);
  const missing = [];
  while (!fs.existsSync(existing)) {
    missing.unshift(path.basename(existing));
    existing = path.dirname(existing);
  }
  return path.join(fs.realpathSync(existing), ...missing);
}

function validateBaseDirectory(baseDirectory, sourceRoot, repository) {
  const base = canonicalDestination(baseDirectory);
  const worktrees = git(sourceRoot, ["worktree", "list", "--porcelain", "-z"])
    .split("\0")
    .filter((field) => field.startsWith("worktree "))
    .map((field) => canonicalDestination(field.slice("worktree ".length)));
  for (const protectedDirectory of [repository, ...worktrees]) {
    const relative = path.relative(protectedDirectory, base);
    if (
      !relative ||
      (!relative.startsWith(`..${path.sep}`) &&
        relative !== ".." &&
        !path.isAbsolute(relative))
    ) {
      throw new Error(
        `Worktree cache must be outside every registered worktree and Git directory: ${base}. Choose a dedicated PRAGMA_WORKTREE_DIR.`,
      );
    }
  }
  return base;
}

async function acquireLock(lockPath, threadId, timeoutMs = 30000) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      fs.mkdirSync(lockPath);
      try {
        fs.writeFileSync(
          path.join(lockPath, "creator.json"),
          JSON.stringify({
            pid: process.pid,
            thread_id: threadId,
            created_at: new Date().toISOString(),
          }) + "\n",
          { flag: "wx" },
        );
      } catch (error) {
        fs.rmdirSync(lockPath);
        throw error;
      }
      return () => fs.rmSync(lockPath, { recursive: true });
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (Date.now() >= deadline) {
        throw new Error(
          `Worktree creation is locked: ${lockPath}. Inspect creator.json and the active process; remove a stale lock only after confirming no creator is running.`,
        );
      }
      await new Promise((resolve) =>
        setTimeout(resolve, Math.min(50, Math.max(1, deadline - Date.now()))),
      );
    }
  }
}

function ownerPath(worktree) {
  return path.resolve(
    worktree,
    git(worktree, ["rev-parse", "--git-path", "pragma/thread.json"]),
  );
}

function validateOwner(owner, threadId, repository, worktree) {
  if (
    !owner ||
    owner.schema !== "pragma.thread-owner" ||
    owner.schema_version !== 1 ||
    owner.thread_id !== threadId ||
    owner.repository !== repository ||
    owner.worktree !== worktree ||
    typeof owner.created_at !== "string" ||
    !Number.isFinite(Date.parse(owner.created_at))
  ) {
    throw new Error(
      `Worktree owner conflicts with thread ${JSON.stringify(threadId)}: ${worktree}. Existing work is preserved.`,
    );
  }
}

function readOwner(file, threadId, repository, worktree) {
  let owner;
  try {
    owner = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(
      `Cannot reuse an unowned or invalid worktree: ${worktree} (${error.message}). Existing work is preserved.`,
    );
  }
  validateOwner(owner, threadId, repository, worktree);
  return owner;
}

function claimOwner(file, owner) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(8).toString("hex")}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(owner, null, 2) + "\n", {
    flag: "wx",
    mode: 0o600,
  });
  try {
    // Publishing by exclusive hard link prevents another process's owner from being overwritten.
    fs.linkSync(temporary, file);
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    readOwner(file, owner.thread_id, owner.repository, owner.worktree);
  } finally {
    fs.unlinkSync(temporary);
  }
}

async function ensureWorktree(threadId, source, baseDirectory) {
  validateThreadId(threadId);
  const sourceRoot = fs.realpathSync(
    git(path.resolve(source), ["rev-parse", "--show-toplevel"]),
  );
  const repository = canonicalGitDirectory(sourceRoot);
  const startingCommit = git(sourceRoot, ["rev-parse", "--verify", "HEAD"]);
  const name = threadName(threadId);
  const branch = `pragma/thread-${name}`;
  const base = validateBaseDirectory(baseDirectory, sourceRoot, repository);
  fs.mkdirSync(base, { recursive: true });
  const destination = path.join(fs.realpathSync(base), hash(repository), name);
  const release = await acquireLock(
    path.join(repository, "pragma", "thread-locks", `${name}.lock`),
    threadId,
  );
  try {
    let reused = false;
    if (fs.existsSync(destination)) {
      const worktree = fs.realpathSync(destination);
      if (
        canonicalGitDirectory(worktree) !== repository ||
        fs.realpathSync(git(worktree, ["rev-parse", "--show-toplevel"])) !==
          worktree
      ) {
        throw new Error(
          `Destination is not the expected repository worktree: ${destination}. Existing files are preserved.`,
        );
      }
      readOwner(ownerPath(worktree), threadId, repository, worktree);
      if (git(worktree, ["symbolic-ref", "--short", "HEAD"]) !== branch) {
        throw new Error(
          `Owned worktree is on a different branch: ${worktree}. Existing work is preserved.`,
        );
      }
      reused = true;
    } else {
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      const branches = git(sourceRoot, [
        "for-each-ref",
        "--format=%(refname)",
        `refs/heads/${branch}`,
      ]);
      // Git refuses a branch already checked out elsewhere; never force or move that checkout.
      if (branches === `refs/heads/${branch}`) {
        git(sourceRoot, ["worktree", "add", "--quiet", destination, branch]);
      } else {
        git(sourceRoot, [
          "worktree",
          "add",
          "--quiet",
          "-b",
          branch,
          destination,
          startingCommit,
        ]);
      }
      const worktree = fs.realpathSync(destination);
      claimOwner(ownerPath(worktree), {
        schema: "pragma.thread-owner",
        schema_version: 1,
        thread_id: threadId,
        repository,
        worktree,
        created_at: new Date().toISOString(),
      });
    }
    const worktree = fs.realpathSync(destination);
    return {
      thread_id: threadId,
      repository,
      worktree,
      branch,
      owner_file: ownerPath(worktree),
      reused,
    };
  } finally {
    release();
  }
}

async function main(args, environment) {
  if (args.length > 2)
    throw new Error("Usage: thread-worktree.js [thread-id] [repo]");
  const threadId = validateThreadId(
    args[0] ?? environment.PRAGMA_THREAD_ID ?? environment.CODEX_THREAD_ID,
  );
  const base =
    environment.PRAGMA_WORKTREE_DIR ||
    path.join(os.homedir(), ".cache", "pragma", "worktrees");
  const result = await ensureWorktree(
    threadId,
    args[1] || process.cwd(),
    path.resolve(base),
  );
  process.stdout.write(JSON.stringify(result) + "\n");
}

if (require.main === module) {
  main(process.argv.slice(2), process.env).catch((error) => {
    process.stderr.write(`pragma thread-worktree: ${error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = { validateThreadId, threadName, acquireLock, ensureWorktree };
