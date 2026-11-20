#!/usr/bin/env python3
"""Create and serve a deterministic local BitTorrent test torrent for Android CI.

The Android emulator connects directly to this seeder through its host alias
(10.0.2.2). No public tracker, DHT lookup, public swarm, or copyrighted media
is needed to verify metadata exchange and piece delivery.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import time
from pathlib import Path

try:
    import libtorrent as lt
except ImportError as exc:  # pragma: no cover - exercised on GitHub runner
    raise SystemExit(
        "python3-libtorrent is required; install the Ubuntu package "
        "python3-libtorrent and run with /usr/bin/python3"
    ) from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--seed-dir", required=True, type=Path)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--port", type=int, default=6881)
    args = parser.parse_args()

    video = args.video.resolve()
    seed_dir = args.seed_dir.resolve()
    state_file = args.state_file.resolve()
    if not video.is_file():
        raise SystemExit(f"Seed video does not exist: {video}")
    size = video.stat().st_size
    if size < 8 * 1024 * 1024:
        raise SystemExit(f"Seed video must exceed 8 MiB; got {size} bytes.")
    if not 1 <= args.port <= 65535:
        raise SystemExit("Invalid peer port.")

    seed_dir.mkdir(parents=True, exist_ok=True)
    # Keep the video in the exact directory used as the torrent save path.
    target = seed_dir / video.name
    if video != target:
        target.write_bytes(video.read_bytes())

    # Use a basename relative to the save directory. Absolute paths would
    # become nested torrent paths and make the seeder's on-disk layout diverge.
    previous_cwd = Path.cwd()
    os.chdir(seed_dir)
    storage = lt.file_storage()
    lt.add_files(storage, target.name)
    builder = lt.create_torrent(storage, 256 * 1024)
    builder.set_creator("MovieBox Nexus deterministic CI test")
    lt.set_piece_hashes(builder, str(seed_dir))
    torrent_bytes = lt.bencode(builder.generate())
    os.chdir(previous_cwd)
    torrent_path = seed_dir / "moviebox-ci-seed.torrent"
    torrent_path.write_bytes(torrent_bytes)
    info = lt.torrent_info(lt.bdecode(torrent_bytes))
    info_hash = str(info.info_hash()).lower()

    # Bind on all interfaces: the Android emulator reaches this host through
    # 10.0.2.2. DHT and trackers are intentionally disabled for determinism.
    session = lt.session({
        "listen_interfaces": f"0.0.0.0:{args.port}",
        "enable_dht": False,
        "enable_lsd": False,
        "enable_upnp": False,
        "enable_natpmp": False,
        "announce_to_all_trackers": False,
        "announce_to_all_tiers": False,
    })
    params = lt.add_torrent_params()
    params.ti = info
    params.save_path = str(seed_dir)
    params.flags = lt.torrent_flags.seed_mode
    handle = session.add_torrent(params)

    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        status = handle.status()
        if bool(getattr(status, "is_seeding", False)):
            break
        time.sleep(0.25)
    else:
        raise SystemExit("Local libtorrent seed did not reach seeding state within 90 seconds.")

    video_bytes = target.read_bytes()
    seek_offset = 4 * 1024 * 1024
    state = {
        "info_hash": info_hash,
        "peer_endpoint": f"127.0.0.1:{args.port}",
        "size_bytes": len(video_bytes),
        "first_hex": video_bytes[:16].hex(),
        "seek_offset": seek_offset,
        "seek_hex": video_bytes[seek_offset:seek_offset + 16].hex(),
        "torrent_file": str(torrent_path),
    }
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(state), encoding="utf-8")
    print("MOVIEBOX_LOCAL_SEED_READY " + json.dumps(state), flush=True)

    stopping = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not stopping:
        time.sleep(1)
    session.pause()
    session = None
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
