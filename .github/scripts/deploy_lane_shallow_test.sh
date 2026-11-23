#!/usr/bin/env bash
# Proves "Pick the lane" (`elixir .github/scripts/deploy_lane.exs`) can resolve
# a merge commit and a squash commit in a `git clone --depth 2`, and that the
# old tip-of-main check (`git fetch --depth=1`) hides the parent the way
# deploy-lanes run 45132632242 failed. No Fly access, no production deploy.
#
# CI runs this after setup-beam (plain elixir, no mix). Run:
#   .github/scripts/deploy_lane_shallow_test.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
if ! command -v elixir >/dev/null; then
  echo "elixir is required on PATH (CI: after setup-beam)" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A tiny origin whose only change since production is an [admin] file.
# KIND is merge or squash. Writes PROD_SHA and TIP_SHA into the named files.
init_origin() {
  local kind=$1 dest=$2 prod_file=$3 tip_file=$4
  git init -q -b main "$dest" >/dev/null
  git -C "$dest" config user.name "Lane test"
  git -C "$dest" config user.email "lane-test@example.com"
  mkdir -p "$dest/.github/scripts" "$dest/lib/ex_tales_forge/deploy_lanes" "$dest/docs"
  cp "$root/.github/scripts/deploy_lane.exs" "$dest/.github/scripts/"
  cp "$root/lib/ex_tales_forge/deploy_lanes.ex" "$dest/lib/ex_tales_forge/"
  cp "$root/lib/ex_tales_forge/deploy_lanes/cli.ex" "$dest/lib/ex_tales_forge/deploy_lanes/"
  printf '%s\n' '[admin]' 'docs/admin-only.md' > "$dest/.github/deploy-lanes.txt"
  printf 'prod\n' > "$dest/docs/admin-only.md"
  printf 'seed\n' > "$dest/README.md"
  git -C "$dest" add -A
  git -C "$dest" commit -q -m "production" >/dev/null
  git -C "$dest" rev-parse HEAD > "$prod_file"

  git -C "$dest" checkout -q -b feature >/dev/null
  printf '%s\n' "$kind" > "$dest/docs/admin-only.md"
  git -C "$dest" add docs/admin-only.md
  git -C "$dest" commit -q -m "admin-only change" >/dev/null
  git -C "$dest" checkout -q main >/dev/null
  if [ "$kind" = merge ]; then
    git -C "$dest" merge -q --no-ff -m "Merge feature" feature >/dev/null
  elif [ "$kind" = squash ]; then
    git -C "$dest" merge -q --squash feature >/dev/null
    git -C "$dest" commit -q -m "squash admin-only change" >/dev/null
  else
    echo "unknown kind: $kind" >&2
    return 1
  fi
  git -C "$dest" rev-parse HEAD > "$tip_file"
}

pick_lane() {
  local repo=$1 sha=$2 production=$3
  local out=$work/output
  mkdir -p "$out"
  : > "$out/github_output"
  : > "$out/github_summary"
  : > "$out/stdout"
  (
    cd "$repo"
    GITHUB_OUTPUT="$out/github_output" GITHUB_STEP_SUMMARY="$out/github_summary" \
      elixir .github/scripts/deploy_lane.exs --sha "$sha" --production "$production"
  ) > "$out/stdout" 2>&1
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf 'elixir exited %s\n%s\n' "$status" "$(cat "$out/stdout")"
    return 1
  fi
  local lane
  lane=$(sed -n 's/^lane=//p' "$out/github_output" | tail -n 1)
  printf 'lane=%s\n' "$lane"
  grep -E 'Deploy lane:|This merge|Since production' "$out/stdout" || true
  [ "$lane" = admin ]
}

# --- 1. depth 2: merge and squash both pick admin ---
for kind in merge squash; do
  src=$work/src-$kind
  init_origin "$kind" "$src" "$work/prod-$kind" "$work/tip-$kind"
  prod=$(cat "$work/prod-$kind")
  tip=$(cat "$work/tip-$kind")
  echo
  echo "=== $kind commit $tip (production $prod) ==="
  git -C "$src" log --oneline --decorate --graph -5
  parents=$(git -C "$src" rev-parse "$tip"^@ | wc -l | tr -d ' ')
  echo "parents: $parents"

  shallow=$work/depth2-$kind
  git clone -q --depth 2 "file://$src" "$shallow"
  if git -C "$shallow" rev-parse --verify "${tip}^1" >/dev/null 2>&1; then
    pass "$kind depth-2 clone has ${tip}^1"
  else
    fail "$kind depth-2 clone missing ${tip}^1"
    git -C "$shallow" rev-parse "${tip}^1" 2>&1 || true
    continue
  fi

  if pick_lane "$shallow" "$tip" "$prod"; then
    pass "$kind depth-2 Pick the lane -> admin"
  else
    fail "$kind depth-2 Pick the lane did not pick admin"
  fi

  # Contrast: depth 1 cannot see the parent.
  depth1=$work/depth1-$kind
  git clone -q --depth 1 "file://$src" "$depth1"
  if git -C "$depth1" rev-parse --verify "${tip}^1" >/dev/null 2>&1; then
    fail "$kind depth-1 clone unexpectedly has ${tip}^1"
  else
    pass "$kind depth-1 clone hides ${tip}^1 (expected)"
  fi
done

# --- 2. The production bug: a full clone, then fetch --depth=1, hides ^1 ---
echo
echo "=== reproduce run 45132632242: fetch --depth=1 after a full clone ==="
src=$work/src-merge
tip=$(cat "$work/tip-merge")
full=$work/full-then-shallow
git clone -q "file://$src" "$full"
if git -C "$full" rev-parse --verify "${tip}^1" >/dev/null 2>&1; then
  pass "full clone has ${tip}^1"
else
  fail "full clone missing ${tip}^1"
fi
git -C "$full" fetch --no-tags --depth=1 origin main >/dev/null 2>&1
if git -C "$full" rev-parse --verify "${tip}^1" >/dev/null 2>&1; then
  fail "after git fetch --depth=1, ${tip}^1 is still visible (bug not reproduced)"
else
  pass "after git fetch --depth=1, ${tip}^1 is hidden (the production failure)"
  if [ -f "$full/.git/shallow" ]; then
    pass "fetch --depth=1 wrote .git/shallow"
  else
    fail "fetch --depth=1 did not write .git/shallow"
  fi
fi

# --- 3. The fix: ls-remote for the tip check leaves parents intact ---
echo
echo "=== tip check via git ls-remote (the fix) ==="
fixed=$work/full-ls-remote
git clone -q "file://$src" "$fixed"
prod=$(cat "$work/prod-merge")
main_sha=$(git -C "$fixed" ls-remote origin refs/heads/main | cut -f1)
if [ "$main_sha" = "$tip" ]; then
  pass "ls-remote origin refs/heads/main == tip $tip"
else
  fail "ls-remote returned '$main_sha', expected $tip"
fi
if git -C "$fixed" rev-parse --verify "${tip}^1" >/dev/null 2>&1; then
  pass "after ls-remote, ${tip}^1 is still visible"
else
  fail "after ls-remote, ${tip}^1 is hidden"
fi
if pick_lane "$fixed" "$tip" "$prod"; then
  pass "after ls-remote, Pick the lane -> admin"
else
  fail "after ls-remote, Pick the lane did not pick admin"
fi

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "All checks passed"
