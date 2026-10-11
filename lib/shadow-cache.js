// Resolve the same persistent cache for captures and collectors.
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function git(directory, args) {
  const result = spawnSync("git", args, {
    cwd: directory,
    encoding: "utf8",
    timeout: 5000,
  });
  if (result.error) throw result.error;
  return result;
}

function configured(directory, key, type) {
  const result = git(directory, ["config", type, "--get", key]);
  if (result.status === 1 && !result.stdout) return null;
  if (result.status !== 0)
    throw new Error(`Cannot read ${key}: ${result.stderr.trim()}`);
  return result.stdout.trimEnd();
}

function resolveCache(directory, environment = process.env) {
  if (environment.PRAGMA_SHADOW_CACHE_DIR)
    return {
      directory: path.resolve(directory, environment.PRAGMA_SHADOW_CACHE_DIR),
      source: "PRAGMA_SHADOW_CACHE_DIR",
    };
  const setting = configured(directory, "pragma.shadowCacheDir", "--path");
  if (setting !== null) {
    if (!setting || !path.isAbsolute(setting))
      throw new Error(
        "pragma.shadowCacheDir must be an absolute directory path",
      );
    return { directory: setting, source: "pragma.shadowCacheDir" };
  }
  const result = git(directory, [
    "rev-parse",
    "--path-format=absolute",
    "--git-path",
    "pragma/shadow",
  ]);
  if (result.status !== 0 || !result.stdout.trim())
    throw new Error(
      "Shadow capture needs a Git repository or a configured shadow cache",
    );
  return {
    directory: path.resolve(directory, result.stdout.trimEnd()),
    source: "git-worktree",
  };
}

function cacheAccess(directory, environment = process.env) {
  const value =
    environment.PRAGMA_SHADOW_SHARED ||
    configured(directory, "pragma.shadowCacheShared", "--bool") ||
    "false";
  if (!["0", "1", "false", "true"].includes(value))
    throw new Error("PRAGMA_SHADOW_SHARED must be 0, 1, false, or true");
  return { shared: value === "1" || value === "true" };
}

function prepareCache(cache, shared) {
  if (!shared) {
    fs.mkdirSync(cache, { recursive: true, mode: 0o700 });
    return null;
  }
  if (typeof process.getgid !== "function")
    throw new Error(
      "Shared shadow receipts require a filesystem with Unix group permissions",
    );
  let status;
  try {
    status = fs.statSync(cache);
  } catch (error) {
    throw new Error(
      `Shared shadow cache must already exist: ${cache} (${error.code})`,
    );
  }
  // Setgid inherits the operator-selected group; sticky prevents deleting other users' runs.
  if (
    !status.isDirectory() ||
    (status.mode & 0o3770) !== 0o3770 ||
    status.mode & 0o007
  )
    throw new Error(
      `Shared shadow cache must have mode 3770 and its access group: ${cache}`,
    );
  const groups = [process.getgid(), ...process.getgroups()];
  if (!groups.includes(status.gid))
    throw new Error(
      `Current user is not a member of the shared cache group (gid ${status.gid})`,
    );
  fs.accessSync(
    cache,
    fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK,
  );
  return status.gid;
}

function shareReceipt(directory, group) {
  const status = fs.lstatSync(directory);
  if (status.isSymbolicLink()) return;
  if (!status.isDirectory() && !status.isFile()) return;
  if (status.isFile() && status.nlink !== 1)
    throw new Error(
      `Cannot share a hard-linked artifact without changing another file: ${directory}`,
    );
  if (status.gid !== group)
    throw new Error(
      `Receipt artifact did not inherit the shared group: ${directory}`,
    );
  if (status.isDirectory()) {
    for (const entry of fs.readdirSync(directory))
      shareReceipt(path.join(directory, entry), group);
    fs.chmodSync(directory, 0o2750);
  } else fs.chmodSync(directory, 0o640);
}

module.exports = { resolveCache, cacheAccess, prepareCache, shareReceipt };
