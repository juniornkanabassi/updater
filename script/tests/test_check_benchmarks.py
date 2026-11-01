import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "check_benchmarks", Path(__file__).resolve().parents[1] / "check_benchmarks.py")
gates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gates)

APP = """\
APP_BENCHMARK name=cold_launch_to_populated_sidebar_fixture p50_ms=1
APP_BENCHMARK name=selection_to_detail p95_ms=1
APP_BENCHMARK name=selection_to_render_memory p95_ms=1
APP_BENCHMARK name=selection_to_render_disk p95_ms=1
APP_BENCHMARK name=selection_to_render_cold p95_ms=1
APP_MEMORY name=repeated_selection delta_bytes=100
"""
COMPLEXITY = """\
BENCHMARK name=app_data_store_update_batch p95_ms=1
BENCHMARK name=update_result_acceptance_overlap p95_ms=1
BENCHMARK name=app_list_snapshot_build_and_lookup p95_ms=1
BENCHMARK name=app_list_search_refilter p95_ms=1
BENCHMARK name=app_list_search_full_rebuild p95_ms=2
BENCHMARK name=version_comparison_repeated_parse p95_ms=1
BENCHMARK name=release_notes_markup_parse_and_render p95_ms=1
BENCHMARK name=release_notes_persistent_cache_read p95_ms=1
BENCHMARK name=update_repository_catalog_decode p95_ms=2
BENCHMARK name=update_repository_compact_index_decode p95_ms=1
BENCHMARK name=update_repository_entry_metadata_and_matching p95_ms=1
BENCHMARK name=update_repository_lazy_metadata_and_matching p95_ms=1
BENCHMARK name=bundle_collection_path_filtering p95_ms=1
BENCHMARK name=update_check_scheduler_fixture p95_ms=1
"""


class BenchmarkGateTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.report = self.root / "report.txt"
        self.log = self.root / "report.log"
        self.log.write_text("")
        self.baseline = self.root / "baseline.txt"
        self.baseline.write_text(APP)

    def check(self, text=APP, mode="app"):
        self.report.write_text(text)
        with contextlib.redirect_stdout(io.StringIO()):
            return gates.check(mode, self.report, log=self.log, baseline=self.baseline)

    def test_valid_reports_pass(self):
        self.assertTrue(self.check())
        self.assertTrue(self.check(COMPLEXITY, "complexity"))
        self.assertTrue(self.check(mode="compare"))
        self.baseline.write_text(APP.replace("APP_", "MIGRATION_"))
        self.assertTrue(self.check(mode="compare"))

    def test_missing_malformed_nonfinite_and_negative_metrics_are_errors(self):
        for value in ("", "oops", "nan", "inf", "-1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check(APP.replace("p50_ms=1", "p50_ms=" + value))
        with self.assertRaises(ValueError):
            self.check(APP.replace("p50_ms=1", "median_ms=1"))
        with self.assertRaises(ValueError):
            self.check("\n".join(APP.splitlines()[1:]))
        with self.assertRaises(ValueError):
            self.check(COMPLEXITY.replace("p95_ms=1", "p95_ms=invalid", 1), "complexity")

    def test_duplicate_measurements_are_errors(self):
        with self.assertRaises(ValueError):
            self.check(APP + APP.splitlines()[0])

    def test_absolute_and_relative_budgets_are_enforced(self):
        self.assertFalse(self.check(APP.replace(
            "selection_to_render_cold p95_ms=1",
            "selection_to_render_cold p95_ms=101")))
        self.assertFalse(self.check(COMPLEXITY.replace(
            "app_data_store_update_batch p95_ms=1", "app_data_store_update_batch p95_ms=41"),
            "complexity"))
        self.assertFalse(self.check(COMPLEXITY.replace(
            "app_list_search_refilter p95_ms=1", "app_list_search_refilter p95_ms=1.5"),
            "complexity"))
        self.assertFalse(self.check(APP.replace("p50_ms=1", "p50_ms=1.1504"), "compare"))

    def test_zero_comparison_baseline_is_an_error(self):
        self.baseline.write_text(APP.replace("p50_ms=1", "p50_ms=0"))
        with self.assertRaises(ValueError):
            self.check(mode="compare")
        with self.assertRaises(ValueError):
            self.check(COMPLEXITY.replace("p95_ms=1", "p95_ms=0")
                       .replace("p95_ms=2", "p95_ms=0"), "complexity")

    def test_missing_log_cannot_pass_and_runtime_warnings_fail(self):
        self.log.unlink()
        for mode in ("app", "compare"):
            with self.subTest(mode=mode), self.assertRaises(FileNotFoundError):
                self.check(mode=mode)
        for warning in ("reentrant operation in its NSTableView delegate",
                        "Publishing changes from within view updates"):
            self.log.write_text(warning)
            self.assertFalse(self.check())
            self.assertFalse(self.check(mode="compare"))

    def test_memory_checks_all_samples_and_allows_reduction(self):
        self.assertFalse(self.check(APP.replace("delta_bytes=100", "delta_bytes=25165825")))
        self.assertFalse(self.check(APP.replace("delta_bytes=100", "delta_bytes=25165825")
                                   + "APP_MEMORY name=repeated_selection_2 delta_bytes=0\n"))
        self.assertTrue(self.check(APP.replace("delta_bytes=100", "delta_bytes=-100")))
        with self.assertRaises(ValueError):
            self.check(APP.replace("delta_bytes=100", "samples=1"))


if __name__ == "__main__":
    unittest.main()
