#!/usr/bin/python3
"""No-network test helper. Echo only synthetic test requests, never real secrets."""
import json
import signal
import sys


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def validate_scope(value, path):
    assert set(value) == {"root_path", "root", "parent"}
    assert type(value["root_path"]) is str
    assert path == value["root_path"] or path.startswith(value["root_path"] + "/")
    for key in ("root", "parent"):
        assert set(value[key]) == {"index_number", "created_filetime"}
        assert all(type(number) is int and number > 0 for number in value[key].values())


def validate_tree_scope(value, path):
    assert set(value) == {"layout_version", "arena_path", "arena", "parent"}
    assert type(value["layout_version"]) is int and value["layout_version"] == 2
    assert type(value["arena_path"]) is str
    assert path == value["arena_path"] or path.startswith(value["arena_path"] + "/")
    for key in ("arena", "parent"):
        assert set(value[key]) == {"index_number", "created_filetime"}
        assert all(type(number) is int and number > 0 for number in value[key].values())


def entry(name, size):
    return dict(name=name, bytes=size, directory=False, index_number=1, created_filetime=1, modified_filetime=0,
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


def mutation_case(operation):
    request = operation["request"]
    assert set(request) <= {"operation_id", "kind", "path", "parent", "destination", "destination_parent", "expected", "payload", "receipt", "delete_scope", "tree_scope"}
    assert {"operation_id", "kind", "path", "parent", "receipt"} <= set(request)
    assert request["parent"] == {"index_number": 11, "created_filetime": 22}
    if request["kind"] == "move":
        assert request["destination_parent"] == {"index_number": 33, "created_filetime": 44}
    else:
        assert "destination_parent" not in request
    if "delete_scope" in request:
        assert request["kind"] in {"delete", "cleanup"}
        validate_scope(request["delete_scope"], request["path"])
    if "tree_scope" in request:
        assert "delete_scope" not in request
        validate_tree_scope(request["tree_scope"], request["path"])
    mode = request["path"].rsplit("/", 1)[-1]
    payload = request.get("payload")
    size = payload["bytes"] if payload else request.get("expected", {}).get("bytes", 0)
    receipt = request["receipt"]
    allocated_case = mode.startswith("allocated")
    allocated_phase = receipt.get("staged", {}).get("phase")
    if operation["type"] == "mutate" and payload and (not allocated_case or allocated_phase == "allocated"):
        for value in {"negative": [-1], "regressing": [2, 1], "excessive": [size + 1]}.get(mode, [size]):
            emit({"type": "progress", "bytes": value})
    final = entry(request.get("destination", request["path"]).rsplit("/", 1)[-1], size)
    result = dict(operation_id=request["operation_id"], outcome="committed", code="committed",
                  entry=final, sha256=payload["sha256"] if payload else None, cleanup_pending=False)
    if allocated_case and allocated_phase != "prepared":
        stage_path = request["path"].rsplit("/", 1)[0] + "/.mydrive-" + request["operation_id"] + ".stage"
        stage = dict(path=stage_path, entry=entry(stage_path.rsplit("/", 1)[-1], size if allocated_phase else 0),
                     phase="prepared" if allocated_phase else "allocated", security_sha256="b" * 64, cleanup_safe=True)
        if mode == "allocated-missing-security":
            stage.pop("security_sha256")
        if mode == "allocated-bad-phase":
            stage["phase"] = "unknown"
        if mode == "allocated-directory":
            stage["entry"]["directory"] = True
        if mode == "allocated-nonempty":
            stage["entry"]["bytes"] = 1
        if mode == "allocated-unsafe":
            stage["cleanup_safe"] = False
        result.update(outcome="not_applied", code="prepared" if allocated_phase else "allocated", entry=None,
                      sha256=None, cleanup_pending=True, staged=stage)
    elif mode == "allocation-unknown-archive":
        path = request["path"].rsplit("/", 1)[0] + "/.mydrive-" + request["operation_id"] + ".backup"
        result.update(outcome="uncertain", code="allocation_unknown", entry=None, sha256=None, cleanup_pending=True,
                      archived={"path": path, "entry": entry(path.rsplit("/", 1)[-1], 3), "cleanup_safe": False})
    elif mode == "wrong-id":
        result["operation_id"] = "11111111-1111-4111-8111-111111111111"
    elif mode == "wrong-hash":
        result["sha256"] = "0" * 64
    elif mode == "wrong-name":
        final["name"] = "other"
    elif mode == "wrong-size":
        final["bytes"] += 1
    elif mode == "bad-outcome":
        result["outcome"] = "maybe"
    elif mode == "missing-cleanup":
        result.pop("cleanup_pending")
    elif mode in {"prepared", "wrong-artifact"} and not receipt:
        parent = request["path"].rsplit("/", 1)[0]
        staged_path = parent + "/.mydrive-" + request["operation_id"] + ".stage"
        if mode == "wrong-artifact":
            staged_path = "unrelated-user-file"
        staged = dict(path=staged_path, entry=entry(staged_path.rsplit("/", 1)[-1], size))
        # Omit cleanup_safe intentionally: the adapter must default it to false.
        result.update(outcome="not_applied", code="prepared", entry=None, sha256=None,
                      cleanup_pending=True, staged=staged)
    emit({"type": "complete", "result": result})


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
                "read": {"type", "path", "destination"}, "stat": {"type", "path"},
                "mutate": {"type", "request"}, "reconcile": {"type", "request"}}[kind]
    if "delete_scope" in operation:
        assert kind in {"stat", "list"}
        expected |= {"delete_scope"}
        validate_scope(operation["delete_scope"], operation["path"])
    if "tree_scope" in operation:
        assert kind in {"stat", "list", "read"} and "delete_scope" not in operation
        expected |= {"tree_scope"}
        validate_tree_scope(operation["tree_scope"], operation["path"])
    assert set(operation) == expected
    assert all(type(operation[key]) is str for key in expected if key not in {"request", "delete_scope", "tree_scope"})
    emit({"type": "connected"})
    if operation.get("path") == "__unsupported__":
        emit({"type": "error", "code": "unsupported", "message": "Synthetic unsupported file feature."})
        return
    if operation.get("path", "").endswith("/scope-changed"):
        emit({"type": "error", "code": "scope_changed", "message": "Synthetic scope changed."})
        return
    if operation.get("path", "").endswith("/tree-scope-changed"):
        emit({"type": "error", "code": "tree_scope_changed", "message": "Synthetic private tree scope changed."})
        return
    if kind in {"mutate", "reconcile"}:
        mutation_case(operation)
    elif kind == "stat":
        mode = operation["path"].rsplit("/", 1)[-1]
        result = {} if mode == "missing-field" else {"entry": None if mode == "missing" else entry(mode, 3)}
        if operation["path"] == "":
            result["entry"].update(directory=True, attributes=0x10)
        emit({"type": "complete", "result": result})
    elif kind == "list":
        if operation["path"] == "__progress__/wrong-command":
            emit({"type": "progress", "bytes": 1})
            return
        # Wire bytes prove that JSON decoding did not merely compare Unicode
        # canonically. This helper is used exclusively with synthetic inputs.
        emit({"type": "page", "entries": [entry(data.hex(), 0)]})
        directory = entry(operation["path"].rsplit("/", 1)[-1], 0)
        directory.update(directory=True, attributes=0x10)
        result = {"complete": True, "entry": directory}
        if operation["path"] == "__listing__/missing":
            result.pop("entry")
        elif operation["path"] == "__listing__/file":
            directory["directory"] = False
        elif operation["path"] == "__listing__/zero":
            directory["index_number"] = 0
        elif operation["path"] == "__listing__/reparse":
            directory["attributes"] |= 0x400
        emit({"type": "complete", "result": result})
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
