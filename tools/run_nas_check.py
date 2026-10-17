#!/usr/bin/env python3
"""Run an opted-in disposable NAS experiment without a password argument."""
import argparse
import getpass
import os
from pathlib import Path
import subprocess
import sys
import uuid
from nas_test_config import load_nas_test_config

def main():
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["probe", "list", "contract"])
    args = parser.parse_args()
    target = load_nas_test_config()
    secret = getpass.getpass("Dedicated NAS test password: ").encode()
    if not 1 <= len(secret) <= 4096:
        parser.error("password must contain 1–4096 UTF-8 bytes")
    common = [part for key, value in target.items() for part in ("--" + key, value)]
    common.append("--password-stdin")
    env = os.environ.copy()
    if args.mode == "contract":
        env.update(CARGO_HOME=str(project / "Transport/.cargo-home"), NAS_TEST_ENABLE="1",
                   NAS_TEST_HOST=target["host"], NAS_TEST_SHARE=target["share"],
                   NAS_TEST_USER=target["username"],
                   NAS_TEST_ROOT=".mydrive-transport-tests/run-" + uuid.uuid4().hex[:12])
        command = ["cargo", "test", "--locked", "--test", "nas_contract", "--",
                   "--ignored", "--test-threads=1", "--nocapture"]
        cwd = project / "Transport"
    else:
        command = [str(project / "Transport/target/release/nas-transport"), *common, args.mode]
        cwd = project
    try:
        return subprocess.run(command, input=secret + b"\n", cwd=cwd, env=env, timeout=180).returncode
    except subprocess.TimeoutExpired:
        print("Experiment exceeded its deadline; inspect retained fixtures before retrying.", file=sys.stderr)
        return 124


if __name__ == "__main__":
    sys.exit(main())
