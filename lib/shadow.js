// Run a project-owned compiler comparison and retain a local receipt.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");
const { performance } = require("node:perf_hooks");

const [runner, receiptFile] = process.argv.slice(2);
const cwd = process.cwd();
const pragmaRoot = path.dirname(__dirname);
process.umask(0o077);

function probe(command, args, directory = cwd) {
  const result = spawnSync(command, args, {
    cwd: directory,
    encoding: "utf8",
    timeout: 5000,
    maxBuffer: 1024 * 1024,
  });
  return {
    command: [command, ...args],
    exit_code: result.status,
    signal: result.signal,
    output: (result.stdout || "") + (result.stderr || ""),
    error: result.error?.message || null,
  };
}

function git(args, directory = cwd) {
  const result = probe("git", args, directory);
  return result.exit_code === 0 ? result.output.trimEnd() : null;
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function gitState(root, excludedCache) {
  const statusArgs = [
    "status",
    "--porcelain=v1",
    "--untracked-files=all",
    "--",
    ".",
  ];
  if (excludedCache) statusArgs.push(`:(exclude,literal)${excludedCache}`);
  return {
    head: git(["rev-parse", "--verify", "HEAD"]),
    tree: git(["rev-parse", "HEAD^{tree}"]),
    branch: git(["symbolic-ref", "--quiet", "--short", "HEAD"]),
    describe: git(["describe", "--always", "--dirty", "--tags"]),
    commit_time: git(["show", "-s", "--format=%cI", "HEAD"]),
    upstream: git(["rev-parse", "--symbolic-full-name", "@{upstream}"]),
    status: git(statusArgs, root),
  };
}

function packageVersions() {
  const names = [
    "typescript",
    "tsc-rs",
    "@typescript/native-preview",
    "@effect/tsgo",
    "@effect/language-service",
    "effect",
    "oxlint",
    "oxlint-tsgolint",
  ];
  return Object.fromEntries(
    names.map((name) => {
      const location = path.join(cwd, "node_modules", name, "package.json");
      try {
        const pkg = JSON.parse(fs.readFileSync(location, "utf8"));
        return [
          name,
          {
            name: pkg.name,
            version: pkg.version,
            path: location,
          },
        ];
      } catch {
        return [name, null];
      }
    }),
  );
}

function writeJson(location, value) {
  fs.writeFileSync(`${location}.tmp`, JSON.stringify(value, null, 2) + "\n");
  fs.renameSync(`${location}.tmp`, location);
}

function inputManifest(root, destination, excludedCache) {
  const listed = probe(
    "git",
    ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    root,
  );
  if (listed.exit_code !== 0)
    throw new Error(`Cannot inventory Git inputs: ${listed.output}`);
  const names = [...new Set(listed.output.split("\0").filter(Boolean))].sort();
  const entries = [];
  for (const name of names) {
    if (
      excludedCache &&
      (name === excludedCache || name.startsWith(`${excludedCache}/`))
    )
      continue;
    const base = path.basename(name);
    const config =
      /^(package\.json|(?:ts|js)config.*\.jsonc?|\.oxlintrc\.jsonc?|oxlint\.config\.[mc]?ts|(?:package-lock|npm-shrinkwrap)\.json|(?:pnpm-lock|yarn\.lock|bun\.lockb?).*)$/.test(
        base,
      );
    if (!config && !/\.[cm]?[jt]sx?$/.test(name)) continue;
    const location = path.join(root, name);
    try {
      const stat = fs.lstatSync(location);
      if (stat.isSymbolicLink()) {
        entries.push({
          path: name,
          kind: "symlink",
          target: fs.readlinkSync(location),
        });
      } else if (stat.isFile()) {
        const bytes = fs.readFileSync(location);
        entries.push({
          path: name,
          kind: "file",
          sha256: sha256(bytes),
          bytes: stat.size,
          mode: stat.mode & 0o777,
          mtime_ms: stat.mtimeMs,
        });
        if (config && destination) {
          const saved = path.join(destination, "inputs", name);
          fs.mkdirSync(path.dirname(saved), { recursive: true, mode: 0o700 });
          fs.writeFileSync(saved, bytes);
        }
      }
    } catch (error) {
      entries.push({ path: name, kind: "unavailable", error: error.message });
    }
  }
  return { sha256: sha256(JSON.stringify(entries)), files: entries };
}

async function capture(command, args, directory, label, timeoutMs) {
  const stdoutPath = path.join(directory, `${label}.stdout.log`);
  const stderrPath = path.join(directory, `${label}.stderr.log`);
  const stdout = fs.openSync(stdoutPath, "w");
  const stderr = fs.openSync(stderrPath, "w");
  const started = performance.now();
  const startedAt = new Date().toISOString();
  let result;
  try {
    result = await new Promise((resolve) => {
      let timer;
      let forceTimer;
      let timedOut = false;
      let spawnError = null;
      const child = spawn(command, args, {
        cwd,
        detached: true,
        stdio: ["ignore", stdout, stderr],
      });
      const killGroup = (signal) => {
        if (!child.pid) return;
        try {
          process.kill(-child.pid, signal);
        } catch (error) {
          if (error.code !== "ESRCH") spawnError ||= error.message;
        }
      };
      const interrupt = (signal) => {
        // Detached compilers must not survive cancellation of the hook.
        killGroup("SIGKILL");
        process.exit(128 + os.constants.signals[signal]);
      };
      process.on("SIGINT", interrupt);
      process.on("SIGTERM", interrupt);
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          timedOut = true;
          killGroup("SIGTERM");
          forceTimer = setTimeout(() => killGroup("SIGKILL"), 1000);
        }, timeoutMs);
      }
      child.on("error", (error) => {
        spawnError = error.message;
      });
      child.on("close", (code, signal) => {
        clearTimeout(timer);
        const finish = () => {
          process.off("SIGINT", interrupt);
          process.off("SIGTERM", interrupt);
          resolve({
            exit_code: code,
            signal,
            error: spawnError,
            timed_out: timedOut,
          });
        };
        // Retain the group cleanup timer even when the package manager exits first.
        if (timedOut && forceTimer) setTimeout(finish, 1100);
        else finish();
      });
    });
  } finally {
    fs.closeSync(stdout);
    fs.closeSync(stderr);
  }
  return {
    command: [command, ...args],
    cwd,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    duration_ms: Math.round(performance.now() - started),
    timeout_ms: timeoutMs || null,
    ...result,
    stdout: {
      file: path.basename(stdoutPath),
      bytes: fs.statSync(stdoutPath).size,
      sha256: sha256(fs.readFileSync(stdoutPath)),
    },
    stderr: {
      file: path.basename(stderrPath),
      bytes: fs.statSync(stderrPath).size,
      sha256: sha256(fs.readFileSync(stderrPath)),
    },
  };
}

