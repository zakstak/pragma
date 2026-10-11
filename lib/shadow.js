// Run a project-owned compiler comparison and retain a local receipt.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");
const { performance } = require("node:perf_hooks");
const { createRequire } = require("node:module");

const { scriptPlan, readOnlyArgs } = require("./shadow-plan.js");
const { getThreadContext } = require("./thread-context.js");
const { buildSummary } = require("./shadow-summary.js");
const [runner, receiptFile, mode = "required"] = process.argv.slice(2);
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

async function capture(
  command,
  args,
  directory,
  label,
  timeoutMs,
  workingDirectory = cwd,
) {
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
        cwd: workingDirectory,
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
    cwd: workingDirectory,
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

function discoverProjects(root, excludedLocation) {
  const projects = [];
  projects.discovery_errors = [];
  const excluded = new Set([
    ".git",
    "node_modules",
    "target",
    "dist",
    "build",
    ".cache",
    ".coordination",
    ".venv",
    "vendor",
    "coverage",
    "tests",
    "test",
    "fixtures",
    "__fixtures__",
    "baselines",
  ]);
  function visit(directory, depth) {
    if (
      excludedLocation &&
      (directory === excludedLocation ||
        directory.startsWith(`${excludedLocation}${path.sep}`))
    )
      return;
    let entries;
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      projects.discovery_errors.push({
        project: path.relative(root, directory) || ".",
        scope: "discovery",
        reason: `Cannot read project directory: ${error.message}`,
      });
      return;
    }
    const packagePath = path.join(directory, "package.json");
    let pkg = null,
      packageError = null;
    if (
      entries.some((entry) => entry.name === "package.json" && entry.isFile())
    ) {
      try {
        pkg = JSON.parse(fs.readFileSync(packagePath, "utf8"));
        if (!pkg || typeof pkg !== "object" || Array.isArray(pkg))
          throw new Error("package.json must contain an object");
        for (const name of ["typecheck", "typecheck:shadow"]) {
          if (
            pkg.scripts &&
            Object.hasOwn(pkg.scripts, name) &&
            (typeof pkg.scripts[name] !== "string" || !pkg.scripts[name].trim())
          )
            throw new Error(`scripts.${name} must be a nonempty string`);
        }
      } catch (error) {
        packageError = error.message;
      }
    }
    const configs = entries
      .filter(
        (entry) =>
          entry.isFile() &&
          /^(?:ts|js)config(?:[.-].*)?\.jsonc?$/.test(entry.name),
      )
      .map((entry) => entry.name)
      .sort();
    if (pkg || packageError || configs.length)
      projects.push({
        directory,
        package: pkg,
        package_error: packageError,
        configs,
      });
    if (depth >= 8) return;
    for (const entry of entries) {
      if (
        entry.isDirectory() &&
        !entry.name.startsWith(".") &&
        !excluded.has(entry.name)
      )
        visit(path.join(directory, entry.name), depth + 1);
    }
  }
  visit(root, 0);
  return projects;
}

function localCompiler(directory, root, name = "tsc") {
  let current = directory;
  while (true) {
    const location = path.join(current, "node_modules", ".bin", name);
    try {
      fs.accessSync(location, fs.constants.X_OK);
      return location;
    } catch {
      /* Workspace dependencies may be hoisted to a parent package. */
    }
    if (current === root || current === path.dirname(current)) return null;
    current = path.dirname(current);
  }
}

function fileIdentity(location) {
  try {
    const realpath = fs.realpathSync(location);
    return {
      path: location,
      realpath,
      sha256: sha256(fs.readFileSync(realpath)),
    };
  } catch (error) {
    return { path: location, unavailable: error.message };
  }
}

function projectCompilerIdentity(executable, directory, nativeComparison) {
  const name = nativeComparison ? "tsc-rs" : "typescript";
  const identity = {
    kind: nativeComparison ? "project-tsc-rs" : "project-typescript",
    executable,
    executable_identity: executable ? fileIdentity(executable) : null,
    version: executable ? probe(executable, ["--version"], directory) : null,
    package: null,
    native_package: null,
    native_binary: null,
  };
  try {
    const resolve = createRequire(path.join(directory, "package.json"));
    const location = resolve.resolve(`${name}/package.json`);
    const pkg = JSON.parse(fs.readFileSync(location, "utf8"));
    identity.package = {
      ...fileIdentity(location),
      name: pkg.name,
      version: pkg.version,
      git_head: pkg.gitHead || null,
    };
    if (nativeComparison) {
      const nativeName = `@tsc-rs/${process.platform}-${process.arch}`;
      const nativeLocation = createRequire(location).resolve(
        `${nativeName}/package.json`,
      );
      const nativePkg = JSON.parse(fs.readFileSync(nativeLocation, "utf8"));
      identity.native_package = {
        ...fileIdentity(nativeLocation),
        name: nativePkg.name,
        version: nativePkg.version,
      };
      identity.native_binary = fileIdentity(
        path.join(
          path.dirname(nativeLocation),
          "lib",
          process.platform === "win32" ? "tsc.exe" : "tsc",
        ),
      );
    }
  } catch {
    // Standalone compiler executables remain identifiable without npm metadata.
  }
  return identity;
}

