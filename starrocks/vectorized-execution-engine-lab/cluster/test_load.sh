#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local expected="$1"
  local file="$2"
  grep -Fq -- "$expected" "$file" || fail "expected $file to contain: $expected"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  [[ "$actual" == "$expected" ]] || fail "expected $expected, got $actual"
}

source "$script_dir/load.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vector-lab-readiness.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clock_file="$test_dir/clock"
curl_args_file="$test_dir/curl-args"
mysql_args_file="$test_dir/mysql-args"
full_timeout_args_file="$test_dir/full-timeout-args"
output_file="$test_dir/output"
printf '%s\n' 100 > "$clock_file"

date() {
  cat "$clock_file"
}

sleep() {
  printf '%s\n' "$(( $(<"$clock_file") + $1 ))" > "$clock_file"
}

curl() {
  printf '%s\n' "$*" >> "$curl_args_file"
  printf '%s\n' 'bootstrap-not-ok'
}

mysql_in_container() {
  printf '%s\n' "$*" >> "$mysql_args_file"
  printf '%s\n' 'backend-not-alive'
}

run_with_timeout() {
  printf '%s\n' "$1" >> "$full_timeout_args_file"
  shift
  printf '%s\n' "$*" >> "$mysql_args_file"
  printf '%s\n' 'backend-not-alive'
}

if READINESS_TIMEOUT_SECONDS=1 READINESS_PROBE_MAX_TIME=1 \
  READINESS_POLL_INTERVAL_SECONDS=1 wait_for_cluster_ready > "$output_file" 2>&1; then
  fail 'readiness unexpectedly succeeded'
fi

assert_equals 1 "$(wc -l < "$curl_args_file" | tr -d ' ')"
assert_contains '--max-time 1' "$curl_args_file"
assert_contains '--connect-timeout=1' "$mysql_args_file"
assert_contains 1 "$full_timeout_args_file"
assert_contains 'last bootstrap observation: bootstrap-not-ok' "$output_file"
assert_contains 'last backend observation: backend-not-alive' "$output_file"

sleep_args_file="$test_dir/sleep-args"
: > "$curl_args_file"
: > "$mysql_args_file"
: > "$full_timeout_args_file"
printf '%s\n' 100 > "$clock_file"

curl() {
  printf '%s\n' "$*" >> "$curl_args_file"
  if [[ "$(<"$clock_file")" == 100 ]]; then
    printf '%s\n' 104 > "$clock_file"
  fi
  printf '%s\n' 'bootstrap-not-ok'
}

sleep() {
  printf '%s\n' "$1" >> "$sleep_args_file"
  printf '%s\n' "$(( $(<"$clock_file") + $1 ))" > "$clock_file"
}

if READINESS_TIMEOUT_SECONDS=5 READINESS_PROBE_MAX_TIME=5 \
  READINESS_POLL_INTERVAL_SECONDS=2 wait_for_cluster_ready > "$output_file" 2>&1; then
  fail 'readiness unexpectedly succeeded near its deadline'
fi

assert_contains '--connect-timeout=1' "$mysql_args_file"
assert_contains 1 "$full_timeout_args_file"
assert_equals 1 "$(<"$sleep_args_file")"
assert_equals 1 "$(wc -l < "$curl_args_file" | tr -d ' ')"

printf '%s\n' 100 > "$clock_file"
: > "$full_timeout_args_file"

curl() {
  printf '%s\n' "$*" >> "$curl_args_file"
  printf '%s\n' '{"status":"OK"}'
}

mysql_in_container() {
  printf '%s\n' 106 > "$clock_file"
  printf '%s\n' $'a\tb\tc\td\te\tf\tg\th\ttrue'
}

run_with_timeout() {
  printf '%s\n' "$1" >> "$full_timeout_args_file"
  shift
  printf '%s\n' 106 > "$clock_file"
  printf '%s\n' $'a\tb\tc\td\te\tf\tg\th\ttrue'
}

if READINESS_TIMEOUT_SECONDS=5 READINESS_PROBE_MAX_TIME=5 \
  READINESS_POLL_INTERVAL_SECONDS=2 wait_for_cluster_ready > "$output_file" 2>&1; then
  fail 'readiness accepted an Alive backend response after its deadline'
fi

assert_contains 5 "$full_timeout_args_file"
assert_contains 'last backend observation: a' "$output_file"

printf '%s\n' 100 > "$clock_file"
: > "$full_timeout_args_file"

run_with_timeout() {
  printf '%s\n' "$1" >> "$full_timeout_args_file"
  shift
  printf '%s\n' 220 > "$clock_file"
  printf '%s\n' 'backend-not-alive'
}

if READINESS_TIMEOUT_SECONDS=120 READINESS_PROBE_MAX_TIME=5 \
  READINESS_POLL_INTERVAL_SECONDS=2 wait_for_cluster_ready > "$output_file" 2>&1; then
  fail 'readiness unexpectedly succeeded with a failed backend probe'
fi

assert_equals 5 "$(<"$full_timeout_args_file")"

timeout_output_file="$test_dir/full-timeout-output"
timeout_time_file="$test_dir/full-timeout-time"
if /usr/bin/time -p -o "$timeout_time_file" bash -c '
  source "$1"
  run_with_timeout 0.2 python3 -c "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(5)"
' bash "$script_dir/load.sh" \
  > "$timeout_output_file" 2>&1; then
  fail 'full-process timeout unexpectedly succeeded'
fi
awk '$1 == "real" && $2 < 1 { found=1 } END { exit !found }' "$timeout_time_file" \
  || fail 'full-process timeout took one second or longer'
assert_contains 'timed out' "$timeout_output_file"

echo 'PASS: readiness uses a deadline, bounded probes, and timeout diagnostics'
