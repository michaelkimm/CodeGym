# Vectorized Execution Engine Learning Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained StarRocks learning lab that follows one Filter + GROUP BY query through Row-at-a-time Python, NumPy Chunk execution, and a real StarRocks 3.3.22 Query Profile.

**Architecture:** Keep the teaching model in one importable `demo.py`, with standard-library unit tests in `test_demo.py`. Put the disposable StarRocks all-in-one cluster behind Compose and a deterministic Stream Load script, then guide the learner through prediction, tracing, benchmarking, SQL execution, and operator-scoped Profile interpretation in the README.

**Tech Stack:** Python 3.12, NumPy 2.4.4, `unittest`, Bash, Docker Compose v2, StarRocks 3.3.22, SQL, CSV

## Global Constraints

- The implementation root is `starrocks/vectorized-execution-engine-lab/`.
- Use Python 3.12 and pin `numpy==2.4.4`.
- Use random seed `20260724`, default row count `1_000_000`, and default Chunk size `4_096`.
- Use `starrocks/allin1-ubuntu:3.3.22` and expose ports `9030`, `8030`, and `8040`.
- Keep the Row and Vector models on the same generated NumPy source arrays.
- Do not include data construction or Row conversion in timed query regions.
- Do not claim a required speedup or compare Python time directly with StarRocks time.
- Target 220 nonblank, noncomment lines for `demo.py`; do not exceed the reviewed hard limit of 260 lines.
- Use only `argparse` for the CLI and `unittest` for automated Python tests.
- Resolve committed input/default output paths from the lab directory, not the caller's working directory.
- Never commit `data/benchmark_user_chats.csv` or `.venv/`.
- Reset `vector_lab.user_chats` before every tiny or benchmark load.
- Interpret Query Profile metrics within the operator that owns them.

---

### Task 1: Deterministic Row and Chunk execution model

**Files:**
- Create: `starrocks/vectorized-execution-engine-lab/.gitignore`
- Create: `starrocks/vectorized-execution-engine-lab/requirements.txt`
- Create: `starrocks/vectorized-execution-engine-lab/data/.gitignore`
- Create: `starrocks/vectorized-execution-engine-lab/data/tiny_user_chats.csv`
- Create: `starrocks/vectorized-execution-engine-lab/test_demo.py`
- Create: `starrocks/vectorized-execution-engine-lab/demo.py`

**Interfaces:**
- Consumes: Python 3.12 and NumPy 2.4.4.
- Produces: `Column`, `Chunk`, `ExecutionStats`, `load_tiny()`, `generate_chunk(rows)`, `to_rows(chunk)`, `run_row(rows, trace=False)`, and `run_vector(chunk, chunk_size, trace=False)`.

- [ ] **Step 1: Add fixtures and a failing core test suite**

Create `.gitignore` with:

```gitignore
.venv/
```

Create `requirements.txt` with:

```text
numpy==2.4.4
```

Create `data/.gitignore` with:

```gitignore
*
!.gitignore
!tiny_user_chats.csv
```

Create `data/tiny_user_chats.csv` with:

```csv
chat_id,channel_id,status
1,1,OPEN
2,1,CLOSED
3,2,OPEN
4,3,SNOOZED
5,1,OPEN
6,2,CLOSED
7,3,OPEN
8,1,OPEN
9,2,OPEN
10,3,CLOSED
11,2,OPEN
12,3,OPEN
```

Create `test_demo.py` with:

