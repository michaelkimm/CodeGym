import csv
import tempfile
import unittest
from pathlib import Path

import numpy as np

import demo


class ExecutionModelTest(unittest.TestCase):
    def test_export_writes_header_rows_and_status_names(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "export.csv"
            demo.export_csv(demo.generate_chunk(7), output)

            with output.open(newline="", encoding="utf-8") as source:
                rows = list(csv.DictReader(source))

        self.assertEqual(7, len(rows))
        self.assertEqual(["chat_id", "channel_id", "status"], list(rows[0]))
        self.assertIn(rows[0]["status"], {"OPEN", "CLOSED", "SNOOZED"})

    def test_export_uses_lf_line_endings(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "export.csv"
            demo.export_csv(demo.generate_chunk(1), output)

            exported = output.read_bytes()

        self.assertNotIn(b"\r", exported)
        self.assertEqual(2, exported.count(b"\n"))

    def test_export_requires_existing_parent_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "missing" / "export.csv"
            with self.assertRaisesRegex(ValueError, "parent directory"):
                demo.export_csv(demo.generate_chunk(1), output)

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
