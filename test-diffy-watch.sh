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
  local attempt=0

  printf 'q' >&3 2>/dev/null || true
  for attempt in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  kill -TERM "$pid" 2>/dev/null || true
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
  wait_for_pattern "$output" "STATUS"
}

wait_for_pattern() {
  local output="$1"
  local pattern="$2"
  local attempts="${3:-100}"
  local attempt=0

  for ((attempt = 0; attempt < attempts; attempt++)); do
    if grep -q -- "$pattern" "$output" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  echo "timed out waiting for $pattern" >&2
  return 1
}

last_screen() {
  perl -0ne '@screens = split(/\e\[H\e\[2J/); print $screens[-1]' "$1"
}

plain_last_screen() {
  last_screen "$1" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g'
}

stable_last_screen() {
  plain_last_screen "$1" | perl -pe 's/20\d\d-\d\d-\d\d \d\d:\d\d:\d\d/<timestamp>/g'
}

wait_for_screen_pattern() {
  local output="$1"
  local pattern="$2"
  local attempts="${3:-100}"
  local attempt=0

  for ((attempt = 0; attempt < attempts; attempt++)); do
    if plain_last_screen "$output" | grep -q -- "$pattern"; then
      return 0
    fi
    sleep 0.05
  done
  echo "timed out waiting for screen pattern $pattern" >&2
  return 1
}

repo="$fixture_root/repo"
make_repo "$repo"
touch "$repo/alpha.txt" "$repo/beta.txt"

single_output="$fixture_root/single-output"
run_watch "$single_output" "$repo"
single_screen="$(plain_last_screen "$single_output")"
if [[ "$single_screen" != *"STATUS"*"All diffs"*"?? alpha.txt"*"?? beta.txt"*"DIFFS"* ]]; then
  echo "single-repository rendering failed" >&2
  exit 1
fi
if [[ "$single_screen" != *"[u] ?? on"*"[a] A on"*"[m] M on"* ]]; then
  echo "status filter hints were not rendered" >&2
  exit 1
fi
if ! grep -Fq $'\033[38;5;196malpha.txt' "$single_output"; then
  echo "status filename colors were not rendered" >&2
  exit 1
fi
if ! grep -Fq $'\033[48;5;234m\033[K' "$single_output"; then
  echo "diff pane did not fill the available terminal height" >&2
  exit 1
fi
if grep -q "REPOSITORY 1/" "$single_output"; then
  echo "multi-repository layout was not removed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
if ! grep -Fq $'\033[?1049l' "$single_output"; then
  echo "alternate-screen cleanup failed" >&2
  exit 1
fi
rm -f "$fixture_root/input"

if "$script_dir/diffy-watch" "$repo" "$repo" --help >/dev/null 2>&1; then
  echo "multiple directory arguments were accepted" >&2
  exit 1
fi

filtered_output="$fixture_root/filtered-output"
run_watch "$filtered_output" "$repo" -- alpha.txt
if ! grep -q "alpha.txt" "$filtered_output" || grep -q "beta.txt" "$filtered_output"; then
  echo "diff path filtering failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

search_output="$fixture_root/search-output"
run_watch "$search_output" "$repo"
printf '/beta\n' >&3
if ! wait_for_screen_pattern "$search_output" "Search.*beta"; then
  echo "slash search control failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

filter_repo="$fixture_root/filter-repo"
make_repo "$filter_repo"
printf 'modified-base\n' > "$filter_repo/modified.txt"
git -C "$filter_repo" add modified.txt
git -C "$filter_repo" commit -q -m base
printf 'MODIFIED-FILTER-CONTENT\n' > "$filter_repo/modified.txt"
printf 'ADDED-FILTER-CONTENT\n' > "$filter_repo/added.txt"
git -C "$filter_repo" add added.txt
printf 'UNTRACKED-FILTER-CONTENT\n' > "$filter_repo/untracked.txt"

filter_output="$fixture_root/filter-output"
LINES=50 run_watch "$filter_output" "$filter_repo"
filter_screen="$(plain_last_screen "$filter_output")"
if [[ "$filter_screen" != *"A  added.txt (staged)"* ]] || \
  [[ "$filter_screen" == *"M modified.txt (staged)"* ]] || \
  ! grep -Fq $'\033[38;5;40madded.txt (staged)' "$filter_output"; then
  echo "staged status filename styling failed" >&2
  exit 1
fi
printf 'u' >&3
wait_for_screen_pattern "$filter_output" '?? off'
filter_screen="$(plain_last_screen "$filter_output")"
if [[ "$filter_screen" == *"?? untracked.txt"* ]] || \
  [[ "$filter_screen" == *"UNTRACKED-FILTER-CONTENT"* ]]; then
  echo "untracked filter did not hide status and diff output" >&2
  exit 1