```python
import unittest

import numpy as np

import demo


class ExecutionModelTest(unittest.TestCase):
    def test_tiny_row_and_vector_results_match_expected(self):
        chunk = demo.load_tiny()
        row_result, row_stats = demo.run_row(demo.to_rows(chunk))
        vector_result, vector_stats = demo.run_vector(chunk, chunk_size=4)

        self.assertEqual({1: 3, 2: 3, 3: 2}, row_result)
        self.assertEqual(row_result, vector_result)
        self.assertEqual(12, row_stats.filter_calls)
        self.assertEqual(8, row_stats.aggregate_calls)
        self.assertEqual(3, vector_stats.filter_calls)
        self.assertEqual(3, vector_stats.aggregate_calls)

    def test_generation_is_deterministic(self):
        first = demo.generate_chunk(100)
        second = demo.generate_chunk(100)

        for name in ("chat_id", "channel_id", "status"):
            np.testing.assert_array_equal(first[name], second[name])

    def test_chunk_rejects_different_column_lengths(self):
        with self.assertRaisesRegex(ValueError, "same length"):
            demo.Chunk({
                "chat_id": demo.Column("chat_id", np.array([1, 2])),
                "status": demo.Column("status", np.array([0])),
            })

    def test_vector_handles_incomplete_final_chunk(self):
        chunk = demo.generate_chunk(10)
        row_result, _ = demo.run_row(demo.to_rows(chunk))
        vector_result, stats = demo.run_vector(chunk, chunk_size=4)

        self.assertEqual(row_result, vector_result)
        self.assertEqual(3, stats.chunks_processed)

    def test_vector_handles_no_selected_rows(self):
        chunk = demo.Chunk({
            "chat_id": demo.Column("chat_id", np.arange(1, 6, dtype=np.int64)),
            "channel_id": demo.Column("channel_id", np.ones(5, dtype=np.int32)),
            "status": demo.Column("status", np.ones(5, dtype=np.int8)),
        })

        result, stats = demo.run_vector(chunk, chunk_size=2)

        self.assertEqual({}, result)
        self.assertEqual(0, stats.selected_rows)
        self.assertEqual(0, stats.aggregate_calls)
        self.assertEqual(3, stats.chunks_processed)

    def test_non_positive_sizes_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "positive"):
            demo.generate_chunk(0)
        with self.assertRaisesRegex(ValueError, "positive"):
            demo.run_vector(demo.load_tiny(), chunk_size=0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the core tests and confirm the red state**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m unittest -v test_demo.py
```

Expected: installation succeeds and the test command fails with `ModuleNotFoundError: No module named 'demo'`.

- [ ] **Step 3: Implement the minimal execution model**

Create `demo.py` with the following core implementation:

