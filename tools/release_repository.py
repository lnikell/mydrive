"""Read-only validation of the effective local publication destination."""
import re
from urllib.parse import urlsplit

from release_support import ROOT, ReleaseError, run


def _github_repository(url):
    if any(character.isspace() for character in url):
        return None
    scp = re.fullmatch(r"git@(?i:github\.com):([^?#]+)", url)
    if scp:
        path = scp[1]
    else:
        try:
            value = urlsplit(url)
            if value.hostname is None or value.hostname.lower() != "github.com" or value.query or value.fragment:
                return None
            if value.scheme == "https":
                if value.username is not None or value.password is not None or value.port not in (None, 443):
                    return None
            elif value.scheme == "ssh":
                if value.username != "git" or value.password is not None or value.port not in (None, 22):
                    return None
            else:
                return None
            path = value.path.removeprefix("/")
        except ValueError:
            return None
    path = path.removesuffix("/").removesuffix(".git")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", path) or path.split("/")[-1] in (".", ".."):
        return None
    return path.casefold()


def validate_origin(config, root=ROOT):
    repository = config.get("repository")
    if not isinstance(repository, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repository) \
            or repository.split("/")[-1] in (".", ".."):
        raise ReleaseError("Configure the intended GitHub repository before validating origin.")
    try:
        output = run(["git", "remote", "get-url", "--push", "--all", "origin"], cwd=root, capture=True)
    except ReleaseError:
        raise ReleaseError("Configure origin's push URL for the repository in release/config.json.") from None
    urls = output.splitlines()
    if not urls or any(_github_repository(url) != repository.casefold() for url in urls):
        # Never echo a rejected remote URL: it may contain credentials.
        raise ReleaseError("Every effective origin push URL must target the configured github.com repository without embedded credentials.")