fi
printf 'a' >&3
wait_for_screen_pattern "$filter_output" 'A off'
filter_screen="$(plain_last_screen "$filter_output")"
if [[ "$filter_screen" == *"A  added.txt"* ]] || \
  [[ "$filter_screen" == *"ADDED-FILTER-CONTENT"* ]]; then
  echo "added filter did not hide status and diff output" >&2
  exit 1
fi
printf 'm' >&3
wait_for_screen_pattern "$filter_output" 'M off'
filter_screen="$(plain_last_screen "$filter_output")"
if [[ "$filter_screen" != *"no changes match the active filters"* ]] || \
  [[ "$filter_screen" == *"modified.txt"* ]]; then
  echo "modified filter did not hide status and diff output" >&2
  exit 1
fi
printf 'u' >&3
wait_for_screen_pattern "$filter_output" '?? on'
filter_screen="$(plain_last_screen "$filter_output")"
if [[ "$filter_screen" != *"?? untracked.txt"*"UNTRACKED-FILTER-CONTENT"* ]] || \
  [[ "$filter_screen" == *"added.txt"* ]] || [[ "$filter_screen" == *"modified.txt"* ]]; then
  echo "status filters did not restore only the requested category" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

nav_repo="$fixture_root/nav-repo"
make_repo "$nav_repo"
printf 'one-base\n' > "$nav_repo/one.txt"
printf 'two-base\n' > "$nav_repo/two.txt"
git -C "$nav_repo" add one.txt two.txt
git -C "$nav_repo" commit -q -m base
printf 'ONE-CHANGE\n' > "$nav_repo/one.txt"
printf 'TWO-CHANGE\n' > "$nav_repo/two.txt"

nav_output="$fixture_root/nav-output"
run_watch "$nav_output" "$nav_repo"
printf '\033[C' >&3
wait_for_screen_pattern "$nav_output" '>  M one.txt'
nav_screen="$(plain_last_screen "$nav_output")"
if [[ "$nav_screen" != *"ONE-CHANGE"* ]] || [[ "$nav_screen" == *"TWO-CHANGE"* ]]; then
  echo "down-arrow did not select only the first file diff" >&2
  exit 1
fi
printf '\033[C' >&3
wait_for_screen_pattern "$nav_output" '>  M two.txt'
printf '\033[D' >&3
wait_for_screen_pattern "$nav_output" '>  M one.txt'
printf 'j' >&3
wait_for_screen_pattern "$nav_output" '>  M two.txt'
printf 'k' >&3
wait_for_screen_pattern "$nav_output" '>  M one.txt'
printf 'ONE-REFRESH\n' > "$nav_repo/one.txt"
if ! wait_for_screen_pattern "$nav_output" 'ONE-REFRESH' 60; then
  echo "automatic selected-diff refresh failed" >&2
  exit 1
fi
mouse_row="$(last_screen "$nav_output" | perl -0ne 's/\e\[(\d+);1H/\n$1 /g; for (split /\n/) { if (/two\.txt/ && /^(\d+) /) { print $1; exit } }')"
if [ -z "$mouse_row" ]; then
  echo "could not locate status row for mouse selection" >&2
  exit 1
fi
printf '\033[<0;1;%sM' "$mouse_row" >&3
printf '\033[<0;1;%sm' "$mouse_row" >&3
wait_for_screen_pattern "$nav_output" '>  M two.txt'
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

split_repo="$fixture_root/split-repo"
make_repo "$split_repo"
printf 'base-one\nbase-two\n' > "$split_repo/mixed.txt"
git -C "$split_repo" add mixed.txt
git -C "$split_repo" commit -q -m base
printf 'staged-one\nbase-two\n' > "$split_repo/mixed.txt"
git -C "$split_repo" add mixed.txt
printf 'staged-one\nmodified-two\n' > "$split_repo/mixed.txt"

split_output="$fixture_root/split-output"
run_watch "$split_output" "$split_repo"
printf '\033[C' >&3
wait_for_screen_pattern "$split_output" '> MM mixed.txt'
split_screen="$(plain_last_screen "$split_output")"
if [ "$(printf '%s' "$split_screen" | grep -c 'MM mixed.txt')" -ne 1 ] || \
  [[ "$split_screen" != *"MM mixed.txt (staged)"*"STAGED"*"staged-one"*"UNSTAGED + UNTRACKED"* ]]; then
  echo "mixed file did not render as one row with both diff layers" >&2
  exit 1
fi
printf '\033[B' >&3
if ! wait_for_screen_pattern "$split_output" 'modified-two'; then
  echo "mixed file unstaged diff was not pageable" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

capped_repo="$fixture_root/capped-repo"
make_repo "$capped_repo"
for file_number in {1..12}; do
  printf 'change-%s\n' "$file_number" > "$capped_repo/file$file_number.txt"
