#!/usr/bin/env node
// Read completed receipts without changing caches or creating reporting state.
const fs = require("node:fs");
const path = require("node:path");
const { isDeepStrictEqual } = require("node:util");
const { buildSummary, captureSummary } = require("../lib/shadow-summary.js");
const { resolveCache } = require("../lib/shadow-cache.js");

function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function nonempty(value) {
  return typeof value === "string" && value.length > 0;
}

function stringList(value) {
  return (
    Array.isArray(value) && value.every((item) => typeof item === "string")
  );
}

function relativeArtifact(value) {
  return (
    nonempty(value) &&
    !path.posix.isAbsolute(value) &&
    !path.win32.isAbsolute(value) &&
    !value.split(/[\\/]/).includes("..")
  );
}

function validateOutcome(value) {
  requireValue(object(value), "comparison outcome must be an object");
  requireValue(
    value.exit_code === null || Number.isInteger(value.exit_code),
    "comparison exit code must be an integer or null",
  );
  requireValue(
    value.signal === null || typeof value.signal === "string",
    "comparison signal must be a string or null",
  );
  requireValue(
    typeof value.timed_out === "boolean",
    "comparison timeout state must be a boolean",
  );
  requireValue(
    value.error === null || typeof value.error === "string",
    "comparison error must be a string or null",
  );
}

function validateCapture(value, legacy) {
  if (value === null || (legacy && value === undefined)) return;
  validateOutcome(value);
  if (legacy) {
    for (const stream of ["stdout", "stderr"])
      requireValue(
        object(value[stream]) && relativeArtifact(value[stream].file),
        "root capture log paths must be relative",
      );
  } else {
    requireValue(
      object(value.artifacts),
      "root capture artifacts must be an object",
    );
    for (const stream of ["stdout", "stderr"])
      requireValue(
        relativeArtifact(value.artifacts[stream]),
        `root capture ${stream} artifact path must be relative`,
      );
  }
}

function validateComparison(value, legacy) {
  requireValue(
    object(value) && nonempty(value.project) && nonempty(value.scope),
    "comparison project and scope are required",
  );
  requireValue(
    stringList(value.findings),
    "comparison findings must be strings",
  );
  for (const compiler of ["baseline", "shadow"]) {
    validateOutcome(value[compiler]);
    if (legacy) {
      for (const stream of ["stdout", "stderr"])
        requireValue(
          object(value[compiler][stream]) &&
            relativeArtifact(value[compiler][stream].file),
          "legacy comparison log paths must be relative",
        );
    }
  }
  if (!legacy) {
    requireValue(
      object(value.artifacts),
      "comparison artifacts must be an object",
    );
    for (const key of [
      "baseline_stdout",
      "baseline_stderr",
      "shadow_stdout",
      "shadow_stderr",
    ])
      requireValue(
        relativeArtifact(value.artifacts[key]),
        `comparison ${key} artifact path must be relative`,
      );
  }
}

function validateRunFields(value) {
  requireValue(nonempty(value.id || value.run_id), "run ID is required");
  for (const name of ["started_at", "finished_at"])
    requireValue(
      nonempty(value[name]) && Number.isFinite(Date.parse(value[name])),
      `${name} must be a timestamp`,
    );
  requireValue(
    object(value.repository) && nonempty(value.repository.root),
    "repository root is required",
  );
  requireValue(
    value.repository.git_dir === null || nonempty(value.repository.git_dir),
    "repository Git directory must be a path or null",
  );
  requireValue(object(value.compilers), "compiler identities are required");
  requireValue(
    Array.isArray(value.comparisons),
    "comparisons must be an array",
  );
  requireValue(Array.isArray(value.skipped), "skipped checks must be an array");
  requireValue(
    stringList(value.capture_errors),
    "capture errors must be strings",
  );
}