```python
from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

try:
    import numpy as np
except ModuleNotFoundError as error:
    raise SystemExit(
        "NumPy is required. Run: python -m pip install -r requirements.txt"
    ) from error


LAB_DIR = Path(__file__).resolve().parent
TINY_CSV = LAB_DIR / "data" / "tiny_user_chats.csv"
SEED = 20260724
OPEN = 0
STATUS_TO_CODE = {"OPEN": 0, "CLOSED": 1, "SNOOZED": 2}
CODE_TO_STATUS = {code: status for status, code in STATUS_TO_CODE.items()}


@dataclass(frozen=True)
class Column:
    name: str
    values: np.ndarray


@dataclass
class Chunk:
    columns: dict[str, Column]

    def __post_init__(self) -> None:
        lengths = {len(column.values) for column in self.columns.values()}
        if len(lengths) > 1:
            raise ValueError("all Chunk columns must have the same length")

    def __getitem__(self, name: str) -> np.ndarray:
        return self.columns[name].values

    @property
    def row_count(self) -> int:
        return len(next(iter(self.columns.values())).values) if self.columns else 0


@dataclass(frozen=True)
class ExecutionStats:
    rows_examined: int
    selected_rows: int
    filter_calls: int
    aggregate_calls: int
    chunks_processed: int = 0


def _chunk(chat_id: np.ndarray, channel_id: np.ndarray, status: np.ndarray) -> Chunk:
    return Chunk({
        "chat_id": Column("chat_id", chat_id),
        "channel_id": Column("channel_id", channel_id),
        "status": Column("status", status),
    })


def load_tiny(path: Path = TINY_CSV) -> Chunk:
    values: tuple[list[int], list[int], list[int]] = ([], [], [])
    try:
        with path.open(newline="", encoding="utf-8") as source:
            reader = csv.DictReader(source)
            if reader.fieldnames != ["chat_id", "channel_id", "status"]:
                raise ValueError(f"{path}: expected header chat_id,channel_id,status")
            for line_number, row in enumerate(reader, start=2):
                try:
                    values[0].append(int(row["chat_id"]))
                    values[1].append(int(row["channel_id"]))
                    values[2].append(STATUS_TO_CODE[row["status"]])
                except (KeyError, TypeError, ValueError) as error:
                    raise ValueError(f"{path}:{line_number}: invalid row {row}") from error
    except OSError as error:
        raise ValueError(f"cannot read {path}: {error}") from error
    return _chunk(
        np.asarray(values[0], dtype=np.int64),
        np.asarray(values[1], dtype=np.int32),
        np.asarray(values[2], dtype=np.int8),
    )


def generate_chunk(rows: int) -> Chunk:
    if rows <= 0:
        raise ValueError("rows must be a positive integer")
    rng = np.random.default_rng(SEED)
    return _chunk(
        np.arange(1, rows + 1, dtype=np.int64),
        rng.integers(1, 1001, size=rows, dtype=np.int32),
        rng.choice(np.array([0, 1, 2], dtype=np.int8), size=rows, p=[0.25, 0.60, 0.15]),
    )


def to_rows(chunk: Chunk) -> list[tuple[int, int, int]]:
    return [
        (int(chat_id), int(channel_id), int(status))
        for chat_id, channel_id, status in zip(
            chunk["chat_id"], chunk["channel_id"], chunk["status"], strict=True
        )
    ]


def run_row(
    rows: list[tuple[int, int, int]], trace: bool = False
) -> tuple[dict[int, int], ExecutionStats]:
    result: dict[int, int] = {}
    selected_rows = 0
    for index, (_, channel_id, status) in enumerate(rows, start=1):
        matches = status == OPEN
        if matches:
            result[channel_id] = result.get(channel_id, 0) + 1
            selected_rows += 1
        if trace:
            print(
                f"Row {index:>2}: status={CODE_TO_STATUS[status]:<8} "
                f"predicate={str(matches).lower():<5} partial agg={dict(sorted(result.items()))}"
            )
    return result, ExecutionStats(
        len(rows), selected_rows, len(rows), selected_rows
    )


def run_vector(
    chunk: Chunk, chunk_size: int, trace: bool = False
) -> tuple[dict[int, int], ExecutionStats]:
    if chunk_size <= 0:
        raise ValueError("chunk size must be a positive integer")
    result: dict[int, int] = {}
    selected_rows = aggregate_calls = chunks_processed = 0
    for start in range(0, chunk.row_count, chunk_size):
        stop = min(start + chunk_size, chunk.row_count)
        statuses = chunk["status"][start:stop]
        channels = chunk["channel_id"][start:stop]
        mask = statuses == OPEN
        selected = channels[mask]
        chunks_processed += 1
        selected_rows += int(selected.size)
        if selected.size:
            keys, counts = np.unique(selected, return_counts=True)
            for key, count in zip(keys, counts, strict=True):
                channel_id = int(key)
                result[channel_id] = result.get(channel_id, 0) + int(count)
            aggregate_calls += 1
        if trace:
            print(f"Chunk {chunks_processed}")
            print(f"  status      = {[CODE_TO_STATUS[int(value)] for value in statuses]}")
            print(f"  filter mask = {mask.tolist()}")
            print(f"  channel_id  = {channels.tolist()}")
            print(f"  selected    = {selected.tolist()}")
            print(f"  partial agg = {dict(sorted(result.items()))}")
    return result, ExecutionStats(
        chunk.row_count,
        selected_rows,
        chunks_processed,
        aggregate_calls,
        chunks_processed,
    )
```

