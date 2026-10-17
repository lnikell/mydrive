#!/usr/bin/env python3
"""Opt-in, verified transfer benchmark for the one authorized disposable share.

Password input is a terminal prompt, or raw piped stdin with --password-stdin.
Every helper is measured with wait4: peak RSS belongs to that individual native
process, not a subtraction of cumulative RUSAGE_CHILDREN high-water marks.
"""
import argparse
import datetime
import getpass
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import signal
import subprocess
import sys
import time
import uuid

from nas_test_config import load_nas_test_config, validate_nas_test_config

PROJECT = Path(__file__).resolve().parents[1]
FIXTURE_BYTES = 256 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
FRAME_BYTES = 8 * 1024 * 1024


class BenchmarkError(Exception):
    pass


def validate_target(report, target):
    try:
        recorded = validate_nas_test_config(report.get("target"))
        expected = validate_nas_test_config(target)
    except ValueError as error:
        raise BenchmarkError("fixture NAS test metadata is missing or malformed; inspect retained evidence") from error
    if recorded != expected:
        raise BenchmarkError("recorded fixture targets different NAS test metadata; no operation has run")


class Frames:
    """Bound each frame before appending; never retain the whole output stream."""
    def __init__(self, consume):
        self.pending = bytearray()
        self.consume = consume

    def feed(self, data):
        start = 0
        while start < len(data):
            newline = data.find(b"\n", start)
            end = len(data) if newline < 0 else newline
            if len(self.pending) + end - start > FRAME_BYTES:
                raise BenchmarkError("helper JSON frame exceeds 8 MiB")
            self.pending.extend(data[start:end])
            if newline < 0:
                return
            if not self.pending:
                raise BenchmarkError("helper emitted an empty frame")
            self.consume(json.loads(self.pending))
            self.pending.clear()
            start = end + 1

    def finish(self):
        if self.pending:
            raise BenchmarkError("helper output ended inside a JSON frame")


class Events:
    def __init__(self):
        self.connected = None
        self.complete = None
        self.error = None
        self.names = []
        self.progress_bytes = 0

    def consume(self, event):
        if not isinstance(event, dict) or self.complete is not None or self.error is not None:
            raise BenchmarkError("invalid helper event sequence")
        kind = event.get("type")
        if kind == "connected" and self.connected is None:
            if not isinstance(event.get("security"), dict) or event["security"].get("signing") is not True:
                raise BenchmarkError("helper did not confirm SMB signing")
            self.connected = event
        elif kind == "error":
            self.error = {"code": event.get("code"), "message": event.get("message")}
        elif self.connected is None:
            raise BenchmarkError("helper omitted connection event")
        elif kind == "complete":
            if not isinstance(event.get("result"), dict):
                raise BenchmarkError("helper completion omitted its result")
            self.complete = event
        elif kind == "progress":
            value = event.get("bytes")
            if not isinstance(value, int) or value < self.progress_bytes:
                raise BenchmarkError("invalid helper progress")
            self.progress_bytes = value
        elif kind == "page":
            entries = event.get("entries")
            if not isinstance(entries, list) or len(entries) > 1000:
                raise BenchmarkError("helper directory page exceeds 1000 entries")
            if len(self.names) + len(entries) > 1000:
                raise BenchmarkError("test directory unexpectedly contains over 1000 entries")
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
                    raise BenchmarkError("helper directory entry omitted its name")
                self.names.append(entry["name"])
        else:
            raise BenchmarkError("unexpected helper event")