function compilerProvenance() {
  const executable = path.join(pragmaRoot, "bin", "tsc-rs");
  const receipt = path.join(pragmaRoot, "bin", "tsc-rs.receipt.json");
  let installed = false,
    receiptData = null,
    receiptHash = null,
    wrapperHash = null;
  try {
    fs.accessSync(executable, fs.constants.X_OK);
    installed = true;
    wrapperHash = sha256(fs.readFileSync(executable));
  } catch {
    /* Missing compiler becomes an advisory receipt, never a gate. */
  }
  try {
    const bytes = fs.readFileSync(receipt);
    receiptData = JSON.parse(bytes);
    receiptHash = sha256(bytes);
  } catch {
    /* Older project-owned shadow overrides need no Pragma install receipt. */
  }
  return {
    executable,
    installed,
    wrapper_sha256: wrapperHash,
    receipt_path: receipt,
    receipt_sha256: receiptHash,
    receipt: receiptData,
    version: installed ? probe(executable, ["--version"]) : null,
  };
}

async function captureCommands(commands, directory, label, timeoutMs) {
  const results = [];
  for (const [index, command] of commands.entries()) {
    const result = await capture(
      command.executable,
      command.args,
      directory,
      `${label}-${index}`,
      timeoutMs,
      command.cwd,
    );
    results.push(result);
    if (!passed(result)) break; // Match the supported && chain's short-circuiting.
  }
  for (const stream of ["stdout", "stderr"]) {
    const location = path.join(directory, `${label}.${stream}.log`);
    fs.writeFileSync(location, "");
    for (const result of results)
      fs.appendFileSync(
        location,
        fs.readFileSync(path.join(directory, result[stream].file)),
      );
  }
  const last = results.at(-1);
  return {
    ...last,
    command: results.map((result) => result.command),
    commands: results,
    duration_ms: results.reduce((sum, result) => sum + result.duration_ms, 0),
    stdout: artifact(directory, label, "stdout"),
    stderr: artifact(directory, label, "stderr"),
  };
}

function artifact(directory, label, stream) {
  const file = `${label}.${stream}.log`,
    bytes = fs.readFileSync(path.join(directory, file));
  return { file, bytes: bytes.length, sha256: sha256(bytes) };
}

function observation(directory, baselineLabel, shadowLabel, baseline, shadow) {
  const baselineDiagnostics = diagnostics(directory, baselineLabel);
  const shadowDiagnostics = diagnostics(directory, shadowLabel);
  const comparison = compare(
    baselineDiagnostics,
    shadowDiagnostics,
    null,
    null,
    { sha256: null },
    { sha256: null },
  );
  const findings = [];
  if (passed(baseline) !== passed(shadow)) findings.push("outcome_difference");
  if (comparison.baseline_only.length || comparison.shadow_only.length)
    findings.push("diagnostic_difference");
  if (shadow.timed_out) findings.push("shadow_timeout");
  if (shadow.signal || shadow.error) findings.push("shadow_execution_error");
  if (
    (!passed(baseline) && !baselineDiagnostics.length) ||
    (!passed(shadow) && !shadowDiagnostics.length)
  )
    findings.push("unparsed_failure");
  return {
    findings,
    comparison,
    baseline_diagnostics: baselineDiagnostics,
    shadow_diagnostics: shadowDiagnostics,
  };
}

