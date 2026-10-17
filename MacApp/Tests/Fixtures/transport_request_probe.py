#!/usr/bin/python3
"""No-network test helper. Echo only synthetic test requests, never real secrets."""
import json
import signal
import sys


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def entry(name, size):
    return dict(name=name, bytes=size, directory=False, modified_filetime=0,
                changed_filetime=0, attributes=0)


def progress_case(operation):
    """Synthetic wire cases; sparse files keep large-count checks disk-bounded."""
    mode = operation["path"].removeprefix("__progress__/")
    total = (1 << 32) + 20 if mode == "large" else 0 if mode == "empty" else 20
    samples = {"small": [1, 1, 10], "large": [1, 1 << 32], "empty": [],
               "decreasing": [10, 9], "negative": [-1], "terminal-decreasing": [21],
               "integer-overflow": [1 << 63], "cancel": [1]}[mode]
    with open(operation["destination"], "xb") as output:
        output.truncate(total)
    for count in samples:
        emit({"type": "progress", "bytes": count})
    if mode == "cancel":
        signal.pause()  # The real HelperOperation must interrupt/reap this child.
        return
    emit({"type": "complete", "result": {
        "bytes": total, "entry": entry(mode, total)}})


def main():
    assert sys.argv[1:] == ["--request-stdin"]
    data = sys.stdin.buffer.read(65537)
    assert len(data) <= 65536
    request = json.loads(data)
    assert set(request) == {"version", "host", "share", "username", "password", "operation"}
    assert type(request["version"]) is int and request["version"] == 1
    assert all(type(request[key]) is str for key in ("host", "share", "username", "password"))
    assert 1 <= len(request["password"].encode("utf-8")) <= 4096
    operation = request["operation"]
    kind = operation["type"]
    expected = {"probe": {"type"}, "list": {"type", "path"},
                "read": {"type", "path", "destination"}}[kind]
    assert set(operation) == expected
    assert all(type(operation[key]) is str for key in expected)
    emit({"type": "connected"})
    if kind == "list":
        if operation["path"] == "__progress__/wrong-command":
            emit({"type": "progress", "bytes": 1})
            return
        # Wire bytes prove that JSON decoding did not merely compare Unicode
        # canonically. This helper is used exclusively with synthetic inputs.
        emit({"type": "page", "entries": [entry(data.hex(), 0)]})
        emit({"type": "complete", "result": {"complete": True}})
    elif kind == "read":
        if operation["path"].startswith("__progress__/"):
            progress_case(operation)
            return
        payload = operation["path"].encode("utf-8")
        with open(operation["destination"], "xb") as output:
            output.write(payload)
        emit({"type": "complete", "result": {
            "bytes": len(payload), "entry": entry(operation["path"].rsplit("/", 1)[-1], len(payload))}})
    else:
        emit({"type": "complete", "result": {}})


if __name__ == "__main__":
    try:
        main()
    except Exception:
        emit({"type": "error", "code": "invalid_input", "message": "Invalid synthetic test request."})
        sys.exit(2)