function validateSummary(value) {
  requireValue(object(value), "summary must be an object");
  requireValue(
    value.schema === "pragma.shadow-summary" && value.schema_version === 1,
    "unsupported shadow summary schema/version",
  );
  requireValue(value.state === "complete", "summary is incomplete");
  validateRunFields(value);
  requireValue(nonempty(value.run_id), "summary run ID is required");
  requireValue(
    object(value.producer) &&
      nonempty(value.producer.version) &&
      object(value.producer.source_hashes),
    "summary producer provenance is required",
  );
  requireValue(
    value.repository.head === null || nonempty(value.repository.head),
    "summary Git HEAD must be a string or null",
  );
  requireValue(
    value.producer.name === "pragma" && object(value.producer.git),
    "summary producer identity is required",
  );
  requireValue(stringList(value.findings), "summary findings must be strings");
  requireValue(object(value.artifacts), "summary artifacts must be an object");
  for (const key of ["metadata", "findings"])
    requireValue(
      value.artifacts[key] === `${key}.json`,
      `summary ${key} artifact must be ${key}.json`,
    );
  requireValue(
    Object.hasOwn(value.repository, "id") &&
      Object.hasOwn(value, "worktree_id"),
    "summary repository/worktree identities are required",
  );
  for (const identity of [value.repository.id, value.worktree_id])
    requireValue(
      identity === null || nonempty(identity),
      "repository/worktree identities must be strings or null",
    );
  requireValue(object(value.context), "summary context is required");
  requireValue(
    value.context.thread_id === null || nonempty(value.context.thread_id),
    "thread identity must be a string or null",
  );
  requireValue(
    value.context.thread_source === null ||
      ["PRAGMA_THREAD_ID", "CODEX_THREAD_ID", "worktree-owner"].includes(
        value.context.thread_source,
      ),
    "thread source must be supported or null",
  );
  requireValue(nonempty(value.baseline_policy), "baseline policy is required");
  for (const key of ["baseline", "shadow"]) {
    requireValue(
      Object.hasOwn(value, key),
      `summary root ${key} capture is required`,
    );
    validateCapture(value[key], false);
  }
  for (const comparison of value.comparisons)
    validateComparison(comparison, false);
}

function validateLegacy(metadata, findings) {
  validateRunFields(metadata);
  requireValue(
    object(metadata.pragma) &&
      nonempty(metadata.pragma.version) &&
      object(metadata.pragma.source_hashes),
    "legacy producer provenance is required",
  );
  requireValue(
    object(metadata.git_before) &&
      (metadata.git_before.head === null || nonempty(metadata.git_before.head)),
    "legacy Git HEAD is required",
  );
  requireValue(
    object(findings) && stringList(findings.findings),
    "legacy findings must contain a findings array",
  );
  if (findings.schema !== undefined || findings.schema_version !== undefined)
    requireValue(
      findings.schema === "pragma.shadow-findings" &&
        findings.schema_version === 1,
      "unsupported shadow findings schema/version",
    );
  for (const key of ["baseline", "shadow"])
    validateCapture(metadata[key], true);
  for (const comparison of metadata.comparisons)
    validateComparison(comparison, true);
}

function readJson(location) {
  let contents;
  try {
    contents = fs.readFileSync(location, "utf8");
  } catch (error) {
    throw new Error(`cannot read ${path.basename(location)} (${error.code})`);
  }
  try {
    return JSON.parse(contents);
  } catch {
    throw new Error(`${path.basename(location)} is malformed JSON`);
  }
}

function validateReceiptArtifacts(receipt, summary) {
  const known = [summary.artifacts.metadata, summary.artifacts.findings];
  for (const capture of [summary.baseline, summary.shadow]) {
    if (capture)
      for (const stream of ["stdout", "stderr"])
        known.push(capture.artifacts[stream]);
  }
  for (const comparison of summary.comparisons) {
    for (const key of [
      "baseline_stdout",
      "baseline_stderr",
      "shadow_stdout",
      "shadow_stderr",
    ])
      known.push(comparison.artifacts[key]);
  }
  for (const file of new Set(known)) {
    try {
      const location = path.join(receipt, file);
      requireValue(
        fs.statSync(location).isFile(),
        `${file} is not a regular artifact file`,
      );
      fs.accessSync(location, fs.constants.R_OK);
    } catch (error) {
      throw new Error(
        `artifact ${file} is unavailable (${error.code || error.message})`,
      );
    }
  }
}

function validateIdentity(metadata, summary) {
  requireValue(
    object(metadata.repository) &&
      summary.repository.root === metadata.repository.root &&
      summary.repository.git_dir === metadata.repository.git_dir,
    "summary repository identity does not match metadata",
  );
  requireValue(
    summary.baseline_policy === metadata.baseline_policy,
    "summary baseline policy does not match metadata",
  );
  for (const key of ["baseline", "shadow"]) {
    validateCapture(metadata[key], true);
    requireValue(
      isDeepStrictEqual(summary[key], captureSummary(metadata[key])),
      `summary root ${key} outcome does not match metadata`,
    );
  }
  const context = metadata.context || { thread_id: null, thread_source: null };
  requireValue(
    isDeepStrictEqual(summary.context, context),
    "summary thread context does not match metadata",
  );
  requireValue(
    summary.repository.id === (context.repository_id ?? null) &&
      summary.worktree_id === (context.worktree_id ?? null),
    "summary repository/worktree IDs do not match metadata context",
  );
}

