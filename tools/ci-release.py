#!/usr/bin/env python3
"""Import release secrets only on an ephemeral GitHub-hosted macOS runner."""
import base64
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

from release_support import ROOT, ReleaseError, release_config, run, version_info
from ci_artifacts import recover, outputs


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("prepare", "publish"):
        raise ReleaseError("Use ci-release.py prepare or publish.")
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise ReleaseError("CI secret import is restricted to ephemeral GitHub-hosted runners. Use release.py locally.")
    config, version = release_config(), version_info()
    if os.environ.get("GITHUB_REPOSITORY", "").lower() != (config.get("repository") or "").lower():
        raise ReleaseError("The workflow repository differs from release/config.json.")
    if os.environ.get("GITHUB_REF") != "refs/tags/v" + version["version"]:
        raise ReleaseError("The release workflow must run on the exact version tag.")
    required = ("MYDRIVE_CERTIFICATE_P12_BASE64", "MYDRIVE_CERTIFICATE_PASSWORD", "MYDRIVE_SIGN_IDENTITY",
                "MYDRIVE_HOST_PROFILE_BASE64", "MYDRIVE_PROVIDER_PROFILE_BASE64", "MYDRIVE_SPARKLE_PRIVATE_KEY",
                "MYDRIVE_NOTARY_KEY_BASE64", "MYDRIVE_NOTARY_KEY_ID", "MYDRIVE_NOTARY_ISSUER_ID")
    missing = [x for x in required if not os.environ.get(x)]
    if missing:
        raise ReleaseError("Configure release secrets: " + ", ".join(missing))
    # The runner VM is disposable; still restore its exact search list and remove
    # our Keychain/files on both successful and failed release commands.
    search_list = shlex.split(run(["security", "list-keychains", "-d", "user"], capture=True))
    with tempfile.TemporaryDirectory(prefix="mydrive-signing-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
        folder = Path(temporary)
        keychain = folder / "release.keychain-db"
        password = secrets.token_urlsafe(32)
        def private_file(name, value, decode=True):
            path = folder / name
            data = base64.b64decode(value, validate=True) if decode else value.encode()
            with path.open("xb") as output:
                os.chmod(path, 0o600)
                output.write(data)
            return path
        try:
            certificate = private_file("certificate.p12", os.environ["MYDRIVE_CERTIFICATE_P12_BASE64"])
            host = private_file("host.provisionprofile", os.environ["MYDRIVE_HOST_PROFILE_BASE64"])
            provider = private_file("provider.provisionprofile", os.environ["MYDRIVE_PROVIDER_PROFILE_BASE64"])
            update_key = private_file("update-key", os.environ["MYDRIVE_SPARKLE_PRIVATE_KEY"], decode=False)
            notary_key = private_file("notary.p8", os.environ["MYDRIVE_NOTARY_KEY_BASE64"])
            # Security.framework's CLI accepts import/unlock passwords via -P/-p.
            # Never echo commands or captured output from these operations.
            run(["security", "create-keychain", "-p", password, keychain], capture=True)
            run(["security", "set-keychain-settings", "-lut", "21600", keychain], capture=True)
            run(["security", "unlock-keychain", "-p", password, keychain], capture=True)
            run(["security", "import", certificate, "-k", keychain, "-P", os.environ["MYDRIVE_CERTIFICATE_PASSWORD"],
                 "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], capture=True)
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain], capture=True)
            run(["security", "list-keychains", "-d", "user", "-s", keychain, *search_list], capture=True)
            environment = dict(os.environ, MYDRIVE_HOST_PROFILE=str(host), MYDRIVE_PROVIDER_PROFILE=str(provider),
                               MYDRIVE_SPARKLE_KEY_FILE=str(update_key), MYDRIVE_NOTARY_KEY_PATH=str(notary_key))
            # Remove imported raw secret values from the build/test environment.
            for name in required:
                if name not in ("MYDRIVE_SIGN_IDENTITY", "MYDRIVE_NOTARY_KEY_ID", "MYDRIVE_NOTARY_ISSUER_ID"):
                    environment.pop(name, None)
            if sys.argv[1] == "prepare":
                reused, name, prepared = recover(config, version)
                run([sys.executable, ROOT / "tools/release.py", "verify" if reused else "prepare"],
                    env=environment, timeout=5400)
                outputs(reused, name, prepared)
            else:
                run([sys.executable, ROOT / "tools/release.py", "publish"], env=environment, timeout=1800)
        finally:
            subprocess.run(["security", "list-keychains", "-d", "user", "-s", *search_list], capture_output=True)
            if keychain.exists():
                subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True)


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"CI release stopped: {error}", file=sys.stderr)
        sys.exit(1)
