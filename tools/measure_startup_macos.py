#!/usr/bin/env python3
"""Measure fresh-process Scratchpad startup and interaction costs on macOS.

Build each candidate once, then pass its executable to this runner. Samples
are fresh processes using Scratchpad's bounded native smoke path. The runner
keeps each host log and records process time/CPU/peak RSS using wait4(2).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


HOST_METRICS = (
    "wall_ns",
    "application_build_ns",
    "application_build_max_ns",
    "first_application_submit_ns",
    "frame_p95_ns",
    "gpu_encode_ns",
    "gpu_submissions",
    "application_stabilization_rebuilds",
)
SAMPLE_METRICS = (
    "elapsed_ns",
    "cpu_total_ns",
    "max_rss_bytes",
    "application_build_ns",
    "application_build_max_ns",
    "first_application_submit_ns",
    "wall_ns",
    "frame_p95_ns",
    "gpu_encode_ns",
)


def parse_candidate(value: str) -> tuple[str, Path]:
    label, separator, binary = value.partition("=")
    if not separator or not label.strip() or not binary.strip():
        raise argparse.ArgumentTypeError("candidate must be LABEL=/absolute/path/to/scratchpad-alicorn")
    label = label.strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", label):
        raise argparse.ArgumentTypeError("candidate labels may contain only letters, digits, dot, underscore, and dash")
    return label, Path(binary).expanduser().resolve()


def key_values(line: str, prefix: str) -> dict[str, str]:
    fields = line.split()
    if not fields or fields[0] != prefix:
        return {}
    return dict(zip(fields[1::2], fields[2::2]))


def parse_host_log(log: str, scenario: str = "startup") -> dict[str, int]:
    host_lines = [line.strip() for line in log.splitlines() if line.startswith("SDL application PASS ")]
    smoke_lines = [line.strip() for line in log.splitlines() if line.startswith("alicorn-smoke ")]
    if not host_lines:
        raise ValueError("missing successful SDL application summary")
    if not smoke_lines:
        raise ValueError("missing Scratchpad smoke completion summary")

    fields = host_lines[-1].split()
    host = dict(zip(fields[3::2], fields[4::2]))
    smoke = key_values(smoke_lines[-1], "alicorn-smoke")
    if (
        smoke.get("publication_rendered") != "true"
        or smoke.get("wake_observed") != "true"
        or smoke.get("ordered_shutdown") != "true"
    ):
        raise ValueError(f"smoke acceptance markers did not all pass: {smoke}")

    if scenario == "interaction":
        sequence_lines = [line.strip() for line in log.splitlines() if line.startswith("alicorn-performance-sequence ")]
        sequence = key_values(sequence_lines[-1], "alicorn-performance-sequence") if sequence_lines else {}
        if sequence.get("steps") != "9" or sequence.get("complete") != "true" or sequence.get("passed") != "true":
            raise ValueError(f"interaction sequence did not complete all 9 actions: {sequence}")

    parsed: dict[str, int] = {}
    for key in HOST_METRICS:
        source_key = "primary_gpu_submissions" if key == "gpu_submissions" else key
        if source_key in host:
            parsed[key] = int(host[source_key])
    for key in ("wall_ns", "application_build_max_ns", "first_application_submit_ns", "gpu_submissions"):
        if key not in parsed:
            raise ValueError(f"host summary omitted required metric {key}")
    if parsed["application_build_max_ns"] <= 0:
        raise ValueError("application build timing was zero; expected at least one build callback")
    return parsed


def percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def summarize(values: list[int]) -> dict[str, int | float]:
    return {
        "min": min(values),
        "median": statistics.median(values),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def sample_metric(sample: dict[str, Any], name: str) -> int | None:
    value = sample.get(name, sample["host"].get(name))
    return None if value is None else int(value)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_identity(binary: Path) -> dict[str, str]:
    identity: dict[str, str] = {}
    for filename in ("artifact-manifest.json", "measurement-provenance.json"):
        manifest_path = binary.parent / filename
        if not manifest_path.is_file():
            continue
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for key in (
            "alicorn_commit",
            "caliber_commit",
            "scratchpad_commit",
            "odin_version",
            "build_profile",
            "alicorn_runtime_tree_sha256",
            "scratchpad_tree_sha256",
        ):
            if isinstance(manifest.get(key), str):
                identity[key] = manifest[key]
    return identity


def system_info() -> dict[str, str]:
    info = {
        "os": platform.platform(),
        "macos": platform.mac_ver()[0] or "unknown",
        "architecture": platform.machine(),
        "python": platform.python_version(),
    }
    for key, command in (
        ("model", ["/usr/sbin/sysctl", "-n", "hw.model"]),
        ("cpu", ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]),
        ("macos_product_version", ["/usr/bin/sw_vers", "-productVersion"]),
    ):
        try:
            completed = subprocess.run(command, capture_output=True, text=True, check=True, timeout=2)
            info[key] = completed.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return info


def make_workspace(root: Path, large_document_lines: int = 0) -> None:
    """Create a deterministic workspace, optionally with a large Go document."""
    (root / "README.md").write_text(
        "# Scratchpad startup fixture\n\n"
        "Generated by tools/measure_startup_macos.py. This workspace is disposable.\n",
        encoding="utf-8",
    )
    folders = ("application", "editor", "document", "runtime", "tests", "docs", "themes", "tools")
    extensions = (".go", ".odin", ".md", ".json", ".txt", ".ts")
    for folder_index, folder in enumerate(folders):
        directory = root / folder
        directory.mkdir()
        for file_index in range(24):
            extension = extensions[(folder_index + file_index) % len(extensions)]
            path = directory / f"sample_{file_index:02d}{extension}"
            if folder == "application" and file_index == 0 and large_document_lines:
                lines = ["package sample", ""] + [
                    f"func GeneratedRow{line_index:05d}() int {{ return {line_index} }}"
                    for line_index in range(large_document_lines)
                ]
            else:
                lines = [f"// fixture {folder}/{path.name} row {line_index:02d}" for line_index in range(32)]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def wait_for_child(pid: int, timeout_seconds: float) -> tuple[int, Any, bool]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            waited_pid, status, usage = os.wait4(pid, os.WNOHANG)
        except InterruptedError:
            continue
        if waited_pid == pid:
            return status, usage, False
        if time.monotonic() >= deadline:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            terminate_deadline = time.monotonic() + 1.0
            while time.monotonic() < terminate_deadline:
                try:
                    waited_pid, status, usage = os.wait4(pid, os.WNOHANG)
                except InterruptedError:
                    continue
                if waited_pid == pid:
                    return status, usage, True
                time.sleep(0.02)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            while True:
                try:
                    _, status, usage = os.wait4(pid, 0)
                    return status, usage, True
                except InterruptedError:
                    continue
        time.sleep(0.02)


def run_sample(
    label: str,
    binary: Path,
    workspace: Path,
    results_dir: Path,
    run_name: str,
    timeout_seconds: float,
    scenario: str,
) -> dict[str, Any]:
    log_path = results_dir / f"{label}-{run_name}.log"
    environment = os.environ.copy()
    environment["SCRATCHPAD_ALICORN_SMOKE"] = "1"
    if scenario == "interaction":
        environment["SCRATCHPAD_ALICORN_PERF_SEQUENCE"] = "1"
    else:
        environment.pop("SCRATCHPAD_ALICORN_PERF_SEQUENCE", None)
    environment["SCRATCHPAD_ALICORN_WORKSPACE"] = str(workspace)
    environment.pop("SCRATCHPAD_BACKEND_LIBRARY", None)
    runtime_dir = str(binary.parent)
    existing_library_path = environment.get("DYLD_LIBRARY_PATH", "")
    environment["DYLD_LIBRARY_PATH"] = runtime_dir + (
        os.pathsep + existing_library_path if existing_library_path else ""
    )

    started_ns = time.monotonic_ns()
    with log_path.open("wb") as log_file:
        pid = os.fork()
        if pid == 0:
            try:
                os.chdir(tempfile.gettempdir())
                null_fd = os.open(os.devnull, os.O_RDONLY)
                os.dup2(null_fd, 0)
                os.dup2(log_file.fileno(), 1)
                os.dup2(log_file.fileno(), 2)
                if null_fd > 2:
                    os.close(null_fd)
                os.execve(str(binary), [str(binary)], environment)
            except BaseException as error:
                os.write(2, f"startup measurement child failed: {error}\n".encode())
                os._exit(127)
        status, usage, timed_out = wait_for_child(pid, timeout_seconds)
    elapsed_ns = time.monotonic_ns() - started_ns
    log = log_path.read_text(encoding="utf-8", errors="replace")
    exit_code = os.waitstatus_to_exitcode(status)
    if timed_out:
        raise RuntimeError(f"{label} {run_name} exceeded {timeout_seconds}s; log: {log_path}")
    if exit_code != 0:
        raise RuntimeError(f"{label} {run_name} exited {exit_code}; log: {log_path}\n{log[-4000:]}")
    try:
        host_metrics = parse_host_log(log, scenario)
    except ValueError as error:
        raise RuntimeError(
                f"{label} {run_name} did not satisfy {scenario} smoke/telemetry checks: {error}; "
            f"log: {log_path}\n{log[-4000:]}"
        ) from error

    cpu_user_ns = round(usage.ru_utime * 1_000_000_000)
    cpu_system_ns = round(usage.ru_stime * 1_000_000_000)
    return {
        "candidate": label,
        "run": run_name,
        "exit_code": exit_code,
        "elapsed_ns": elapsed_ns,
        "cpu_user_ns": cpu_user_ns,
        "cpu_system_ns": cpu_system_ns,
        "cpu_total_ns": cpu_user_ns + cpu_system_ns,
        # macOS reports ru_maxrss in bytes.
        "max_rss_bytes": int(usage.ru_maxrss),
        "host": host_metrics,
        "log": str(log_path),
    }


def paired_comparison(samples: list[dict[str, Any]], baseline: str, candidate: str) -> dict[str, Any]:
    old = {sample["run"]: sample for sample in samples if sample["candidate"] == baseline}
    new = {sample["run"]: sample for sample in samples if sample["candidate"] == candidate}
    comparisons: dict[str, Any] = {}
    for metric in SAMPLE_METRICS:
        changes = []
        for run_name in sorted(old.keys() & new.keys()):
            before = sample_metric(old[run_name], metric)
            after = sample_metric(new[run_name], metric)
            if before is not None and after is not None and before != 0:
                changes.append((after - before) * 100.0 / before)
        if changes:
            comparisons[metric] = {
                "median_percent_change": statistics.median(changes),
                "paired_percent_changes": changes,
            }
    return {"baseline": baseline, "candidate": candidate, "metrics": comparisons}


def write_report(results_dir: Path, report: dict[str, Any]) -> None:
    (results_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    rows = []
    for candidate in report["candidates"]:
        summary = candidate["summary"]
        rows.append(
            "| {label} | {elapsed} | {cpu} | {rss} | {build_total} | {build_max} | {first_submit} | {host} |".format(
                label=candidate["label"],
                elapsed=f"{summary['elapsed_ns']['median'] / 1e6:.2f} ms",
                cpu=f"{summary['cpu_total_ns']['median'] / 1e6:.2f} ms",
                rss=f"{summary['max_rss_bytes']['median'] / (1024 * 1024):.1f} MiB",
                build_total=(
                    f"{summary['application_build_ns']['median'] / 1e6:.2f} ms"
                    if "application_build_ns" in summary
                    else "n/a"
                ),
                build_max=f"{summary['application_build_max_ns']['median'] / 1e6:.2f} ms",
                first_submit=f"{summary['first_application_submit_ns']['median'] / 1e6:.2f} ms",
                host=f"{summary['wall_ns']['median'] / 1e6:.2f} ms",
            )
        )
    markdown = [
        f"# Scratchpad macOS {report['scenario']} smoke measurements",
        "",
        f"- Scratchpad revision: {report['scratchpad_revision']}",
        f"- Scenario: {report['scenario']}",
        f"- Runs per candidate: {report['runs_per_candidate']} (after {report['warmups_per_candidate']} warm-up)",
        f"- System: {report['system'].get('model', 'unknown')} · macOS {report['system'].get('macos_product_version', report['system'].get('macos', 'unknown'))} · {report['system'].get('architecture', 'unknown')}",
        f"- Workspace: {report['workspace_description']}",
        *[
            f"- {candidate['label']} Alicorn revision: {candidate['build_identity'].get('alicorn_commit', 'not recorded')}"
            for candidate in report["candidates"]
        ],
        *[
            f"- {candidate['label']} Alicorn runtime tree SHA-256: {candidate['build_identity'].get('alicorn_runtime_tree_sha256', 'not recorded')}"
            for candidate in report["candidates"]
        ],
        *[
            f"- {candidate['label']} binary SHA-256: {candidate['binary_sha256']}"
            for candidate in report["candidates"]
        ],
        "- Each sample is a fresh process using Scratchpad's native smoke path; smoke must report publication, wake, and ordered shutdown.",
        "- Elapsed time and CPU/RSS cover the full bounded smoke process. application_build_ns is cumulative wall time in application-description callbacks; application_build_max_ns is the slowest callback. first_application_submit_ns is the first successful application-frame GPU submission, not visible-pixel presentation. Host wall_ns includes the smoke wait.",
        "- The interaction scenario runs nine actions through Scratchpad's existing commands and UI state paths: open README, open a Go file, switch documents, open and close Quick Open, open and close Settings, then close both documents. The fixture checks completion before a sample is accepted.",
        f"- Percentiles use nearest-rank; at {report['runs_per_candidate']} measured runs, p95 is the {math.ceil(0.95 * report['runs_per_candidate'])}th ordered sample (the maximum with seven runs), not a stable tail-latency estimate.",
        "",
        "| Candidate | Process elapsed median | CPU median | Peak RSS median | Total app build median | Max app build median | First app submit median | Host loop median |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        *rows,
    ]
    comparison = report.get("paired_comparison")
    if comparison:
        markdown.extend(
            [
                "",
                f"Paired median percent change: {comparison['candidate']} relative to {comparison['baseline']} (negative means lower).",
                "",
                "| Metric | Median paired change |",
                "| --- | ---: |",
            ]
        )
        for metric, result in comparison["metrics"].items():
            markdown.append(f"| {metric} | {result['median_percent_change']:+.1f}% |")
    markdown.extend(["", "Raw per-process logs and summary.json are in this results directory.", ""])
    (results_dir / "summary.md").write_text("\n".join(markdown), encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate",
        action="append",
        required=True,
        type=parse_candidate,
        metavar="LABEL=PATH",
        help="candidate executable, repeat to compare builds",
    )
    parser.add_argument("--runs", type=int, default=7, help="fresh measured processes per candidate (default: 7)")
    parser.add_argument("--warmups", type=int, default=1, help="unreported fresh process per candidate (default: 1)")
    parser.add_argument("--workspace", type=Path, help="read-only workspace to open; default is a generated 193-file fixture")
    parser.add_argument(
        "--large-document-lines",
        type=int,
        default=0,
        help="generate application/sample_00.go with this many function rows; use with --scenario interaction",
    )
    parser.add_argument("--results-dir", type=Path, required=True, help="directory for raw logs and summary reports")
    parser.add_argument("--timeout-seconds", type=float, default=20.0, help="per-process timeout (default: 20)")
    parser.add_argument("--scenario", choices=("startup", "interaction"), default="startup", help="bounded app scenario to exercise")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if sys.platform != "darwin":
        raise SystemExit("This runner uses macOS wait4 RSS units and SDL/Cocoa; run it on macOS.")
    if args.runs < 3:
        raise SystemExit("--runs must be at least 3")
    if args.warmups < 0 or args.timeout_seconds <= 0:
        raise SystemExit("--warmups must be nonnegative and timeout must be positive")
    if args.large_document_lines < 0:
        raise SystemExit("--large-document-lines must be nonnegative")
    if args.large_document_lines and args.workspace:
        raise SystemExit("--large-document-lines cannot be combined with --workspace")
    if args.large_document_lines and args.scenario != "interaction":
        raise SystemExit("--large-document-lines requires --scenario interaction")
    labels = [label for label, _ in args.candidate]
    if len(set(labels)) != len(labels):
        raise SystemExit("candidate labels must be unique")
    for label, binary in args.candidate:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise SystemExit(f"{label} executable is missing or not executable: {binary}")

    results_dir = args.results_dir.expanduser().resolve()
    results_dir.mkdir(parents=True, exist_ok=True)
    temporary_workspace: tempfile.TemporaryDirectory[str] | None = None
    if args.workspace:
        workspace = args.workspace.expanduser().resolve()
        if not workspace.is_dir():
            raise SystemExit(f"workspace is not a directory: {workspace}")
        workspace_description = str(workspace)
    else:
        temporary_workspace = tempfile.TemporaryDirectory(prefix="scratchpad-startup-workspace-")
        workspace = Path(temporary_workspace.name)
        make_workspace(workspace, args.large_document_lines)
        workspace_description = "generated fixture (8 folders, 192 source files, README)"
        if args.large_document_lines:
            workspace_description += (
                f"; application/sample_00.go contains {args.large_document_lines + 2} lines "
                f"({args.large_document_lines} generated functions)"
            )

    try:
        samples: list[dict[str, Any]] = []
        for warmup in range(args.warmups):
            for label, binary in args.candidate:
                run_sample(label, binary, workspace, results_dir, f"warmup-{warmup + 1:02d}", args.timeout_seconds, args.scenario)
        for round_index in range(args.runs):
            offset = round_index % len(args.candidate)
            order = args.candidate[offset:] + args.candidate[:offset]
            for label, binary in order:
                samples.append(
                    run_sample(
                        label,
                        binary,
                        workspace,
                        results_dir,
                        f"run-{round_index + 1:02d}",
                        args.timeout_seconds,
                        args.scenario,
                    )
                )

        candidate_reports = []
        for label, binary in args.candidate:
            own_samples = [sample for sample in samples if sample["candidate"] == label]
            summary: dict[str, Any] = {}
            for metric in SAMPLE_METRICS:
                values = [value for sample in own_samples if (value := sample_metric(sample, metric)) is not None]
                if values:
                    summary[metric] = summarize(values)
            candidate_reports.append(
                {
                    "label": label,
                    "binary": str(binary),
                    "binary_sha256": sha256_file(binary),
                    "runtime_directory": str(binary.parent),
                    "build_identity": build_identity(binary),
                    "summary": summary,
                }
            )

        revision = subprocess.run(
            ["git", "-C", str(Path(__file__).resolve().parent.parent), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        report: dict[str, Any] = {
            "schema": 1,
            "scenario": args.scenario,
            "scratchpad_revision": revision.stdout.strip() if revision.returncode == 0 else "unknown",
            "system": system_info(),
            "workspace_description": workspace_description,
            "runs_per_candidate": args.runs,
            "warmups_per_candidate": args.warmups,
            "candidates": candidate_reports,
            "samples": samples,
        }
        if len(candidate_reports) == 2:
            report["paired_comparison"] = paired_comparison(
                samples, candidate_reports[0]["label"], candidate_reports[1]["label"]
            )
        write_report(results_dir, report)
        print((results_dir / "summary.md").read_text(encoding="utf-8"))
        print(f"Results: {results_dir}")
    finally:
        if temporary_workspace is not None:
            temporary_workspace.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