function readReceipt(receipt) {
  const metadata = readJson(path.join(receipt, "metadata.json"));
  requireValue(
    object(metadata) && metadata.schema_version === 2,
    "unsupported shadow metadata schema/version",
  );
  requireValue(metadata.state === "complete", "metadata is incomplete");
  const summaryPath = path.join(receipt, "summary.json");
  let summary;
  if (fs.existsSync(summaryPath)) summary = readJson(summaryPath);
  else {
    const findings = readJson(path.join(receipt, "findings.json"));
    validateLegacy(metadata, findings);
    const artifacts = { metadata: "metadata.json", findings: "findings.json" };
    for (const name of [
      "report.md",
      "notes.md",
      "inputs-before.json",
      "inputs-after.json",
      "git-staged.patch",
      "git-worktree.patch",
    ])
      if (fs.existsSync(path.join(receipt, name))) artifacts[name] = name;
    summary = buildSummary(metadata, findings, artifacts);
  }
  validateSummary(summary);
  validateIdentity(metadata, summary);
  validateReceiptArtifacts(receipt, summary);
  requireValue(
    summary.run_id === metadata.id,
    "summary run ID does not match metadata",
  );
  return { receipt, summary };
}

function repositoryCache(directory) {
  return resolveCache(directory).directory;
}

function options(argv) {
  const inputs = [];
  let latest = false;
  for (let index = 0; index < argv.length; index++) {
    const option = argv[index];
    if (option === "--latest") latest = true;
    else if (["--cache", "--repo"].includes(option)) {
      const value = argv[++index];
      requireValue(
        nonempty(value) && !value.startsWith("--"),
        `${option} requires a path`,
      );
      inputs.push({ kind: option.slice(2), directory: path.resolve(value) });
    } else throw new Error(`unknown argument: ${option}`);
  }
  if (!inputs.length) inputs.push({ kind: "repo", directory: process.cwd() });
  return { inputs, latest };
}

function newest(left, right) {
  return (
    Date.parse(right.summary.started_at) -
      Date.parse(left.summary.started_at) ||
    right.summary.run_id.localeCompare(left.summary.run_id) ||
    left.receipt.localeCompare(right.receipt)
  );
}

function group(run) {
  const { summary } = run;
  return JSON.stringify([
    summary.repository.id || summary.repository.root,
    summary.worktree_id ||
      summary.repository.git_dir ||
      summary.repository.root,
    summary.context?.thread_id ?? null,
  ]);
}

function collect({ inputs, latest }) {
  const runs = [],
    skipped = [],
    seen = new Set();
  for (const input of inputs) {
    let cache, entries;
    try {
      cache =
        input.kind === "repo"
          ? repositoryCache(input.directory)
          : input.directory;
      cache = fs.realpathSync(cache);
      entries = fs
        .readdirSync(cache, { withFileTypes: true })
        .sort((left, right) => left.name.localeCompare(right.name));
    } catch (error) {
      skipped.push({
        receipt: cache || input.directory,
        reason: error.message,
      });
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
      let receipt = path.join(cache, entry.name);
      if (seen.has(receipt)) continue;
      try {
        if (!fs.statSync(receipt).isDirectory()) continue;
        receipt = fs.realpathSync(receipt);
        if (seen.has(receipt)) continue;
        seen.add(receipt);
        runs.push(readReceipt(receipt));
      } catch (error) {
        if (!seen.has(receipt)) seen.add(receipt);
        skipped.push({ receipt, reason: error.message });
      }
    }
  }
  runs.sort(newest);
  skipped.sort(
    (left, right) =>
      left.receipt.localeCompare(right.receipt) ||
      left.reason.localeCompare(right.reason),
  );
  const groups = new Set();
  return {
    schema: "pragma.shadow-collection",
    schema_version: 1,
    generated_at: new Date().toISOString(),
    runs: latest
      ? runs.filter((run) => {
          const key = group(run);
          if (groups.has(key)) return false;
          groups.add(key);
          return true;
        })
      : runs,
    skipped,
  };
}

let parsed;
try {
  parsed = options(process.argv.slice(2));
} catch (error) {
  console.error(
    `${error.message}\nUsage: collect-shadow.js [--cache DIR]... [--repo PATH]... [--latest]`,
  );
  process.exitCode = 2;
}
if (parsed) console.log(JSON.stringify(collect(parsed), null, 2));
