// Collector contract: observations and provenance, with full outputs kept in logs.
const SUMMARY_SCHEMA = "pragma.shadow-summary";
const SUMMARY_SCHEMA_VERSION = 1;

function outcome(result) {
  return {
    exit_code: result.exit_code,
    signal: result.signal,
    timed_out: result.timed_out,
    error: result.error,
  };
}

function captureSummary(result) {
  if (!result) return null;
  return {
    ...outcome(result),
    artifacts: { stdout: result.stdout.file, stderr: result.stderr.file },
  };
}

function comparisonSummary(comparison) {
  return {
    project: comparison.project,
    scope: comparison.scope,
    config: comparison.config ?? null,
    script: comparison.script ?? null,
    baseline: outcome(comparison.baseline),
    shadow: outcome(comparison.shadow),
    baseline_compiler: comparison.baseline_compiler ?? null,
    candidate_compiler: comparison.candidate_compiler ?? null,
    findings: comparison.findings,
    artifacts: {
      baseline_stdout: comparison.baseline.stdout.file,
      baseline_stderr: comparison.baseline.stderr.file,
      shadow_stdout: comparison.shadow.stdout.file,
      shadow_stderr: comparison.shadow.stderr.file,
    },
  };
}

function buildSummary(metadata, findings, artifacts) {
  return {
    schema: SUMMARY_SCHEMA,
    schema_version: SUMMARY_SCHEMA_VERSION,
    run_id: metadata.id,
    started_at: metadata.started_at,
    finished_at: metadata.finished_at,
    state: "complete",
    cache_access: metadata.cache_access ?? null,
    repository: {
      id: metadata.context?.repository_id ?? null,
      root: metadata.repository.root,
      git_dir: metadata.repository.git_dir,
      head: metadata.git_before.head,
    },
    worktree_id: metadata.context?.worktree_id ?? null,
    context: metadata.context ?? { thread_id: null, thread_source: null },
    producer: {
      name: "pragma",
      version: metadata.pragma.version,
      git: metadata.pragma.git,
      source_hashes: metadata.pragma.source_hashes,
    },
    baseline_policy: metadata.baseline_policy,
    baseline: captureSummary(metadata.baseline),
    shadow: captureSummary(metadata.shadow),
    compilers: metadata.compilers,
    findings: findings.findings,
    comparisons: metadata.comparisons.map(comparisonSummary),
    skipped: metadata.skipped,
    capture_errors: metadata.capture_errors,
    artifacts,
  };
}

module.exports = {
  buildSummary,
  captureSummary,
  SUMMARY_SCHEMA,
  SUMMARY_SCHEMA_VERSION,
};
