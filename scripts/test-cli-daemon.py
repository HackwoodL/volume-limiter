#!/usr/bin/env python3

import os
import socket
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    socket_path = Path(f"/tmp/volume-limiter-{os.getuid()}.sock")
    config_path = Path.home() / "Library" / "Application Support" / "VolumeLimiter" / "config.json"
    backup_data = config_path.read_bytes() if config_path.exists() else None

    subprocess.run(["swift", "build"], cwd=repo, check=True)

    if socket_path.exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(socket_path))
        except OSError:
            socket_path.unlink(missing_ok=True)
        else:
            probe.close()
            print(f"daemon already appears to be running at {socket_path}; refusing to interfere", file=sys.stderr)
            return 2

    daemon = repo / ".build" / "debug" / "volume-limiterd"
    cli = repo / ".build" / "debug" / "volume-limit"
    proc = subprocess.Popen(
        [str(daemon)],
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    try:
        wait_for_socket(socket_path, proc)
        run_cli(cli, ["status"])
        run_cli(cli, ["set", "100"])
        run_cli(cli, ["get"])
        run_cli(cli, ["off"])
        run_cli(cli, ["on"])
        run_cli(cli, ["bluetooth-only", "status"])

        second = subprocess.run(
            [str(daemon)],
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
        )
        print("$ volume-limiterd # duplicate")
        print(second.stdout, end="")
        if second.returncode == 0:
            raise RuntimeError("duplicate daemon unexpectedly started successfully")
    finally:
        stop_process(proc)
        socket_path.unlink(missing_ok=True)
        restore_config(config_path, backup_data)

    unavailable = subprocess.run(
        [str(cli), "status"],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    print("$ volume-limit status # daemon stopped")
    print(unavailable.stdout, end="")
    print(unavailable.stderr, end="", file=sys.stderr)
    if unavailable.returncode != 69:
        raise RuntimeError(f"expected daemon unavailable exit 69, got {unavailable.returncode}")

    return 0


def wait_for_socket(socket_path: Path, proc: subprocess.Popen[str]) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if socket_path.exists():
            return
        if proc.poll() is not None:
            output = proc.stdout.read() if proc.stdout else ""
            raise RuntimeError(f"daemon exited early with {proc.returncode}:\n{output}")
        time.sleep(0.1)
    raise RuntimeError(f"daemon did not create socket {socket_path}")


def run_cli(binary: Path, args: list[str], display_name: str = "volume-limit") -> None:
    completed = subprocess.run(
        [str(binary), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    print(f"$ {display_name} {' '.join(args)}")
    print(completed.stdout, end="")
    print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise RuntimeError(f"{display_name} {' '.join(args)} exited {completed.returncode}")


def stop_process(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def restore_config(config_path: Path, backup_data: bytes | None) -> None:
    if backup_data is None:
        config_path.unlink(missing_ok=True)
        return
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_bytes(backup_data)


if __name__ == "__main__":
    raise SystemExit(main())
