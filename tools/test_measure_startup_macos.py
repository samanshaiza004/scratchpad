import unittest

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
                "frame_p95_ns 400 gpu_encode_ns 500 application_build_ns 450 application_build_max_ns 250 "
                "application_stabilization_rebuilds 1",
                "alicorn-smoke publication_rendered true wake_observed true ordered_shutdown true",
            )
        )
        metrics = measurement.parse_host_log(log)
        self.assertEqual(metrics["application_build_ns"], 450)
        self.assertEqual(metrics["application_build_max_ns"], 250)
        self.assertEqual(metrics["wall_ns"], 1000)
        self.assertEqual(metrics["gpu_submissions"], 9)

    def test_parse_host_log_rejects_incomplete_smoke(self):
        log = (
            "SDL application PASS wall_ns 1000 application_build_ns 450 application_build_max_ns 250 primary_gpu_submissions 1\n"
            "alicorn-smoke publication_rendered true wake_observed false ordered_shutdown true\n"
        )
        with self.assertRaises(ValueError):
            measurement.parse_host_log(log)

    def test_parse_host_log_accepts_hosts_without_aggregate_build_metric(self):
        log = (
            "SDL application PASS wall_ns 1000 application_build_max_ns 250 primary_gpu_submissions 1\n"
            "alicorn-smoke publication_rendered true wake_observed true ordered_shutdown true\n"
        )
        metrics = measurement.parse_host_log(log)
        self.assertEqual(metrics["application_build_max_ns"], 250)
        self.assertNotIn("application_build_ns", metrics)

    def test_summary_statistics(self):
        summary = measurement.summarize([10, 20, 30, 40, 50])
        self.assertEqual(summary["median"], 30)
        self.assertEqual(summary["p95"], 50)
        self.assertEqual(summary["min"], 10)
        self.assertEqual(summary["max"], 50)


if __name__ == "__main__":
    unittest.main()