done
capped_output="$fixture_root/capped-output"
LINES=18 run_watch "$capped_output" "$capped_repo"
for move in {1..10}; do
  printf '\033[C' >&3
done
wait_for_screen_pattern "$capped_output" '> ??'
capped_screen="$(plain_last_screen "$capped_output")"
if [[ "$capped_screen" != *"All diffs"*"DIFFS"* ]] || \
  [ "$(printf '%s' "$capped_screen" | grep -c '?? file')" -gt 5 ]; then
  echo "pinned capped status list failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

paging_repo="$fixture_root/paging-repo"
make_repo "$paging_repo"
for line_number in {1..60}; do
  printf 'base-%02d\n' "$line_number" >> "$paging_repo/long.txt"
done
git -C "$paging_repo" add long.txt
git -C "$paging_repo" commit -q -m base
for line_number in {1..60}; do
  printf 'changed-%02d\n' "$line_number" >> "$paging_repo/changed.txt"
done
mv "$paging_repo/changed.txt" "$paging_repo/long.txt"
paging_output="$fixture_root/paging-output"
LINES=18 run_watch "$paging_output" "$paging_repo"
printf '\033[C' >&3
wait_for_screen_pattern "$paging_output" '>  M long.txt'
paging_before="$(stable_last_screen "$paging_output")"
printf '\033[B' >&3
sleep 0.1
paging_after="$(stable_last_screen "$paging_output")"
if [ "$paging_before" = "$paging_after" ] || [[ "$paging_after" != *">  M long.txt"*"DIFFS"* ]]; then
  echo "right-arrow diff paging failed" >&2
  exit 1
fi
printf '\033[A' >&3
sleep 0.1
if [ "$(stable_last_screen "$paging_output")" != "$paging_before" ]; then
  echo "left-arrow diff paging failed" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

perf_bin="$fixture_root/perf-bin"
perf_log="$fixture_root/perf-git.log"
real_git="$(command -v git)"
mkdir -p "$perf_bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$DIFFY_GIT_LOG"\nfor arg in "$@"; do\n  if [ "$arg" = "--binary" ]; then\n    sleep 2\n  fi\ndone\nexec "%s" "$@"\n' "$real_git" > "$perf_bin/git"
chmod +x "$perf_bin/git"
export DIFFY_GIT_LOG="$perf_log"
perf_output="$fixture_root/perf-output"
PATH="$perf_bin:$PATH" run_watch "$perf_output" "$nav_repo"
: > "$perf_log"
printf '\033[C' >&3
if ! wait_for_screen_pattern "$perf_output" '>  M one.txt' 10; then
  echo "selection waited on repository-wide diff work" >&2
  exit 1
fi
if grep -q -- '--binary' "$perf_log"; then
  echo "selection invoked repository-wide binary diff hashing" >&2
  exit 1
fi
if grep -q -- 'diff.*two.txt' "$perf_log"; then
  echo "selection rendered an unrelated file diff" >&2
  exit 1
fi
stop_watch "$watch_pid"
exec 3>&-
rm -f "$fixture_root/input"

if command -v script >/dev/null 2>&1; then
  pty_bin="$fixture_root/pty-bin"
  pty_output="$fixture_root/pty-output"
  real_delta="$(command -v delta)"
  mkdir -p "$pty_bin"
  printf '#!/usr/bin/env bash\nsleep 0.5\nexec "%s" "$@"\n' "$real_delta" > "$pty_bin/delta"
  chmod +x "$pty_bin/delta"
  (
    sleep 0.2
    printf '\033[<65;1;10M\033[<65;1;10M'
    sleep 0.8
    printf 'q'
  ) | script -q "$pty_output" env PATH="$pty_bin:$PATH" \
    "$script_dir/diffy-watch" -n 10 "$nav_repo" >/dev/null
  if grep -Fq '^[[<65;1;10M' "$pty_output" || \
    grep -Fq $'\033[<65;1;10M' "$pty_output"; then
    echo "mouse input bytes leaked into terminal output" >&2
    exit 1
  fi
fi

lazybin="$fixture_root/bin"
mkdir -p "$lazybin"
printf '#!/usr/bin/env bash\nprintf "LAZYGIT_PWD=%%s\\n" "$PWD"\n' > "$lazybin/lazygit"
chmod +x "$lazybin/lazygit"

lazygit_output="$fixture_root/lazygit-output"
PATH="$lazybin:$PATH" run_watch "$lazygit_output" "$repo"
printf 'l' >&3
sleep 1
repo_root="$(git -C "$repo" rev-parse --show-toplevel)"
if ! grep -q "LAZYGIT_PWD=$repo_root" "$lazygit_output"; then
  echo "lazygit repository launch failed" >&2
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
run_watch "$rebase_output" "$rebase_repo"
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
