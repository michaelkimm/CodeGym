from __future__ import annotations

import argparse
import csv
import gc
import platform
import statistics
import sys
import time
from collections.abc import Callable
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
DEFAULT_EXPORT = LAB_DIR / "data" / "benchmark_user_chats.csv"
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
        rng.choice(
            np.array([0, 1, 2], dtype=np.int8),
            size=rows,
            p=[0.25, 0.60, 0.15],
        ),
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


def export_csv(chunk: Chunk, path: Path) -> None:
    if not path.parent.is_dir():
        raise ValueError(f"output parent directory does not exist: {path.parent}")
    with path.open("w", newline="", encoding="utf-8") as target:
        writer = csv.writer(target, lineterminator="\n")
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
