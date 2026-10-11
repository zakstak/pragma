#!/usr/bin/env bash
# Exercise real commits and pushes against a local bare repository.
set -euo pipefail

PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap_args=(--agent)
required_tools=(git prek kingfisher shfmt shellcheck prettier oxlint npm node go goimports golangci-lint yamllint)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing integration-test dependency: %s\n' "$tool" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
export PRAGMA_GLOBAL_BIN_DIR="$tmp_dir/global-bin"
mkdir -p "$PRAGMA_GLOBAL_BIN_DIR"
for core_tool in prek kingfisher; do
  cp "$(command -v "$core_tool")" "$PRAGMA_GLOBAL_BIN_DIR/$core_tool"
done
repo_dir="$tmp_dir/target repo"
remote_dir="$tmp_dir/remote.git"
log_file="$tmp_dir/hook.log"
unset PRAGMA_HOME PRAGMA_SKIP_TESTS PRAGMA_SKIP_INTERNAL_BIN_PATH
export PRAGMA_OUTPUT_FORMAT=gpt

expect_success() {
  local label="$1"
  shift
  if "$@" >"$log_file" 2>&1; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label"
    cat "$log_file"
    exit 1
  fi
}

expect_rejection() {
  local label="$1"
  local diagnostic="$2"
  shift 2
  if "$@" >"$log_file" 2>&1; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$label"
    exit 1
  fi
  if ! grep -Fq "$diagnostic" "$log_file"; then
    printf 'FAIL: %s did not produce the expected diagnostic\n' "$label"
    cat "$log_file"
    exit 1
  fi
  if grep -Fq 'index.lock' "$log_file"; then
    printf 'FAIL: a hook tried to lock the Git index during commit\n'
    cat "$log_file"
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

git init -q -b main "$repo_dir"
git -C "$repo_dir" config --local user.name 'Pragma fixture'
git -C "$repo_dir" config --local user.email pragma-fixture@example.invalid
git -C "$repo_dir" config --local commit.gpgsign false
expect_success 'Bootstrap installs real hooks' bash "$PRAGMA_DIR/install.sh" "${bootstrap_args[@]}" "$repo_dir"
cd "$repo_dir"

cat >hello.sh <<'SCRIPT'
#!/usr/bin/env bash
if true;then
echo "hello"
fi
SCRIPT
cat >package.json <<'JSON'
{
  "name": "pragma-hook-fixture",
  "private": true,
  "scripts": {
    "typecheck": "node -e \"process.exit(require('node:fs').existsSync('.fail-typecheck') ? 1 : 0)\"",
    "test": "node -e \"process.exit(require('node:fs').existsSync('.fail-tests') ? 1 : 0)\""
  }
}
JSON

cat >go.mod <<'GO'
module example.invalid/pragma-fixture

go 1.26.0
GO
cat >answer.go <<'GO'
package fixture
func Answer()int{return 42}
GO
cat >answer_test.go <<'GO'
package fixture

import (
  "os"
  "testing"
)

func TestAnswer(t *testing.T) {
  if _, err := os.Stat(".fail-go-tests"); err == nil {
    t.Fatal("requested failure")
  }
  if Answer() != 42 {
    t.Fatal("wrong answer")
  }
}
GO

cat >hello.ts <<'TS'
export const answer: number = 42;
TS
cat >.oxlintrc.json <<'JSON'
{
  "rules": {
    "no-unused-vars": "warn"
  }
}
JSON

git add .
expect_rejection 'Formatting changes block the first commit' 'files were modified by this hook' git commit -m fixture
grep -Fq '  echo "hello"' hello.sh
git show :hello.sh | grep -Fq 'if true;then'
printf 'PASS: formatting preserves the staged contents for review\n'
grep -Fq 'func Answer() int { return 42 }' answer.go
printf 'PASS: Go formatting runs through the real hook\n'
git add .
expect_success 'Reviewed formatting commits successfully' git commit -m fixture

cat >hello.ts <<'TS'
const unused: number = 42;
TS
cp hello.ts "$tmp_dir/before-lint.ts"
git add hello.ts
expect_rejection 'Oxlint warnings block commits' '"tool":"oxlint"' git commit -m 'TypeScript lint rejection'
cmp hello.ts "$tmp_dir/before-lint.ts"
printf 'PASS: Oxlint leaves source files unchanged\n'
printf '{"rules":{"no-unused-vars":"off"}}\n' >.oxlintrc.json
expect_success 'Oxlint respects project rule configuration' bash .pragma-hooks/lint.sh hello.ts
git restore --staged --worktree hello.ts
git restore --worktree .oxlintrc.json

cat >hello.sh <<'SCRIPT'
#!/usr/bin/env bash
printf "%s\n" $1
SCRIPT
git add hello.sh
expect_rejection 'Shell lint errors block commits' '"tool":"shellcheck"' git commit -m 'lint rejection'
git restore --staged --worktree hello.sh

cat >answer.go <<'GO'
package fixture

import "fmt"

func Answer() int {
  fmt.Printf("%d", "invalid format")
  return 42
}
GO
git add answer.go
expect_rejection 'Go formatting changes require review' 'files were modified by this hook' git commit -m 'Go lint rejection'
git add answer.go
expect_rejection 'golangci-lint v2 blocks Go errors' '"tool":"golangci-lint"' git commit -m 'Go lint rejection'
git restore --staged --worktree answer.go

# Assemble a synthetic, nonfunctional PAT without putting a whole token in source.
printf 'GITHUB_TOKEN=ghp_%s%s\n' '7aBcD9eFgH2iJkL4mN' 'oP6qRsT8uVwX0yZaB1' >credential.env
git add credential.env
expect_rejection 'Default secret rules block credential commits' '"tool":"kingfisher"' git commit -m 'secret rejection'
if grep -Fq "$(cut -d= -f2 credential.env)" "$log_file"; then
  printf 'FAIL: secret diagnostics exposed the token\n'
  exit 1
fi
printf 'PASS: secret diagnostics redact the token\n'
git restore --staged credential.env
expect_success 'Unstaged secrets are outside commit scan scope' git commit --allow-empty -m 'unstaged secret fixture'
rm credential.env

git init -q --bare "$remote_dir"
git remote add origin "$remote_dir"
expect_success 'Passing tests allow pushes' git push -u origin main
printf 'fail fixture typecheck\n' >.fail-typecheck
expect_success 'Prepare the failing-typecheck push' git commit --allow-empty -m 'typecheck rejection'
expect_rejection 'Failing typecheck blocks pushes' '"cls":"typecheck"' git push origin main
rm .fail-typecheck
expect_success 'Repaired typecheck allows pushes' git push origin main
printf 'fail fixture tests\n' >.fail-tests
expect_success 'Prepare the failing-test push' git commit --allow-empty -m 'push rejection'
expect_rejection 'Failing tests block pushes' '"tool":"npm"' git push origin main
rm .fail-tests
expect_success 'Repaired tests allow pushes' git push origin main
printf 'fail Go fixture tests\n' >.fail-go-tests
expect_success 'Prepare the failing Go test push' git commit --allow-empty -m 'Go push rejection'
expect_rejection 'Failing Go tests block pushes' '"tool":"go"' git push origin main
rm .fail-go-tests
expect_success 'Repaired Go tests allow pushes' git push origin main
test "$(git rev-parse HEAD)" = "$(git --git-dir="$remote_dir" rev-parse main)"
printf 'PASS: the local remote received the expected commit\n'