class Helper:
    def __init__(self, binary, password, root, report, save, timeout=600, *, target=None):
        self.binary, self.password, self.root = binary, password, root
        self.report, self.save, self.timeout = report, save, timeout
        self.target = load_nas_test_config() if target is None else validate_nas_test_config(target)
        if "target" in report:
            validate_target(report, self.target)

    def run(self, command, *arguments, expect_error=None):
        args = [str(self.binary)]
        for key, value in self.target.items():
            args.extend(["--" + key, value])
        args.extend(["--password-stdin", "--test-root", self.root, command, *map(str, arguments)])
        record = {"command": command, "arguments": list(map(str, arguments))}
        self.report["operations"].append(record)
        self.save()
        events = Events()
        frames = Frames(events.consume)
        started = time.perf_counter()
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        record["pid"] = process.pid
        reaped = False
        try:
            try:
                process.stdin.write(self.password)
                process.stdin.close()
            except BrokenPipeError:
                pass
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                eof = False
                while not (eof and reaped):
                    if time.perf_counter() - started > self.timeout:
                        raise BenchmarkError("helper exceeded its operation deadline")
                    for key, _ in selector.select(0.1):
                        data = os.read(key.fd, 65536)
                        if data:
                            frames.feed(data)
                        else:
                            selector.unregister(key.fileobj)
                            eof = True
                    if not reaped:
                        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
                        if pid:
                            reaped = True
                            process.returncode = os.waitstatus_to_exitcode(status)
                            rss_scale = 1 if sys.platform == "darwin" else 1024
                            record.update(peak_rss_bytes=usage.ru_maxrss * rss_scale,
                                          user_cpu_seconds=usage.ru_utime,
                                          system_cpu_seconds=usage.ru_stime)
                frames.finish()
            record.update(wall_seconds=time.perf_counter() - started,
                          exit_code=process.returncode, connected=events.connected,
                          complete=events.complete, error=events.error)
            if expect_error:
                if process.returncode == 0 or not events.error or events.error["code"] != expect_error:
                    raise BenchmarkError("expected helper error: " + expect_error)
            elif process.returncode != 0 or events.error or events.complete is None:
                code = events.error["code"] if events.error else "missing_complete"
                raise BenchmarkError("helper failed: " + str(code))
            return events
        except BaseException as error:
            record["failure"] = type(error).__name__ + ": " + str(error)
            raise
        finally:
            if not reaped:
                self._stop(process)
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()
            record.setdefault("wall_seconds", time.perf_counter() - started)
            self.save()

    @staticmethod
    def _stop(process):
        # The helper and any descendants own this new process group only.
        for signum, grace in [(signal.SIGINT, 1), (signal.SIGTERM, 1), (signal.SIGKILL, 3)]:
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass
            until = time.monotonic() + grace
            while time.monotonic() < until:
                pid, status, _ = os.wait4(process.pid, os.WNOHANG)
                if pid:
                    process.returncode = os.waitstatus_to_exitcode(status)
                    return
                time.sleep(0.02)
        raise BenchmarkError("could not reap the helper after termination")


def file_hash(path, offset=0, length=None):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        source.seek(offset)
        remaining = length
        while remaining is None or remaining > 0:
            block = source.read(CHUNK_BYTES if remaining is None else min(CHUNK_BYTES, remaining))
            if not block:
                if remaining:
                    raise BenchmarkError("local fixture ended before the requested range")
                break
            digest.update(block)
            if remaining is not None:
                remaining -= len(block)
    return digest.hexdigest()


def make_fixture(path, size):
    digest = hashlib.sha256()
    with path.open("xb") as destination:
        remaining = size
        while remaining:
            block = os.urandom(min(CHUNK_BYTES, remaining))
            destination.write(block)
            digest.update(block)
            remaining -= len(block)
        destination.flush()
        os.fsync(destination.fileno())
    return digest.hexdigest()


