#!/usr/bin/env python3
"""Generate latest.json update manifest and SHA256SUMS.txt for GitHub Releases."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys


PUBSPEC_VERSION_RE = re.compile(
    r"^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\+([0-9]+)\s*$",
    re.MULTILINE,
)

PLATFORM_MATCHERS: list[tuple[str, re.Pattern[str], str]] = [
    ("windows-x64", re.compile(r"-windows-x64\.zip$"), "zip"),
    ("android-arm64-v8a", re.compile(r"-android-arm64-v8a\.apk$"), "apk"),
    ("android-armeabi-v7a", re.compile(r"-android-armeabi-v7a\.apk$"), "apk"),
    ("android-x86_64", re.compile(r"-android-x86_64\.apk$"), "apk"),
    ("linux-x64", re.compile(r"-linux-x64\.tar\.gz$"), "tar.gz"),
    ("macos-universal", re.compile(r"-macos-universal\.zip$"), "zip"),
]


def parse_pubspec_version(pubspec_path: pathlib.Path) -> tuple[str, int]:
    content = pubspec_path.read_text(encoding="utf-8")
    match = PUBSPEC_VERSION_RE.search(content)
    if not match:
        raise ValueError(
            f"Could not find `version: x.y.z+N` in {pubspec_path}"
        )
    return match.group(1), int(match.group(2))


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def detect_platform(file_name: str) -> tuple[str, str] | None:
    for platform_key, pattern, kind in PLATFORM_MATCHERS:
        if pattern.search(file_name):
            return platform_key, kind
    return None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate latest.json and SHA256SUMS.txt from release artifacts."
    )
    parser.add_argument("--repo", required=True, help="GitHub repository (owner/name)")
    parser.add_argument("--tag", required=True, help="Release tag (e.g. v1.0.1)")
    parser.add_argument(
        "--pubspec",
        type=pathlib.Path,
        default=pathlib.Path("pubspec.yaml"),
        help="Path to pubspec.yaml",
    )
    parser.add_argument(
        "--artifacts-dir",
        type=pathlib.Path,
        required=True,
        help="Directory containing packaged platform release files",
    )
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        required=True,
        help="Directory to write latest.json and SHA256SUMS.txt",
    )
    parser.add_argument(
        "--notes-file",
        type=pathlib.Path,
        default=None,
        help="Optional markdown file containing release notes",
    )
    args = parser.parse_args()

    version, build_number = parse_pubspec_version(args.pubspec)
    expected_tag = f"v{version}"
    if args.tag.startswith("v") and args.tag != expected_tag:
        print(
            f"::warning::Release tag ({args.tag}) does not match pubspec.yaml version ({expected_tag})",
            file=sys.stderr,
        )

    files = sorted(
        p for p in args.artifacts_dir.rglob("*") if p.is_file()
    )
    if not files:
        raise RuntimeError(f"No release artifacts found in {args.artifacts_dir}")

    platforms: dict[str, dict[str, object]] = {}
    checksum_lines: list[str] = []

    for artifact in files:
        file_name = artifact.name
        if file_name in {"latest.json", "SHA256SUMS.txt"}:
            continue
        digest = sha256_file(artifact)
        size = artifact.stat().st_size
        checksum_lines.append(f"{digest}  {file_name}")

        detected = detect_platform(file_name)
        if detected is None:
            continue
        platform_key, kind = detected
        platforms[platform_key] = {
            "fileName": file_name,
            "url": f"https://github.com/{args.repo}/releases/download/{args.tag}/{file_name}",
            "sha256": digest,
            "size": size,
            "kind": kind,
        }

    notes = ""
    if args.notes_file and args.notes_file.exists():
        notes = args.notes_file.read_text(encoding="utf-8").strip()

    manifest = {
        "schemaVersion": 1,
        "version": version,
        "buildNumber": build_number,
        "tag": args.tag,
        "publishedAt": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "releaseUrl": f"https://github.com/{args.repo}/releases/tag/{args.tag}",
        "notes": notes,
        "platforms": dict(sorted(platforms.items())),
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output_dir / "latest.json"
    checksums_path = args.output_dir / "SHA256SUMS.txt"

    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    checksums_path.write_text(
        "\n".join(checksum_lines) + "\n",
        encoding="utf-8",
    )

    print(f"Generated {manifest_path} with {len(platforms)} platform entries.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