- [ ] **Step 4: Run the core tests and confirm the green state**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
.venv/bin/python -m unittest -v test_demo.py
```

Expected: `Ran 6 tests` followed by `OK`.

- [ ] **Step 5: Commit the deterministic model**

```bash
git add starrocks/vectorized-execution-engine-lab
git commit -m "feat: add row and chunk execution model"
```

---

### Task 2: Trace, benchmark, and export CLI

**Files:**
- Modify: `starrocks/vectorized-execution-engine-lab/demo.py`
- Modify: `starrocks/vectorized-execution-engine-lab/test_demo.py`

**Interfaces:**
- Consumes: Task 1 execution model.
- Produces: `export_csv(chunk, path)`, `trace`, `benchmark`, and `export` subcommands with positive integer validation.

- [ ] **Step 1: Add failing export and CLI validation tests**

Add these imports to `test_demo.py`:

```python
import csv
import tempfile
from pathlib import Path
```

Add these methods to `ExecutionModelTest`:

```python
    def test_export_writes_header_rows_and_status_names(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "export.csv"
            demo.export_csv(demo.generate_chunk(7), output)

            with output.open(newline="", encoding="utf-8") as source:
                rows = list(csv.DictReader(source))

        self.assertEqual(7, len(rows))
        self.assertEqual(["chat_id", "channel_id", "status"], list(rows[0]))
        self.assertIn(rows[0]["status"], {"OPEN", "CLOSED", "SNOOZED"})

    def test_export_requires_existing_parent_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "missing" / "export.csv"
            with self.assertRaisesRegex(ValueError, "parent directory"):
                demo.export_csv(demo.generate_chunk(1), output)
```

- [ ] **Step 2: Run the focused tests and confirm the red state**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
.venv/bin/python -m unittest -v \
  test_demo.ExecutionModelTest.test_export_writes_header_rows_and_status_names \
  test_demo.ExecutionModelTest.test_export_requires_existing_parent_directory
```

Expected: both tests fail with `AttributeError: module 'demo' has no attribute 'export_csv'`.

- [ ] **Step 3: Add complete CLI behavior**

Add these imports to `demo.py`:

```python
import argparse
import gc
import platform
import statistics
import sys
import time
from collections.abc import Callable
```

Add this constant after `TINY_CSV`:

```python
DEFAULT_EXPORT = LAB_DIR / "data" / "benchmark_user_chats.csv"
```

Append these functions to `demo.py`:

```python
def export_csv(chunk: Chunk, path: Path) -> None:
    if not path.parent.is_dir():
        raise ValueError(f"output parent directory does not exist: {path.parent}")
    with path.open("w", newline="", encoding="utf-8") as target:
        writer = csv.writer(target)
        writer.writerow(("chat_id", "channel_id", "status"))
        writer.writerows(
            (int(chat_id), int(channel_id), CODE_TO_STATUS[int(status)])
            for chat_id, channel_id, status in zip(
                chunk["chat_id"], chunk["channel_id"], chunk["status"], strict=True
            )
        )


def _timed(call: Callable[[], tuple[dict[int, int], ExecutionStats]]):
    gc_was_enabled = gc.isenabled()
    if gc_was_enabled:
        gc.disable()
    try:
        started = time.perf_counter()
        value = call()
        return time.perf_counter() - started, value
    finally:
        if gc_was_enabled:
            gc.enable()


def _positive(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be a positive integer")
    return parsed


def command_trace(_: argparse.Namespace) -> None:
    chunk = load_tiny()
    print("=== ROW TRACE ===")
    row_result, row_stats = run_row(to_rows(chunk), trace=True)
    print("\n=== CHUNK TRACE (size=4) ===")
    vector_result, vector_stats = run_vector(chunk, chunk_size=4, trace=True)
    expected = {1: 3, 2: 3, 3: 2}
    if row_result != expected or vector_result != expected:
        raise RuntimeError(
            f"unexpected result: row={row_result}, vector={vector_result}, expected={expected}"
        )
    print(f"\nResult equality: {row_result == vector_result}")
    print(f"Row stats: {row_stats}")
    print(f"Vector stats: {vector_stats}")


def command_benchmark(args: argparse.Namespace) -> None:
    chunk = generate_chunk(args.rows)
    rows = to_rows(chunk)
    for _ in range(2):
        run_row(rows)
        run_vector(chunk, args.chunk_size)
    times: dict[str, list[float]] = {"row": [], "vector": []}
    latest: dict[str, tuple[dict[int, int], ExecutionStats]] = {}
    calls = {
        "row": lambda: run_row(rows),
        "vector": lambda: run_vector(chunk, args.chunk_size),
    }
    for round_number in range(5):
        order = ("row", "vector") if round_number % 2 == 0 else ("vector", "row")
        for name in order:
            elapsed, latest[name] = _timed(calls[name])
            times[name].append(elapsed)
    row_result, row_stats = latest["row"]
    vector_result, vector_stats = latest["vector"]
    if row_result != vector_result:
        raise RuntimeError(f"result mismatch: row={row_result}, vector={vector_result}")
    print(f"Python: {platform.python_version()}")
    print(f"NumPy: {np.__version__}")
    print(f"CPU architecture: {platform.machine()}")
    print(f"Rows: {args.rows}")
    print(f"Chunk size: {args.chunk_size}")
    print("Result equality: True")
    print(f"Row median time: {statistics.median(times['row']):.6f}s")
    print(f"Vector median time: {statistics.median(times['vector']):.6f}s")
    print(f"Rows examined: {row_stats.rows_examined}")
    print(f"Selected rows: {row_stats.selected_rows}")
    print(f"Row filter calls: {row_stats.filter_calls}")
    print(f"Row aggregate calls: {row_stats.aggregate_calls}")
    print(f"Chunks processed: {vector_stats.chunks_processed}")
    print(f"Chunk filter calls: {vector_stats.filter_calls}")
    print(f"Chunk aggregate calls: {vector_stats.aggregate_calls}")


def command_export(args: argparse.Namespace) -> None:
    output = args.output if args.output.is_absolute() else LAB_DIR / args.output
    chunk = generate_chunk(args.rows)
    export_csv(chunk, output)
    print(f"Exported {chunk.row_count} rows to {output}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="StarRocks vectorized execution lab")
    commands = parser.add_subparsers(dest="command", required=True)
    trace = commands.add_parser("trace", help="show Row and Chunk execution")
    trace.set_defaults(handler=command_trace)
    benchmark = commands.add_parser("benchmark", help="compare execution models")
    benchmark.add_argument("--rows", type=_positive, default=1_000_000)
    benchmark.add_argument("--chunk-size", type=_positive, default=4_096)
    benchmark.set_defaults(handler=command_benchmark)
    export = commands.add_parser("export", help="write Stream Load CSV")
    export.add_argument("--rows", type=_positive, default=1_000_000)
    export.add_argument("--output", type=Path, default=DEFAULT_EXPORT)
    export.set_defaults(handler=command_export)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        args.handler(args)
        return 0
    except (RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run unit tests and CLI smoke tests**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
.venv/bin/python -m unittest -v test_demo.py
.venv/bin/python demo.py trace
.venv/bin/python demo.py benchmark --rows 10000 --chunk-size 257
.venv/bin/python demo.py export --rows 1000
test "$(wc -l < data/benchmark_user_chats.csv | tr -d ' ')" = 1001
awk 'NF && $1 !~ /^#/' demo.py | wc -l
```

Expected:

- `Ran 8 tests` followed by `OK`.
- Trace ends with `Result equality: True` and the expected `{1: 3, 2: 3, 3: 2}` partial result.
- Benchmark prints `Result equality: True`, 10,000 examined rows, and fewer Chunk filter calls than Row filter calls.
- Export prints `Exported 1000 rows` and the CSV has 1,001 lines including its header.
- The final line-count command prints a value no greater than `260`.

- [ ] **Step 5: Commit the executable Python lab**

```bash
git add starrocks/vectorized-execution-engine-lab
git commit -m "feat: add vectorized execution lab CLI"
```

---

### Task 3: Disposable StarRocks cluster and deterministic Stream Load

**Files:**
- Create: `starrocks/vectorized-execution-engine-lab/cluster/compose.yaml`
- Create: `starrocks/vectorized-execution-engine-lab/cluster/schema.sql`
- Create: `starrocks/vectorized-execution-engine-lab/cluster/query.sql`
- Create: `starrocks/vectorized-execution-engine-lab/cluster/load.sh`

**Interfaces:**
- Consumes: `data/tiny_user_chats.csv` and generated `data/benchmark_user_chats.csv`.
- Produces: service `starrocks`, database `vector_lab`, Primary Key table `user_chats`, `./cluster/load.sh tiny|benchmark`, and a Profile-enabled query script.

- [ ] **Step 1: Confirm cluster checks fail before assets exist**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
docker compose -f cluster/compose.yaml config
bash -n cluster/load.sh
```

Expected: both commands fail because the files do not exist.

- [ ] **Step 2: Add Compose, schema, query, and load assets**

Create `cluster/compose.yaml` with:

```yaml
services:
  starrocks:
    image: starrocks/allin1-ubuntu:3.3.22
    ports:
      - "9030:9030"
      - "8030:8030"
      - "8040:8040"
    volumes:
      - fe_meta:/data/deploy/starrocks/fe/meta
      - be_storage:/data/deploy/starrocks/be/storage

volumes:
  fe_meta:
  be_storage:
```

Create `cluster/schema.sql` with:

```sql
CREATE DATABASE IF NOT EXISTS vector_lab;
USE vector_lab;

CREATE TABLE IF NOT EXISTS user_chats (
  chat_id BIGINT NOT NULL,
  channel_id INT NOT NULL,
  status VARCHAR(16) NOT NULL
)
PRIMARY KEY (chat_id)
DISTRIBUTED BY HASH(chat_id) BUCKETS 4
PROPERTIES ("replication_num" = "1");
```

Create `cluster/query.sql` with:

```sql
SELECT VERSION() AS starrocks_version;
USE vector_lab;
SELECT COUNT(*) AS loaded_rows FROM user_chats;

EXPLAIN VERBOSE
SELECT channel_id, COUNT(*) AS open_chat_count
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id
ORDER BY channel_id;

SET enable_profile = true;
SELECT channel_id, COUNT(*) AS open_chat_count
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id
ORDER BY channel_id;
SELECT last_query_id() AS profile_query_id;
```

Create executable `cluster/load.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

cluster_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lab_dir="$(cd "$cluster_dir/.." && pwd)"
compose=(docker compose -f "$cluster_dir/compose.yaml")
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

ready=false
for _ in {1..60}; do
  if curl -fsS http://127.0.0.1:8030/api/bootstrap | grep -q '"status":"OK"'; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  echo "StarRocks FE was not ready within 120 seconds" >&2
  echo "check: ${compose[*]} logs starrocks" >&2
  exit 1
fi

mysql_in_container() {
  "${compose[@]}" exec -T starrocks \
    mysql -h127.0.0.1 -P9030 -uroot "$@"
}

mysql_in_container < "$cluster_dir/schema.sql"
mysql_in_container -e "TRUNCATE TABLE vector_lab.user_chats"

expected_rows=$(( $(wc -l < "$csv") - 1 ))
response_file="$(mktemp "${TMPDIR:-/tmp}/vector-lab-load.XXXXXX")"
trap 'rm -f "$response_file"' EXIT
label="vector_lab_${target}_$(date +%s)_$$"

http_code="$(curl --location-trusted --silent --show-error \
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
  http://127.0.0.1:8030/api/vector_lab/user_chats/_stream_load)"

cat "$response_file"
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
```

Run:

```bash
chmod +x cluster/load.sh
```

- [ ] **Step 3: Run static configuration checks**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
bash -n cluster/load.sh
docker compose -f cluster/compose.yaml config --quiet
docker buildx imagetools inspect starrocks/allin1-ubuntu:3.3.22
```

Expected: shell syntax and Compose configuration pass. Image inspection lists the current `linux/arm64` platform and, if published by the official tag, `linux/amd64`; only listed platforms are documented as supported.

- [ ] **Step 4: Start StarRocks and load the tiny dataset**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
docker compose -f cluster/compose.yaml up -d
./cluster/load.sh tiny
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot --batch --skip-column-names \
  -e "SELECT channel_id, COUNT(*) FROM vector_lab.user_chats WHERE status='OPEN' GROUP BY channel_id ORDER BY channel_id"
```

Expected: load ends with `Loaded 12 rows`, followed by query rows `1 3`, `2 3`, and `3 2`.

- [ ] **Step 5: Load benchmark data and capture a real Profile**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
.venv/bin/python demo.py export --rows 10000
./cluster/load.sh benchmark
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot < cluster/query.sql
query_id="$(docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot --batch --skip-column-names \
  -e "USE vector_lab; SET enable_profile=true; SELECT channel_id,COUNT(*) FROM user_chats WHERE status='OPEN' GROUP BY channel_id; SELECT last_query_id()" \
  | tail -1 | tr -d '\r')"
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot --batch --skip-column-names \
  -e "SELECT get_query_profile('$query_id')" \
  | grep -E 'PushRowNum|PullRowNum|RawRowsRead|RowsRead|OperatorTotalTime'
```

Expected: benchmark load ends with `Loaded 10000 rows`; `EXPLAIN VERBOSE` contains an OLAP scan predicate and aggregate; Profile retrieval prints at least one of the required row metrics and `OperatorTotalTime`. If profile publication is asynchronous, retry only the final retrieval command for up to 30 seconds at two-second intervals.

- [ ] **Step 6: Commit the verified StarRocks lab**

```bash
git add starrocks/vectorized-execution-engine-lab/cluster
git commit -m "feat: add disposable StarRocks learning cluster"
```

---

### Task 4: Learner-first README and full verification

**Files:**
- Create: `starrocks/vectorized-execution-engine-lab/README.md`

**Interfaces:**
- Consumes: Tasks 1-3 commands and observed outputs.
- Produces: a start-to-finish curriculum, cleanup commands, Profile metric map, troubleshooting guide, and five comprehension questions.

- [ ] **Step 1: Write the README with executable learning checkpoints**

Create `README.md` with these sections and exact command contracts:

```markdown
# StarRocks Vectorized Execution Engine Lab

이 실습은 하나의 `WHERE status = 'OPEN' GROUP BY channel_id` 쿼리를 Row Python,
NumPy Chunk, StarRocks 3.3.22 순서로 따라간다. 속도 경쟁이 아니라 데이터 이동과
Operator 입출력을 이해하는 것이 목표다.

## 준비

- Python 3.12
- Docker Desktop 또는 Docker Engine + Compose v2
- `curl`

```bash
cd starrocks/vectorized-execution-engine-lab
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

## 1. 먼저 결과를 예측한다

`data/tiny_user_chats.csv`를 읽고 아래 쿼리 결과를 실행 전에 적어 본다.

```sql
SELECT channel_id, COUNT(*) AS open_chat_count
FROM user_chats
WHERE status = 'OPEN'
GROUP BY channel_id
ORDER BY channel_id;
```

예상한 뒤 확인할 정답은 channel 1 → 3, channel 2 → 3, channel 3 → 2다.

## 2. Row와 Chunk trace를 관찰한다

```bash
.venv/bin/python demo.py trace
```

Row trace에서는 입력 행마다 predicate가 한 번 호출된다. Chunk trace에서는 네 행의
`status` Column을 한 번에 비교해 Boolean mask를 만들고, 선택된 `channel_id`만
batch aggregation에 전달한다.

먼저 `demo.py`의 `Column`, `Chunk`, `run_row`, `run_vector`만 읽는다. 나머지 CLI
코드는 실행 흐름을 이해한 뒤 읽는다.

## 3. 호출 횟수와 시간을 구분한다

```bash
.venv/bin/python demo.py benchmark
```

기본값은 seed `20260724`, 1,000,000행, Chunk 4,096행이다. 결과가 같은지 먼저
확인하고 Row filter calls와 Chunk filter calls를 비교한다. 시간은 현재 Python과
NumPy에서 나온 교육용 microbenchmark일 뿐 StarRocks 성능 예측값이 아니다.

빠른 smoke run은 다음과 같다.

```bash
.venv/bin/python demo.py benchmark --rows 10000 --chunk-size 257
```

## 4. 실제 StarRocks를 실행한다

```bash
docker compose -f cluster/compose.yaml up -d
./cluster/load.sh tiny
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot < cluster/query.sql
```

`EXPLAIN VERBOSE`에서 `status = 'OPEN'` predicate가 Scan에 있는지 별도 Filter에
있는지 먼저 찾고, Aggregate node를 찾는다. optimizer 선택에 따라 predicate 위치는
달라질 수 있다.

## 5. 대용량 데이터로 Profile을 본다

```bash
.venv/bin/python demo.py export
./cluster/load.sh benchmark
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot < cluster/query.sql
```

마지막 `profile_query_id`를 복사해 다음 SQL에서 사용한다.

```sql
SELECT get_query_profile('<query_id>')\G
```

또는 `http://localhost:8030`의 Queries 화면에서 같은 Query ID를 연다.

| Python 관찰값 | StarRocks Profile에서 볼 위치 |
|---|---|
| 입력 행 | 해당 Operator의 `PushRowNum` |
| 출력 행 | 해당 Operator의 `PullRowNum` |
| predicate 전 Scan 행 | Scan의 `RawRowsRead` |
| storage predicate 후 행 | Scan의 `RowsRead` |
| 함수별 측정 시간 | 해당 Operator의 `OperatorTotalTime` |

서로 다른 Operator의 수치를 직접 등치하지 않는다. 특히 predicate가 Scan으로
pushdown되면 Python의 selected rows는 별도 Filter가 아니라 Scan의 출력과 더 가까울
수 있다. Profile은 Chunk 객체 자체가 아니라 Operator의 행 수와 시간을 보여준다.

## 검증

```bash
.venv/bin/python -m unittest -v test_demo.py
bash -n cluster/load.sh
docker compose -f cluster/compose.yaml config --quiet
```

unit test는 고정 결과, 결정적 생성, 불완전 마지막 Chunk, 빈 selection, Column 길이,
CSV export를 확인한다.

## 종료와 초기화

컨테이너만 내리면 named volume은 유지된다.

```bash
docker compose -f cluster/compose.yaml down
```

데이터까지 지우고 깨끗하게 다시 시작하려면 다음을 실행한다.

```bash
docker compose -f cluster/compose.yaml down --volumes
```

## 문제 해결

- NumPy import 실패: `.venv/bin/python -m pip install -r requirements.txt`
- FE 준비 실패: `docker compose -f cluster/compose.yaml logs starrocks`
- benchmark CSV 없음: `.venv/bin/python demo.py export`
- 포트 충돌: 8030, 8040, 9030을 사용하는 로컬 프로세스를 종료한 뒤 다시 시작
- Stream Load 실패: `load.sh`가 출력한 JSON의 `Message`와 `ErrorURL` 확인

## 확인 질문

1. Chunk는 Row 목록과 어떻게 다른가?
2. 같은 행 수를 조사해도 Operator 호출 횟수가 다른 이유는 무엇인가?
3. Boolean mask는 Filter와 Aggregate 사이에서 무엇을 전달하는가?
4. 연속 typed Column은 CPU cache와 SIMD에 왜 유리한가?
5. Python의 입출력 행 수는 Profile의 어느 Operator 지표와 연결되는가?
```

- [ ] **Step 2: Execute every documented non-destructive verification command**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
.venv/bin/python -m unittest -v test_demo.py
.venv/bin/python demo.py trace >/tmp/vector-lab-trace.txt
.venv/bin/python demo.py benchmark --rows 10000 --chunk-size 257
.venv/bin/python demo.py export --rows 1000
bash -n cluster/load.sh
docker compose -f cluster/compose.yaml config --quiet
./cluster/load.sh tiny
docker compose -f cluster/compose.yaml exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot < cluster/query.sql
git status --short
```

Expected: all commands exit zero; SQL returns `1 3`, `2 3`, `3 2`; Profile ID is non-empty; Git status does not list `.venv/` or `data/benchmark_user_chats.csv`.

- [ ] **Step 3: Check content constraints and links**

Run:

```bash
cd starrocks/vectorized-execution-engine-lab
test "$(awk 'NF && $1 !~ /^#/' demo.py | wc -l | tr -d ' ')" -le 260
rg -n 'Row|Column|Chunk|Boolean mask|PushRowNum|PullRowNum|RawRowsRead|RowsRead|OperatorTotalTime' README.md
git diff --check
```

Expected: line-count assertion and whitespace check pass; every required concept appears in README.

- [ ] **Step 4: Commit the learning guide**

```bash
git add starrocks/vectorized-execution-engine-lab/README.md
git commit -m "docs: add vectorized execution learning path"
```

---

### Task 5: Final integrated review and cleanup

**Files:**
- Modify only if verification exposes a concrete defect: files under `starrocks/vectorized-execution-engine-lab/`

**Interfaces:**
- Consumes: the full lab from Tasks 1-4.
- Produces: verified final Git state and captured evidence for the handoff.

- [ ] **Step 1: Run the complete verification suite from the repository root**

Run:

```bash
lab=starrocks/vectorized-execution-engine-lab
"$lab/.venv/bin/python" -m unittest discover -s "$lab" -p 'test_*.py' -v
"$lab/.venv/bin/python" "$lab/demo.py" benchmark --rows 10000 --chunk-size 257
bash -n "$lab/cluster/load.sh"
docker compose -f "$lab/cluster/compose.yaml" config --quiet
"$lab/cluster/load.sh" tiny
docker compose -f "$lab/cluster/compose.yaml" exec -T starrocks \
  mysql -h127.0.0.1 -P9030 -uroot --batch --skip-column-names \
  -e "SELECT channel_id,COUNT(*) FROM vector_lab.user_chats WHERE status='OPEN' GROUP BY channel_id ORDER BY channel_id"
git status --short --branch
```

Expected: tests and static checks pass, benchmark reports equality, tiny query returns `1 3`, `2 3`, `3 2`, and only intentional committed plan/implementation state appears in Git.

- [ ] **Step 2: Review the implementation against every design requirement**

Check:

```bash
rg -n '^## ' docs/superpowers/specs/2026-07-24-vectorized-execution-engine-lab-design.md
rg -n '3\.3\.22|20260724|1_000_000|4_096|numpy==2\.4\.4' \
  starrocks/vectorized-execution-engine-lab docs/superpowers/specs
git log --oneline -6
```

Expected: every fixed version and default is present, and separate commits exist for the model, CLI, cluster, and README.

- [ ] **Step 3: Stop the disposable cluster without deleting its reusable volume**

Run:

```bash
docker compose -f starrocks/vectorized-execution-engine-lab/cluster/compose.yaml down
```

Expected: containers and network stop cleanly; volumes remain available for the learner unless they choose `down --volumes` from README.
