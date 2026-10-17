#!/usr/bin/env python3
"""Run development backend diagnostics inside the sandboxed MyDrive host.

This does not automate the app's UI. Finder verification uses Computer Use.
Passwords are prompted privately and passed only through a bounded stdin pipe.
"""
import argparse
import getpass
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import uuid
from nas_test_config import load_nas_test_config, validate_nas_test_config

PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["registration", "connection", "connection-reset", "credential", "session",
                                        "refresh", "pin", "offload", "offload-all", "remove"])
    parser.add_argument("identifier", nargs="?")
    parser.add_argument("--domain", default="unas-test", help="Existing dedicated-test connection's canonical Domain ID")
    args = parser.parse_args()
    if (args.mode in ("pin", "offload")) != (args.identifier is not None):
        parser.error("only pin/offload require exactly one catalog item identifier")
    if args.domain != "unas-test":
        try:
            if str(uuid.UUID(args.domain)) != args.domain:
                raise ValueError()
        except ValueError:
            parser.error("domain must be unas-test or a canonical lowercase UUID")
    binary = PROJECT / "dist/MyDrive.app/Contents/MacOS/MyDrive"
    target = load_nas_test_config()
    info = plistlib.loads((binary.parent.parent / "Info.plist").read_bytes())
    if (info.get("MyDriveDevelopmentBuild") is not True
            or validate_nas_test_config(info.get("MyDriveDevelopmentConnection")) != target):
        parser.error("the development bundle does not match the configured NAS test metadata; rebuild first")
    saved = PROJECT / ".runtime" / args.domain / "connection.json"
    if saved.exists():
        if saved.stat().st_size > 65_536:
            parser.error("the saved test connection is oversized")
        settings = json.loads(saved.read_text())
        if (settings.get("domainID") != args.domain
                or validate_nas_test_config({key: settings.get(key) for key in target}) != target):
            parser.error("the saved connection does not match the configured NAS test metadata")
    output = args.mode if args.mode in ("registration", "connection", "credential", "session") else "control"
    if args.mode == "connection-reset":
        output = "connection"
    report = PROJECT / ".runtime" / (output + "-result.json")
    report.unlink(missing_ok=True)
    password = None
    if args.mode in ("connection", "connection-reset", "session"):
        password = getpass.getpass("Dedicated NAS test password: ").encode()
        if not password or len(password) > 4096:
            parser.error("password must contain 1–4096 UTF-8 bytes")
    command = [str(binary), "--probe-" + args.mode]
    if args.identifier:
        command.append(args.identifier)
    command += ["--domain", args.domain]
    process = subprocess.Popen(command, stdin=subprocess.PIPE if password else subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    interrupted = False
    try:
        process.communicate(password, timeout=135)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        interrupted = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        print("Diagnostic waiting ended; the host was reaped. Provider work already accepted may still finish.",
              file=sys.stderr)
    finally:
        password = None
    if not report.exists() or report.stat().st_size > 16 * 1024:
        print("No bounded diagnostic report was produced; exit " + str(process.returncode), file=sys.stderr)
        return 1
    result = json.loads(report.read_text())
    print(json.dumps(result, indent=2))
    return 0 if (not interrupted and process.returncode == 0 and result.get("stage") == "complete"
                 and result.get("domainID") == args.domain) else 1


if __name__ == "__main__":
    sys.exit(main())
