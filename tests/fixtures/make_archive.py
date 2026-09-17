#!/usr/bin/env python3
"""Builds a .tar.gz with precisely controlled entries for archive-safety
tests (path traversal, absolute paths, symlinks) that would be awkward or
non-portable to construct with the system `tar` binary across macOS/Linux.

Usage: make_archive.py <output.tar.gz> <spec> [<spec> ...]
Each <spec> is "type:name[:linkname]", type one of: file, dir, symlink.
A "file" entry gets trivial fixed content.
"""
import sys
import tarfile
import io

out_path = sys.argv[1]
specs = sys.argv[2:]

with tarfile.open(out_path, "w:gz") as tar:
    for spec in specs:
        parts = spec.split(":", 2)
        kind = parts[0]
        name = parts[1]
        if kind == "file":
            data = b"placeholder content\n"
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            info.type = tarfile.REGTYPE
            tar.addfile(info, io.BytesIO(data))
        elif kind == "dir":
            info = tarfile.TarInfo(name=name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tar.addfile(info)
        elif kind == "symlink":
            linkname = parts[2] if len(parts) > 2 else "/etc/passwd"
            info = tarfile.TarInfo(name=name)
            info.type = tarfile.SYMTYPE
            info.linkname = linkname
            tar.addfile(info)
        else:
            raise SystemExit(f"unknown entry kind: {kind}")
