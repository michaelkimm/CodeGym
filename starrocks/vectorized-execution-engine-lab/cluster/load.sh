#!/usr/bin/env bash
set -euo pipefail

cluster_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lab_dir="$(cd "$cluster_dir/.." && pwd)"
compose=(docker compose -f "$cluster_dir/compose.yaml")

mysql_in_container() {
  "${compose[@]}" exec -T starrocks \
    mysql -h127.0.0.1 -P9030 -uroot "$@"
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  python3 - "$timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(
    command,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
try:
    output, _ = process.communicate(timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    output, _ = process.communicate()
    sys.stdout.buffer.write(output)
    print(f"backend probe timed out after {timeout_seconds:g} seconds", file=sys.stderr)
    raise SystemExit(124)
sys.stdout.buffer.write(output)
raise SystemExit(process.returncode)
PY
}

wait_for_cluster_ready() {
  local timeout_seconds="${READINESS_TIMEOUT_SECONDS:-120}"
  local probe_max_time="${READINESS_PROBE_MAX_TIME:-5}"
  local poll_interval_seconds="${READINESS_POLL_INTERVAL_SECONDS:-2}"
  local start_seconds deadline_seconds now_seconds remaining_seconds
  local curl_max_time mysql_connect_timeout backend_probe_timeout sleep_seconds
  local bootstrap_ok backend_ok
  local last_bootstrap_observation='(no bootstrap probe completed)'
  local last_backend_observation='(no backend probe completed)'

  start_seconds="$(date +%s)"
  deadline_seconds=$((start_seconds + timeout_seconds))
  while true; do
    now_seconds="$(date +%s)"
    if ((now_seconds >= deadline_seconds)); then
      echo "StarRocks FE and BE were not ready within ${timeout_seconds} seconds" >&2
      echo "last bootstrap observation: ${last_bootstrap_observation}" >&2
      echo "last backend observation: ${last_backend_observation}" >&2
      echo "check: ${compose[*]} logs starrocks" >&2
      return 1
    fi
    remaining_seconds=$((deadline_seconds - now_seconds))
    curl_max_time=$probe_max_time
    if ((curl_max_time > remaining_seconds)); then
      curl_max_time=$remaining_seconds
    fi

    if last_bootstrap_observation="$(curl -fsS --max-time "$curl_max_time" \
        http://127.0.0.1:8030/api/bootstrap 2>&1)" \
      && grep -q '"status":"OK"' <<< "$last_bootstrap_observation"; then
      bootstrap_ok=true
    else
      bootstrap_ok=false
    fi

    now_seconds="$(date +%s)"
    if ((now_seconds >= deadline_seconds)); then
      echo "StarRocks FE and BE were not ready within ${timeout_seconds} seconds" >&2
      echo "last bootstrap observation: ${last_bootstrap_observation}" >&2
      echo "last backend observation: ${last_backend_observation}" >&2
      echo "check: ${compose[*]} logs starrocks" >&2
      return 1
    fi
    remaining_seconds=$((deadline_seconds - now_seconds))
    mysql_connect_timeout=$probe_max_time
    if ((mysql_connect_timeout > remaining_seconds)); then
      mysql_connect_timeout=$remaining_seconds
    fi
    backend_probe_timeout=$probe_max_time
    if ((backend_probe_timeout > remaining_seconds)); then
      backend_probe_timeout=$remaining_seconds
    fi

    if last_backend_observation="$(run_with_timeout "$backend_probe_timeout" \
        "${compose[@]}" exec -T starrocks \
        mysql -h127.0.0.1 -P9030 -uroot \
        --connect-timeout="$mysql_connect_timeout" \
        --batch --skip-column-names -e "SHOW BACKENDS" 2>&1)" \
      && awk -F '\t' '$9 == "true" { found=1 } END { exit !found }' \
        <<< "$last_backend_observation"; then
      backend_ok=true
    else
      backend_ok=false
    fi

    now_seconds="$(date +%s)"
    if ((now_seconds >= deadline_seconds)); then
      echo "StarRocks FE and BE were not ready within ${timeout_seconds} seconds" >&2
      echo "last bootstrap observation: ${last_bootstrap_observation}" >&2
      echo "last backend observation: ${last_backend_observation}" >&2
      echo "check: ${compose[*]} logs starrocks" >&2
      return 1
    fi
    if [[ "$bootstrap_ok" == true && "$backend_ok" == true ]]; then
      return 0
    fi
    remaining_seconds=$((deadline_seconds - now_seconds))
    sleep_seconds=$poll_interval_seconds
    if ((sleep_seconds > remaining_seconds)); then
      sleep_seconds=$remaining_seconds
    fi
    sleep "$sleep_seconds"
  done
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

target="${1:-}"
case "$target" in
  tiny) csv="$lab_dir/data/tiny_user_chats.csv" ;;
  benchmark) csv="$lab_dir/data/benchmark_user_chats.csv" ;;
  *) echo "usage: $0 tiny|benchmark" >&2; exit 2 ;;
esac

if [[ ! -f "$csv" ]]; then
  if [[ "$target" == benchmark ]]; then
    echo "missing $csv" >&2
    echo "run: $lab_dir/.venv/bin/python $lab_dir/demo.py export" >&2
  else
    echo "missing $csv" >&2
  fi
  exit 1
fi

if ! wait_for_cluster_ready; then
  exit 1
fi

mysql_in_container < "$cluster_dir/schema.sql"
mysql_in_container -e "TRUNCATE TABLE vector_lab.user_chats"

expected_rows=$(( $(wc -l < "$csv") - 1 ))
response_file="$(mktemp "${TMPDIR:-/tmp}/vector-lab-load.XXXXXX")"
trap 'rm -f "$response_file"' EXIT
label="vector_lab_${target}_$(date +%s)_$$"

if http_code="$(curl --location-trusted --silent --show-error \
    --user root: \
    --header "label:$label" \
    --header "Expect:100-continue" \
    --header "format:csv" \
    --header "column_separator:," \
    --header "skip_header:1" \
    --header "strict_mode:true" \
    --upload-file "$csv" \
    --request PUT \
    --output "$response_file" \
    --write-out '%{http_code}' \
    http://127.0.0.1:8030/api/vector_lab/user_chats/_stream_load)"; then
  curl_rc=0
else
  curl_rc=$?
fi

cat "$response_file"
if ((curl_rc != 0)); then
  echo "Stream Load transport failed: curl exit=$curl_rc HTTP=${http_code:-000}" >&2
  exit "$curl_rc"
fi
python3 - "$response_file" "$http_code" "$expected_rows" <<'PY'
import json
import sys

path, http_code, expected = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, encoding="utf-8") as source:
    response = json.load(source)
status = response.get("Status")
loaded = int(response.get("NumberLoadedRows", -1))
if http_code != 200 or status != "Success" or loaded != expected:
    raise SystemExit(
        f"Stream Load failed: HTTP={http_code}, Status={status}, "
        f"NumberLoadedRows={loaded}, expected={expected}"
    )
PY

actual_rows="$(mysql_in_container --batch --skip-column-names \
  -e "SELECT COUNT(*) FROM vector_lab.user_chats")"
if [[ "$actual_rows" != "$expected_rows" ]]; then
  echo "row count mismatch: expected=$expected_rows actual=$actual_rows" >&2
  exit 1
fi
echo "Loaded $actual_rows rows into vector_lab.user_chats"