function diagnostics(directory, label) {
  const output = ["stdout", "stderr"]
    .map((stream) =>
      fs.readFileSync(path.join(directory, `${label}.${stream}.log`), "utf8"),
    )
    .join("\n");
  // oxlint-disable-next-line no-control-regex -- Strip ANSI from compiler diagnostics.
  const clean = output.replace(/\x1b\[[0-9;]*m/g, "");
  const values = [];
  for (const line of clean.split(/\r?\n/)) {
    const match =
      line.match(
        /^(.*?)\((\d+),(\d+)\):\s*(error|warning)\s+TS(\d+):\s*(.*)$/,
      ) ||
      line.match(/^(.*?):(\d+):(\d+)\s*-\s*(error|warning)\s+TS(\d+):\s*(.*)$/);
    if (match)
      values.push({
        file: match[1],
        line: Number(match[2]),
        column: Number(match[3]),
        severity: match[4],
        code: `TS${match[5]}`,
        message: match[6],
      });
    else if (/^(error|warning) TS\d+:/.test(line))
      values.push({ message: line });
    else if (/^\s+\S/.test(line) && values.length)
      values.at(-1).message += `\n${line.trim()}`;
  }
  return [
    ...new Map(values.map((value) => [JSON.stringify(value), value])).values(),
  ].sort((left, right) =>
    JSON.stringify(left).localeCompare(JSON.stringify(right)),
  );
}

function passed(result) {
  return (
    result.exit_code === 0 &&
    !result.error &&
    !result.signal &&
    !result.timed_out
  );
}

function compare(baseline, shadow, before, after, inputsBefore, inputsAfter) {
  const baselineKeys = new Set(baseline.map((value) => JSON.stringify(value)));
  const shadowKeys = new Set(shadow.map((value) => JSON.stringify(value)));
  return {
    baseline_only: baseline.filter(
      (value) => !shadowKeys.has(JSON.stringify(value)),
    ),
    shadow_only: shadow.filter(
      (value) => !baselineKeys.has(JSON.stringify(value)),
    ),
    repository_changed:
      JSON.stringify(before) !== JSON.stringify(after) ||
      inputsBefore.sha256 !== inputsAfter.sha256,
  };
}

async function main() {
  if (!["npm", "bun"].includes(runner) || !receiptFile)
    throw new Error("Usage: shadow.js <npm|bun> <receipt-file>");
  const timeout = Number(process.env.PRAGMA_SHADOW_TIMEOUT_SECONDS || 120);
  if (!Number.isFinite(timeout) || timeout <= 0 || timeout * 1000 > 2147483647)
    throw new Error(
      "PRAGMA_SHADOW_TIMEOUT_SECONDS must be positive and at most 2147483.647",
    );
  const started = performance.now();
  const root = git(["rev-parse", "--show-toplevel"]) || cwd;
  const defaultCache = git(["rev-parse", "--git-path", "pragma/shadow"]);
  if (!defaultCache && !process.env.PRAGMA_SHADOW_CACHE_DIR)
    throw new Error(
      "Shadow capture needs a Git repository or PRAGMA_SHADOW_CACHE_DIR",
    );
  const cache = path.resolve(
    process.env.PRAGMA_SHADOW_CACHE_DIR || defaultCache,
  );
  const relativeCache = path.relative(root, cache);
  if (!relativeCache)
    throw new Error(
      "Use a dedicated directory for PRAGMA_SHADOW_CACHE_DIR, rather than the repository root",
    );
  const excludedCache =
    !relativeCache.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relativeCache)
      ? relativeCache
      : null;
  const before = gitState(root, excludedCache);
  fs.mkdirSync(cache, { recursive: true, mode: 0o700 });
  const directory = fs.mkdtempSync(
    path.join(
      cache,
      `${new Date().toISOString().replace(/[:.]/g, "-")}-${before.head?.slice(0, 12) || "unborn"}-`,
    ),
  );
  fs.writeFileSync(receiptFile, directory);
  const metadata = {
    schema_version: 1,
    cache_directory: cache,
    state: "running",
    id: path.basename(directory),
    started_at: new Date().toISOString(),
    repository: {
      root,
      cwd,
      git_dir: git(["rev-parse", "--absolute-git-dir"]),
    },
    git_before: before,
    host: {
      platform: process.platform,
      arch: process.arch,
      release: os.release(),
      cpu_model: os.cpus()[0]?.model,
      cpu_count: os.cpus().length,
      memory_bytes: os.totalmem(),
    },
    runtime: {
      executable: process.execPath,
      pid: process.pid,
      parent_pid: process.ppid,
      version: process.version,
      bun_version: globalThis.Bun?.version || null,
    },
    pragma: {
      root: pragmaRoot,
      version: fs.readFileSync(path.join(pragmaRoot, "VERSION"), "utf8").trim(),
      git: probe("git", ["rev-parse", "HEAD"], pragmaRoot),
      status: probe("git", ["status", "--porcelain=v1"], pragmaRoot),
      source_hashes: Object.fromEntries(
        ["lib/test.sh", "lib/shadow.js"].map((name) => [
          name,
          sha256(fs.readFileSync(path.join(pragmaRoot, name))),
        ]),
      ),
    },
    environment: {
      CI: process.env.CI || null,
      LANG: process.env.LANG || null,
      LC_ALL: process.env.LC_ALL || null,
      TZ: process.env.TZ || null,
    },
    packages: packageVersions(),
    versions: Object.fromEntries(
      [runner, "node", "bun", "git"].map((name) => [
        name,
        probe(name, ["--version"]),
      ]),
    ),
    compilers: Object.fromEntries(
      ["tsc", "tsc-rs"].map((name) => [
        name,
        probe(path.join(cwd, "node_modules/.bin", name), ["--version"]),
      ]),
    ),
    scripts: JSON.parse(fs.readFileSync("package.json", "utf8")).scripts,
    baseline: null,
    shadow: null,
    capture_errors: [],
  };
  writeJson(path.join(directory, "metadata.json"), metadata);
  for (const label of ["baseline", "shadow"]) {
    for (const stream of ["stdout", "stderr"])
      fs.writeFileSync(path.join(directory, `${label}.${stream}.log`), "");
  }
  let inputsBefore = { sha256: null, files: [] };
  try {
    inputsBefore = inputManifest(root, directory, excludedCache);
    writeJson(path.join(directory, "inputs-before.json"), inputsBefore);
    for (const [name, args] of [
      [
        "git-staged.patch",
        [
          "diff",
          "--cached",
          "--binary",
          "--no-color",
          "--no-ext-diff",
          "--no-textconv",
        ],
      ],
      [
        "git-worktree.patch",
        ["diff", "--binary", "--no-color", "--no-ext-diff", "--no-textconv"],
      ],
    ]) {
      // Redirect to files to retain patches of any size without a subprocess buffer limit.
      const fd = fs.openSync(path.join(directory, name), "w");
      try {
        spawnSync("git", args, { cwd: root, stdio: ["ignore", fd, "ignore"] });
      } finally {
        fs.closeSync(fd);
      }
    }
  } catch (error) {
    metadata.capture_errors.push(error.message);
  }
  metadata.baseline = await capture(
    runner,
    ["run", "typecheck"],
    directory,
    "baseline",
    0,
  );
  writeJson(path.join(directory, "metadata.json"), metadata);
  metadata.shadow = await capture(
    runner,
    ["run", "typecheck:shadow"],
    directory,
    "shadow",
    timeout * 1000,
  );
  metadata.git_after = gitState(root, excludedCache);
  let inputsAfter = { sha256: null, files: [] };
  try {
    inputsAfter = inputManifest(root, undefined, excludedCache);
    writeJson(path.join(directory, "inputs-after.json"), inputsAfter);
  } catch (error) {
    metadata.capture_errors.push(error.message);
  }
  const baselineDiagnostics = diagnostics(directory, "baseline");
  const shadowDiagnostics = diagnostics(directory, "shadow");
  const comparison = compare(
    baselineDiagnostics,
    shadowDiagnostics,
    before,
    metadata.git_after,
    inputsBefore,
    inputsAfter,
  );
  const findings = [];
  if (passed(metadata.baseline) !== passed(metadata.shadow))
    findings.push("outcome_difference");
  if (comparison.baseline_only.length || comparison.shadow_only.length)
    findings.push("diagnostic_difference");
  if (metadata.shadow.timed_out) findings.push("shadow_timeout");
  if (metadata.shadow.signal || metadata.shadow.error)
    findings.push("shadow_execution_error");
  if (
    (!passed(metadata.baseline) && !baselineDiagnostics.length) ||
    (!passed(metadata.shadow) && !shadowDiagnostics.length)
  )
    findings.push("unparsed_failure");
  if (comparison.repository_changed)
    findings.push("repository_changed_during_run");
  if (metadata.capture_errors.length) findings.push("capture_error");
  writeJson(path.join(directory, "findings.json"), {
    findings,
    comparison,
    baseline_diagnostics: baselineDiagnostics,
    shadow_diagnostics: shadowDiagnostics,
  });
  metadata.state = "complete";
  metadata.finished_at = new Date().toISOString();
  metadata.duration_ms = Math.round(performance.now() - started);
  fs.writeFileSync(
    path.join(directory, "notes.md"),
    "# Local observations\n\n",
  );
  fs.writeFileSync(
    path.join(directory, "report.md"),
    `# TypeScript shadow run\n\nGit HEAD: ${before.head || "unborn"}\n\nStarted: ${metadata.started_at}\n\nFindings: ${findings.join(", ") || "no differences observed"}\n\n| Check | Exit code | Signal | Duration (ms) |\n| --- | --- | --- | --- |\n| Baseline | ${metadata.baseline.exit_code} | ${metadata.baseline.signal || "none"} | ${metadata.baseline.duration_ms} |\n| Shadow | ${metadata.shadow.exit_code} | ${metadata.shadow.signal || "none"} | ${metadata.shadow.duration_ms} |\n\nFull outputs are in the baseline and shadow stdout/stderr logs. Commands, versions, and Git state are in metadata.json. Diagnostic differences are in findings.json. Add observations to notes.md before sharing a finding.\n`,
  );
  writeJson(path.join(directory, "metadata.json"), metadata);
  if (process.env.PRAGMA_OUTPUT_FORMAT === "human")
    console.log(
      `tsc-rs shadow: ${findings.join(", ") || "no differences observed"}; cached at ${directory}`,
    );
  else
    console.log(
      JSON.stringify({
        v: 1,
        hook: "pre-push",
        step: "shadow",
        cache: directory,
        findings,
        baseline_code: metadata.baseline.exit_code,
        shadow_code: metadata.shadow.exit_code,
      }),
    );
  if (metadata.baseline.exit_code !== null) return metadata.baseline.exit_code;
  return metadata.baseline.signal
    ? 128 + (os.constants.signals[metadata.baseline.signal] || 0)
    : 1;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error) => {
    console.error(`Shadow capture failed: ${error.stack || error.message}`);
    process.exitCode = 125;
  });
