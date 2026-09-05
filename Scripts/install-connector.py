#!/usr/bin/env python3
"""Stage, verify and install LLM Usage's connector on an existing SSH host."""
import argparse
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="Existing SSH alias or user@hostname")
    parser.add_argument("--hermes-root", help="Opt in to the offline Hermes runtime check using this absolute checkout path on the SSH host")
    parser.add_argument("--hermes-python", default="python3", help="Python executable on the SSH host with Hermes dependencies (used with --hermes-root)")
    parser.add_argument("--hermes-cli", help="Hermes CLI executable on the SSH host (optional, used with --hermes-root)")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@._-]{0,199}", args.host):
        parser.error("host must be an SSH alias or user@hostname")
    if args.hermes_root and not args.hermes_root.startswith("/"):
        parser.error("--hermes-root must be an absolute path on the SSH host")
    if args.hermes_cli and not args.hermes_root:
        parser.error("--hermes-cli requires --hermes-root")

    root = Path(__file__).resolve().parents[1]
    ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", args.host]
    stage = "/tmp/quotabar-install-" + uuid.uuid4().hex
    files = ["Sources/OpenAIQuotaBar/Resources/quotabar_peer.py", "Scripts/pool-integration-check.py", "Scripts/hermes-pool-check.py"]
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w:gz") as tar:
        for name in files:
            tar.add(root / name, arcname=name)
    subprocess.run(ssh + ["umask 077; mkdir -p " + shlex.quote(stage) + "; tar -xz -C " + shlex.quote(stage)], input=archive.getvalue(), check=True, timeout=30)
    try:
        subprocess.run(ssh + ["python3 " + shlex.quote(stage + "/Scripts/pool-integration-check.py")], check=True, timeout=90)
        if args.hermes_root:
            check = [args.hermes_python, stage + "/Scripts/hermes-pool-check.py", "--hermes-root", args.hermes_root]
            if args.hermes_cli:
                check.extend(["--hermes-cli", args.hermes_cli])
            subprocess.run(ssh + [shlex.join(check)], check=True, timeout=60)
        subprocess.run(ssh + ["python3 " + shlex.quote(stage + "/Sources/OpenAIQuotaBar/Resources/quotabar_peer.py") + " install"], check=True, timeout=40)
        subprocess.run(ssh + ["python3 ~/.local/share/quotabar/quotabar-peer.py status"], check=True, timeout=15)
        print(json.dumps({"host": args.host, "installation": "verified", "scope": "SSH user only", "existingSessionsRestarted": False}))
    finally:
        # This exact UUID directory was created above solely for this installation.
        cleanup = "import shutil; shutil.rmtree(" + repr(stage) + ", ignore_errors=True)"
        subprocess.run(ssh + ["python3 -c " + shlex.quote(cleanup)], timeout=15, check=False)


if __name__ == "__main__":
    main()
