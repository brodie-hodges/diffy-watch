#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/diffy-watch-tests.XXXXXX")"

cleanup() {
  local pid="${watch_pid:-}"

  if [ -n "$pid" ]; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$fixture_root"
}
trap cleanup EXIT

stop_watch() {
  local pid="$1"

  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  watch_pid=""
}

make_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name diffy-watch-test
}

run_watch() {
  local output="$1"
  shift

  mkfifo "$fixture_root/input"
  "$script_dir/diffy-watch" -n 1 "$@" < "$fixture_root/input" > "$output" 2>&1 &
  watch_pid=$!
  exec 3>"$fixture_root/input"
  sleep 2
}

repo_a="$fixture_root/repo-a"
repo_b="$fixture_root/repo-b"
make_repo "$repo_a"
make_repo "$repo_b"
touch "$repo_a/alpha.txt" "$repo_b/beta.txt"

multi_output="$fixture_root/multi-output"
run_watch "$multi_output" -d "$repo_a" -d "$repo_b"
if ! grep -q "REPOSITORY 1/2" "$multi_output" || ! grep -q "REPOSITORY 2/2" "$multi_output"; then
  echo "multi-repository rendering failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

filtered_output="$fixture_root/filtered-output"
run_watch "$filtered_output" -d "$repo_a" -d "$repo_b" -- alpha.txt
if ! grep -q "alpha.txt" "$filtered_output" || grep -q "beta.txt" "$filtered_output"; then
  echo "diff path filtering failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

collapse_output="$fixture_root/collapse-output"
run_watch "$collapse_output" -d "$repo_a"
printf 'C' >&3
sleep 1
if ! grep -q "diff collapsed" "$collapse_output"; then
  echo "collapse control failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

lazybin="$fixture_root/bin"
mkdir -p "$lazybin"
printf '#!/usr/bin/env bash\nprintf "LAZYGIT_PWD=%%s\\n" "$PWD"\n' > "$lazybin/lazygit"
chmod +x "$lazybin/lazygit"

lazygit_output="$fixture_root/lazygit-output"
PATH="$lazybin:$PATH" run_watch "$lazygit_output" -d "$repo_a" -d "$repo_b"
printf ']l' >&3
sleep 1
repo_b_root="$(git -C "$repo_b" rev-parse --show-toplevel)"
if ! grep -q "LAZYGIT_PWD=$repo_b_root" "$lazygit_output"; then
  echo "active-repository lazygit launch failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

rebase_repo="$fixture_root/rebase-repo"
make_repo "$rebase_repo"
printf 'base\n' > "$rebase_repo/file.txt"
git -C "$rebase_repo" add file.txt
git -C "$rebase_repo" commit -q -m base
git -C "$rebase_repo" branch -M main
git -C "$rebase_repo" checkout -qb topic
printf 'topic\n' > "$rebase_repo/file.txt"
git -C "$rebase_repo" commit -qam topic
git -C "$rebase_repo" checkout -q main
printf 'main\n' > "$rebase_repo/file.txt"
git -C "$rebase_repo" commit -qam main
git -C "$rebase_repo" checkout -q topic
if git -C "$rebase_repo" rebase main >/dev/null 2>&1; then
  echo "rebase fixture did not produce a conflict" >&2
  exit 1
fi

index_before="$(git -C "$rebase_repo" hash-object .git/index)"
rebase_output="$fixture_root/rebase-output"
run_watch "$rebase_output" -d "$rebase_repo"
sleep 1
index_after="$(git -C "$rebase_repo" hash-object .git/index)"
if [ "$index_before" != "$index_after" ] || ! grep -q "REBASE" "$rebase_output"; then
  echo "rebase safety failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"
git -C "$rebase_repo" rebase --abort >/dev/null 2>&1 || true

echo "diffy-watch tests passed"