async function main() {
  if (
    !["npm", "bun"].includes(runner) ||
    !receiptFile ||
    !["required", "advisory"].includes(mode)
  )
    throw new Error(
      "Usage: shadow.js <npm|bun> <receipt-file> [required|advisory]",
    );
  const timeout = Number(process.env.PRAGMA_SHADOW_TIMEOUT_SECONDS || 120);
  if (!Number.isFinite(timeout) || timeout <= 0 || timeout * 1000 > 2147483647)
    throw new Error(
      "PRAGMA_SHADOW_TIMEOUT_SECONDS must be positive and at most 2147483.647",
    );
  const root = git(["rev-parse", "--show-toplevel"]) || cwd;
  const context = getThreadContext(root);
  const initiallyDiscovered = discoverProjects(
    cwd,
    process.env.PRAGMA_SHADOW_CACHE_DIR
      ? path.resolve(process.env.PRAGMA_SHADOW_CACHE_DIR)
      : null,
  );
  // The authoritative root gate is independent of advisory discovery filters.
  let scripts = {};
  try {
    const pkg = JSON.parse(
      fs.readFileSync(path.join(cwd, "package.json"), "utf8"),
    );
    scripts = pkg.scripts || {};
  } catch (error) {
    if (mode === "required")
      throw new Error(
        `Cannot read authoritative package scripts: ${error.message}`,
      );
  }
  if (
    mode === "required" &&
    (typeof scripts.typecheck !== "string" || !scripts.typecheck.trim())
  )
    throw new Error(
      "Required shadow capture has no authoritative typecheck script",
    );
  if (
    mode === "advisory" &&
    !scripts.typecheck &&
    !initiallyDiscovered.discovery_errors.length &&
    !initiallyDiscovered.some(
      (project) =>
        project.package_error ||
        project.configs.length ||
        ["typecheck", "check", "check:types", "typecheck:ts"].some(
          (name) => typeof project.package?.scripts?.[name] === "string",
        ),
    )
  )
    return 0;
  const started = performance.now();
  const defaultCache = git(["rev-parse", "--git-path", "pragma/shadow"]);
  if (!defaultCache && !process.env.PRAGMA_SHADOW_CACHE_DIR)
    throw new Error(
      "Shadow capture needs a Git repository or PRAGMA_SHADOW_CACHE_DIR",
    );
  const cache = path.resolve(
    process.env.PRAGMA_SHADOW_CACHE_DIR || defaultCache,
  );
  const relativeCache = path.relative(root, cache);
  if (root.startsWith(`${cache}${path.sep}`))
    throw new Error("PRAGMA_SHADOW_CACHE_DIR must not contain the repository");
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
    schema_version: 2,
    cache_directory: cache,
    state: "running",
    id: path.basename(directory),
    context,
    started_at: new Date().toISOString(),
    baseline_policy:
      mode === "required" ? "project-script-blocking" : "advisory-only",
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
        [
          "lib/test.sh",
          "lib/shadow.js",
          "lib/shadow-plan.js",
          "lib/shadow-summary.js",
          "lib/thread-context.js",
        ].map((name) => [
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
    compilers: {
      tsc: probe(
        localCompiler(cwd, root) || path.join(cwd, "node_modules/.bin/tsc"),
        ["--version"],
      ),
      "tsc-rs": compilerProvenance(),
    },
    scripts,
    baseline: null,
    shadow: null,
    comparisons: [],
    skipped: [],
    capture_errors: [],
  };
  writeJson(path.join(directory, "metadata.json"), metadata);
  for (const label of ["baseline", "shadow"])
    for (const stream of ["stdout", "stderr"])
      fs.writeFileSync(path.join(directory, `${label}.${stream}.log`), "");
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
  if (scripts.typecheck)
    metadata.baseline = await capture(
      runner,
      ["run", "typecheck"],
      directory,
      "baseline",
      mode === "required" ? 0 : timeout * 1000,
    );
  writeJson(path.join(directory, "metadata.json"), metadata);
  // Discover again after the authoritative script prepares generated configs.
  const projects = discoverProjects(cwd, cache);
  metadata.skipped.push(...projects.discovery_errors);
  const compiler = metadata.compilers["tsc-rs"];
  for (const project of projects) {
    const projectScope = path.relative(root, project.directory) || ".";
    const projectScripts = project.package?.scripts || {};
    const ordinaryScript = [
      "typecheck",
      "check",
      "check:types",
      "typecheck:ts",
    ].find(
      (name) =>
        typeof projectScripts[name] === "string" && projectScripts[name].trim(),
    );
    if (project.package_error) {
      metadata.skipped.push({
        project: projectScope,
        reason: project.package_error,
      });
      continue;
    }
    if (projectScripts["typecheck:shadow"] && projectScripts.typecheck) {
      const index = metadata.comparisons.length;
      const isRoot = project.directory === cwd && metadata.baseline;
      const baselineLabel = isRoot
        ? "baseline"
        : `comparison-${index}-baseline`;
      const shadowLabel = isRoot ? "shadow" : `comparison-${index}-shadow`;
      const projectRunner =
        fs.existsSync(path.join(project.directory, "bun.lock")) ||
        fs.existsSync(path.join(project.directory, "bun.lockb"))
          ? "bun"
          : runner;
      const baseline = isRoot
        ? metadata.baseline
        : await capture(
            projectRunner,
            ["run", "typecheck"],
            directory,
            baselineLabel,
            timeout * 1000,
            project.directory,
          );
      const shadow = await capture(
        projectRunner,
        ["run", "typecheck:shadow"],
        directory,
        shadowLabel,
        timeout * 1000,
        project.directory,
      );
      if (isRoot) metadata.shadow = shadow;
      metadata.comparisons.push({
        project: projectScope,
        scope: "project-owned-script",
        baseline,
        shadow,
        ...observation(directory, baselineLabel, shadowLabel, baseline, shadow),
      });
      continue;
    }
    let plan = ordinaryScript
      ? scriptPlan(projectScripts[ordinaryScript])
      : {
          supported: false,
          commands: [],
          reason: "no project typecheck script",
        };
    const nativePlan = ordinaryScript
      ? scriptPlan(projectScripts[ordinaryScript], "tsc-rs")
      : null;
    const nativeComparison = !plan.supported && nativePlan?.supported;
    if (nativeComparison) plan = nativePlan;
    if (ordinaryScript && !plan.supported)
      metadata.skipped.push({
        project: projectScope,
        scope: "project-script",
        reason: plan.reason,
      });
    const candidates = plan.supported
      ? plan.commands.map((args) => ({
          args,
          scope: nativeComparison ? "native-version-comparison" : "direct-tsc",
          config: null,
        }))
      : project.configs.map((config) => ({
          args: ["--project", config],
          scope: "typescript-config-only",
          config,
        }));
    for (const candidate of candidates) {
      const index = metadata.comparisons.length;
      if (!compiler.installed) {
        metadata.skipped.push({
          project: projectScope,
          config: candidate.config,
          scope: candidate.scope,
          reason: "Pragma-owned tsc-rs is not installed",
        });
        continue;
      }
      const local = localCompiler(
        project.directory,
        root,
        nativeComparison ? "tsc-rs" : "tsc",
      );
      const rootDirect =
        project.directory === cwd && plan.supported && metadata.baseline;
      if (!rootDirect && !local) {
        metadata.skipped.push({
          project: projectScope,
          config: candidate.config,
          scope: candidate.scope,
          reason: "project-local TypeScript compiler is unavailable",
        });
        continue;
      }
      const baselineCompiler = projectCompilerIdentity(
        local,
        project.directory,
        nativeComparison,
      );
      const configNames = new Set(project.configs);
      const inputCommands = rootDirect
        ? candidates.map((item) => item.args)
        : [candidate.args];
      for (const inputArgs of inputCommands) {
        for (const [argIndex, arg] of inputArgs.entries()) {
          const option = arg.toLowerCase();
          if (
            ["--project", "-project", "--p", "-p"].includes(option) &&
            inputArgs[argIndex + 1]
          )
            configNames.add(inputArgs[argIndex + 1]);
          else if (/^-{1,2}(?:project|p)=/.test(option))
            configNames.add(arg.slice(arg.indexOf("=") + 1));
        }
      }
      const configInputs = [...configNames].map((config) => {
        let location = path.resolve(project.directory, config);
        try {
          if (fs.statSync(location).isDirectory())
            location = path.join(location, "tsconfig.json");
          const bytes = fs.readFileSync(location);
          const relative = path.relative(root, location);
          // Save only repository inputs; external config identity still has a hash.
          if (
            !relative.startsWith(`..${path.sep}`) &&
            !path.isAbsolute(relative)
          ) {
            const saved = path.join(directory, "project-configs", relative);
            fs.mkdirSync(path.dirname(saved), { recursive: true, mode: 0o700 });
            fs.writeFileSync(saved, bytes);
          }
          return { path: relative, sha256: sha256(bytes) };
        } catch (error) {
          return { path: location, unavailable: error.message };
        }
      });
      const outputDirectory = path.join(directory, `compiler-state-${index}`);
      fs.mkdirSync(outputDirectory, { mode: 0o700 });
      const baselineLabel = rootDirect
        ? "baseline"
        : `comparison-${index}-baseline`;
      const shadowLabel = rootDirect ? "shadow" : `comparison-${index}-shadow`;
      const args = readOnlyArgs(candidate.args, outputDirectory, "shadow");
      if (rootDirect) {
        // Run an entire direct-tsc && chain once, preserving short-circuit behavior.
        if (metadata.shadow) continue;
        const commands = candidates.map((item, commandIndex) => ({
          executable: compiler.executable,
          args: readOnlyArgs(item.args, outputDirectory, commandIndex),
          cwd: project.directory,
        }));
        metadata.shadow = await captureCommands(
          commands,
          directory,
          "shadow",
          timeout * 1000,
        );
      }
      const baseline = rootDirect
        ? metadata.baseline
        : await capture(
            local,
            readOnlyArgs(candidate.args, outputDirectory, "baseline"),
            directory,
            baselineLabel,
            timeout * 1000,
            project.directory,
          );
      const shadow = rootDirect
        ? metadata.shadow
        : await capture(
            compiler.executable,
            args,
            directory,
            shadowLabel,
            timeout * 1000,
            project.directory,
          );
      metadata.comparisons.push({
        project: projectScope,
        scope: candidate.scope,
        script: ordinaryScript || null,
        config: candidate.config,
        input_argv: candidate.args,
        input_commands: rootDirect
          ? candidates.map((item) => item.args)
          : [candidate.args],
        config_inputs: configInputs,
        baseline_compiler: baselineCompiler,
        candidate_compiler: compiler,
        baseline,
        shadow,
        ...observation(directory, baselineLabel, shadowLabel, baseline, shadow),
      });
      writeJson(path.join(directory, "metadata.json"), metadata);
    }
  }
  metadata.git_after = gitState(root, excludedCache);
  let inputsAfter = { sha256: null, files: [] };
  try {
    inputsAfter = inputManifest(root, undefined, excludedCache);
    writeJson(path.join(directory, "inputs-after.json"), inputsAfter);
  } catch (error) {
    metadata.capture_errors.push(error.message);
  }
  const findings = [
    ...new Set(metadata.comparisons.flatMap((result) => result.findings)),
  ];
  const rootComparison = metadata.comparisons.find(
    (result) => result.project === (path.relative(root, cwd) || "."),
  );
  const comparison = {
    ...(rootComparison?.comparison || { baseline_only: [], shadow_only: [] }),
    repository_changed:
      JSON.stringify(before) !== JSON.stringify(metadata.git_after) ||
      inputsBefore.sha256 !== inputsAfter.sha256,
  };
  if (metadata.skipped.length) findings.push("shadow_coverage_incomplete");
  if (comparison.repository_changed)
    findings.push("repository_changed_during_run");
  if (metadata.capture_errors.length) findings.push("capture_error");
  const findingReport = {
    schema: "pragma.shadow-findings",
    schema_version: 1,
    findings,
    comparison,
    baseline_diagnostics: rootComparison?.baseline_diagnostics || [],
    shadow_diagnostics: rootComparison?.shadow_diagnostics || [],
    projects: metadata.comparisons.map((result) => ({
      project: result.project,
      config: result.config,
      scope: result.scope,
      findings: result.findings,
    })),
    skipped: metadata.skipped,
  };
  writeJson(path.join(directory, "findings.json"), findingReport);
  metadata.finished_at = new Date().toISOString();
  metadata.duration_ms = Math.round(performance.now() - started);
  fs.writeFileSync(
    path.join(directory, "notes.md"),
    "# Local observations\n\n",
  );
  fs.writeFileSync(
    path.join(directory, "report.md"),
    `# TypeScript shadow run\n\nGit HEAD: ${before.head || "unborn"}\n\nStarted: ${metadata.started_at}\n\nBaseline policy: ${metadata.baseline_policy}\n\nFindings: ${findings.join(", ") || "no differences observed"}\n\nCompared: ${metadata.comparisons.length} project/config checks. Unsupported or unavailable checks: ${metadata.skipped.length}.\n\nComplete logs, commands, compiler provenance and scope are retained in metadata.json and findings.json. TS-only config checks do not validate framework transforms or substitute for the project's gate. Add observations to notes.md before sharing a finding.\n`,
  );
  const artifacts = {
    metadata: "metadata.json",
    findings: "findings.json",
    summary: "summary.json",
    report: "report.md",
    notes: "notes.md",
  };
  for (const name of [
    "inputs-before.json",
    "inputs-after.json",
    "git-staged.patch",
    "git-worktree.patch",
  ]) {
    if (fs.existsSync(path.join(directory, name))) artifacts[name] = name;
  }
  writeJson(
    path.join(directory, "summary.json"),
    buildSummary(metadata, findingReport, artifacts),
  );
  // Publish completion last so collectors never observe an incomplete summary.
  metadata.state = "complete";
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
        compared: metadata.comparisons.length,
        skipped: metadata.skipped.length,
        baseline_code: metadata.baseline?.exit_code ?? null,
        shadow_code: metadata.shadow?.exit_code ?? null,
      }),
    );
  if (mode === "advisory" || !metadata.baseline) return 0;
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
