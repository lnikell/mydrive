"""Bounded, nonsecret metadata for explicitly opted-in disposable NAS tests."""
import json
import os
from pathlib import Path
import stat

PROJECT = Path(__file__).resolve().parents[1]
MAX_BYTES = 4096
FIELDS = frozenset(("host", "share", "username"))


def validate_nas_test_config(value):
    """Return a copy; never accept credentials or silently normalize an endpoint."""
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise ValueError("NAS test metadata requires exactly host, share and username; no password field")
    for field in FIELDS:
        text = value[field]
        try:
            size = len(text.encode("utf-8")) if isinstance(text, str) else 0
        except UnicodeEncodeError as error:
            raise ValueError("NAS test metadata contains invalid Unicode") from error
        if (not isinstance(text, str) or not text.strip() or size > 1024
                or any(ord(character) < 32 or ord(character) == 127 for character in text)):
            raise ValueError("NAS test metadata fields must be nonblank bounded strings without control characters")
    return dict(value)


def _unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("NAS test metadata contains duplicate fields")
        result[key] = value
    return result


def load_nas_test_config(root=None):
    """Prefer ignored .local metadata, otherwise use the public example.

    An invalid/unreadable local file fails closed. Tests supply a temporary root
    or explicit metadata, so they never consume the developer's private target.
    """
    root = PROJECT if root is None else Path(root)
    local = root / ".local/nas-test.json"
    try:
        local.lstat()
        source = local
    except FileNotFoundError:
        source = root / "config/nas-test.example.json"
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("NAS test metadata must be a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            data = stream.read(MAX_BYTES + 1)
    finally:
        os.close(descriptor)
    if len(data) > MAX_BYTES:
        raise ValueError("NAS test metadata exceeds 4096 bytes")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_unique_fields)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("NAS test metadata is not valid UTF-8 JSON") from error
    return validate_nas_test_config(value)
