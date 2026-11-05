import json
import tempfile
import unittest
from pathlib import Path

import measure_startup_macos as measurement


class MeasurementHelpersTest(unittest.TestCase):
    def test_parse_candidate(self):
        label, binary = measurement.parse_candidate("baseline=/tmp/build/scratchpad-alicorn")
        self.assertEqual(label, "baseline")
        self.assertEqual(binary.name, "scratchpad-alicorn")

    def test_parse_candidate_requires_label_and_path(self):
        with self.assertRaises(Exception):
            measurement.parse_candidate("missing-separator")

    def test_parse_host_log_extracts_build_metrics_and_requires_clean_smoke(self):
        log = "\n".join(
            (
                "SDL application PASS submissions 12 primary_gpu_submissions 9 retired 12 wall_ns 1000 "
                "frame_p95_ns 400 gpu_encode_ns 500 first_application_submit_ns 350 "
                "application_build_ns 450 application_build_max_ns 250 "
                "application_stabilization_rebuilds 1",
                "alicorn-smoke publication_rendered true wake_observed true ordered_shutdown true",
            )
        )
        metrics = measurement.parse_host_log(log)
        self.assertEqual(metrics["application_build_ns"], 450)
        self.assertEqual(metrics["application_build_max_ns"], 250)
        self.assertEqual(metrics["first_application_submit_ns"], 350)
        self.assertEqual(metrics["wall_ns"], 1000)
        self.assertEqual(metrics["gpu_submissions"], 9)

    def test_parse_host_log_rejects_incomplete_smoke(self):
        log = (
            "SDL application PASS wall_ns 1000 first_application_submit_ns 350 application_build_ns 450 application_build_max_ns 250 primary_gpu_submissions 1\n"
            "alicorn-smoke publication_rendered true wake_observed false ordered_shutdown true\n"
        )
        with self.assertRaises(ValueError):
            measurement.parse_host_log(log)

    def test_parse_host_log_accepts_hosts_without_aggregate_build_metric(self):
        log = (
            "SDL application PASS wall_ns 1000 first_application_submit_ns 350 application_build_max_ns 250 primary_gpu_submissions 1\n"
            "alicorn-smoke publication_rendered true wake_observed true ordered_shutdown true\n"
        )
        metrics = measurement.parse_host_log(log)
        self.assertEqual(metrics["application_build_max_ns"], 250)
        self.assertNotIn("application_build_ns", metrics)

    def test_parse_host_log_requires_complete_interaction_fixture(self):
        log = "\n".join(
            (
                "SDL application PASS wall_ns 1000 application_build_max_ns 250 first_application_submit_ns 350 primary_gpu_submissions 1",
                "alicorn-smoke publication_rendered true wake_observed true ordered_shutdown true",
                "alicorn-performance-sequence steps 9 complete true passed true",
            )
        )
        metrics = measurement.parse_host_log(log, scenario="interaction")
        self.assertEqual(metrics["first_application_submit_ns"], 350)
        incomplete = log.replace("steps 9 complete true passed true", "steps 8 complete false passed false")
        with self.assertRaises(ValueError):
            measurement.parse_host_log(incomplete, scenario="interaction")

    def test_build_identity_merges_dirty_source_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "scratchpad-alicorn"
            binary.touch()
            (root / "artifact-manifest.json").write_text(
                json.dumps({"alicorn_commit": "e3f2f1c", "caliber_commit": "197cd96"}),
                encoding="utf-8",
            )
            (root / "measurement-provenance.json").write_text(
                json.dumps(
                    {
                        "alicorn_commit": "e3f2f1c+local-host-probe",
                        "scratchpad_commit": "6f60a79",
                        "odin_version": "dev-2026-11-nightly:9a69916",
                        "build_profile": "release",
                        "alicorn_runtime_tree_sha256": "runtime-tree-hash",
                        "scratchpad_tree_sha256": "scratchpad-tree-hash",
                        "ignored_field": "omit",
                    }
                ),
                encoding="utf-8",
            )
            identity = measurement.build_identity(binary)
            self.assertEqual(identity["alicorn_commit"], "e3f2f1c+local-host-probe")
            self.assertEqual(identity["caliber_commit"], "197cd96")
            self.assertEqual(identity["scratchpad_commit"], "6f60a79")
            self.assertEqual(identity["alicorn_runtime_tree_sha256"], "runtime-tree-hash")
            self.assertNotIn("ignored_field", identity)

    def test_paired_comparison_skips_optional_metrics_missing_from_either_candidate(self):
        baseline_only = [
            {"candidate": "baseline", "run": "run-01", "host": {"application_build_ns": 100}},
            {"candidate": "candidate", "run": "run-01", "host": {}},
        ]
        candidate_only = [
            {"candidate": "baseline", "run": "run-01", "host": {}},
            {"candidate": "candidate", "run": "run-01", "host": {"application_build_ns": 125}},
        ]
        for samples in (baseline_only, candidate_only):
            with self.subTest(samples=samples):
                result = measurement.paired_comparison(samples, "baseline", "candidate")
                self.assertNotIn("application_build_ns", result["metrics"])

    def test_summary_statistics(self):
        summary = measurement.summarize([10, 20, 30, 40, 50])
        self.assertEqual(summary["median"], 30)
        self.assertEqual(summary["p95"], 50)
        self.assertEqual(summary["min"], 10)
        self.assertEqual(summary["max"], 50)

    def test_make_workspace_can_generate_large_go_document(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            measurement.make_workspace(root, large_document_lines=12)
            lines = (root / "application/sample_00.go").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 14)
            self.assertEqual(lines[0], "package sample")
            self.assertEqual(lines[-1], "func GeneratedRow00011() int { return 11 }")


if __name__ == "__main__":
    unittest.main()