def benchmark(binary, password, work, fixture_bytes=FIXTURE_BYTES, timeout=600, *, target=None):
    """fixture_bytes is internal test injection; the CLI always uses 256 MiB."""
    run_id = "benchmark-" + uuid.uuid4().hex
    target = load_nas_test_config() if target is None else validate_nas_test_config(target)
    root = ".mydrive-transport-tests/" + run_id
    work.mkdir(parents=True, exist_ok=False)
    report_path = work / "report.json"
    report = {
        "status": "running", "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "target": target, "remote_root": root, "binary": str(binary),
        "binary_sha256": file_hash(binary), "platform": platform.platform(),
        "fixture_bytes": fixture_bytes, "python_chunk_bytes": CHUNK_BYTES,
        "memory_method": "wait4 per native helper PID; ru_maxrss converted to bytes",
        "limits": ["Single sequential run; no comparative or fastest claim.",
                   "Server and macOS caches are uncontrolled; read follows upload and range follows full read.",
                   "Wall time includes process launch, connection, command, disconnect, and local fsync.",
                   "Helper operation_ms excludes connection but includes final disconnect; no isolated wire throughput.",
                   "RSS excludes Python, NAS, and kernel filesystem/network caches."],
        "operations": [], "checks": {}, "cleanup": "not started",
    }

    def save():
        temporary = report_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(report_path)

    helper = Helper(binary, password, root, report, save, timeout, target=target)
    source, full, ranged = (work / name for name in ("source.bin", "full.bin", "range.bin"))
    try:
        # A fresh UUID is also checked on the server before any mutation.
        helper.run("list", root, expect_error="not_found")
        report["checks"]["root_was_absent"] = True
        expected = make_fixture(source, fixture_bytes)
        report["fixture_sha256"] = expected
        helper.run("prepare")
        uploaded = helper.run("write", source, "payload.bin").complete["result"]["bytes"]
        if uploaded != fixture_bytes:
            raise BenchmarkError("upload byte count differs from fixture")
        remote = root + "/payload.bin"
        received = helper.run("read", remote, full).complete["result"]
        if received["bytes"] != fixture_bytes or received["entry"]["bytes"] != fixture_bytes:
            raise BenchmarkError("full read byte count differs from fixture")
        if full.stat().st_size != fixture_bytes or file_hash(full) != expected:
            raise BenchmarkError("full-file SHA-256 differs")
        report["checks"]["full_sha256_matches"] = True
        offset = fixture_bytes // 4 + 123
        length = min(8 * 1024 * 1024 + 17, fixture_bytes - offset)
        expected_range = file_hash(source, offset, length)
        received = helper.run("read", remote, ranged, "--offset", offset, "--length", length).complete["result"]
        if received["bytes"] != length or ranged.stat().st_size != length or file_hash(ranged) != expected_range:
            raise BenchmarkError("range bytes or SHA-256 differ")
        report["checks"].update(range_sha256_matches=True, range_offset=offset,
                                range_bytes=length, range_sha256=expected_range)
        listing = helper.run("list", root)
        if listing.names != ["payload.bin"] or listing.complete["result"].get("complete") is not True:
            raise BenchmarkError("run directory contains unexpected entries; retaining all evidence")
        report["cleanup"] = "removing verified run-owned file"
        helper.run("delete", "payload.bin")
        listing = helper.run("list", root)
        if listing.names or listing.complete["result"].get("complete") is not True:
            raise BenchmarkError("run directory is not empty; refusing directory cleanup")
        helper.run("cleanup")
        helper.run("list", root, expect_error="not_found")
        report["cleanup"] = "verified: own payload and empty run directory removed; parent retained"
        for path in (source, full, ranged):
            path.unlink()
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["failure"] = type(error).__name__ + ": " + str(error)
        report["retained_evidence"] = str(work)
        raise
    finally:
        report["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save()
        print("Benchmark report: " + str(report_path), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-test-share", action="store_true",
                        help="authorize this run only on the configured disposable NAS test share")
    parser.add_argument("--password-stdin", action="store_true", help="read raw password from a pipe, max 4096 bytes")
    parser.add_argument("--binary", type=Path, default=PROJECT / "Transport/target/release/nas-transport")
    args = parser.parse_args()
    if not args.confirm_test_share:
        parser.error("--confirm-test-share is required; no NAS operation has run")
    target = load_nas_test_config()
    binary = args.binary.resolve(strict=True)
    help_result = subprocess.run([str(binary), "--help"], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=5)
    if help_result.returncode or b"\n  cleanup\n" not in help_result.stdout:
        parser.error("rebuild the transport with empty-run-directory cleanup support first")
    if args.password_stdin:
        if sys.stdin.isatty():
            parser.error("--password-stdin requires a pipe")
        password = sys.stdin.buffer.read(4097)
    else:
        if not sys.stdin.isatty():
            parser.error("use a terminal prompt or explicit --password-stdin")
        password = getpass.getpass("Dedicated NAS test password: ").encode()
    if not password or len(password) > 4096:
        parser.error("password must contain 1–4096 UTF-8 bytes")
    work = PROJECT / "Transport/.work/benchmarks" / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    try:
        report = benchmark(binary, password, work, target=target)
        print("Verified upload/full/range reads; cleanup passed.")
        for operation in report["operations"]:
            if operation["command"] in ("write", "read"):
                print(f'{operation["command"]}: {operation["wall_seconds"]:.3f}s wall, {operation["peak_rss_bytes"] / 1048576:.2f} MiB helper peak RSS')
    except (BenchmarkError, OSError, ValueError, KeyboardInterrupt) as error:
        print("Benchmark failed; evidence retained. " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
