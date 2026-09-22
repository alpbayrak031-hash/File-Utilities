#!/usr/bin/env python3
"""Copies ffmpeg and every non-system library it needs into an .app bundle.

Usage: bundle_ffmpeg.py <path/to/ffmpeg> <path/to/App.app> [name-inside-bundle]

Layout:  Contents/MacOS/ffmpeg  +  Contents/Frameworks/*.dylib
All references are rewritten to @rpath/<name>, so the bundle works on Macs without Homebrew.
"""
import os
import re
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def deps(path):
    lines = run("otool", "-L", path).splitlines()[1:]
    return [l.strip().split(" (")[0] for l in lines if l.strip()]


def rpaths(path):
    out = run("otool", "-l", path)
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", out)


def is_system(ref):
    return ref.startswith("/usr/lib/") or ref.startswith("/System/")


def resolve(ref, owner):
    loader = os.path.dirname(os.path.realpath(owner))
    if ref.startswith("@loader_path/") or ref.startswith("@executable_path/"):
        return os.path.realpath(os.path.join(loader, ref.split("/", 1)[1]))
    if ref.startswith("@rpath/"):
        name = ref[len("@rpath/"):]
        for rp in rpaths(owner):
            rp = rp.replace("@loader_path", loader).replace("@executable_path", loader)
            candidate = os.path.join(rp, name)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        # Homebrew fallback
        for base in ("/opt/homebrew/lib", "/usr/local/lib"):
            candidate = os.path.join(base, name)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise SystemExit(f"Can't resolve {ref} (needed by {owner})")
    return os.path.realpath(ref)


def main():
    ffmpeg, app = os.path.realpath(sys.argv[1]), sys.argv[2]
    # A statically linked build (no non-system dependencies) just gets copied in under its own name.
    name = sys.argv[3] if len(sys.argv) > 3 else "ffmpeg"
    macos = os.path.join(app, "Contents", "MacOS")
    frameworks = os.path.join(app, "Contents", "Frameworks")
    os.makedirs(frameworks, exist_ok=True)

    exe = os.path.join(macos, name)
    shutil.copy2(ffmpeg, exe)
    os.chmod(exe, 0o755)

    # Walk the dependency graph starting from the original files (so @loader_path/@rpath resolve).
    copied = {}  # real source path -> bundled name
    queue = [(ffmpeg, exe)]
    edits = {}   # bundled file -> [(old ref, new ref)]
    while queue:
        source, bundled = queue.pop()
        changes = []
        for ref in deps(source):
            if is_system(ref):
                continue
            real = resolve(ref, source)
            if real == os.path.realpath(source):
                continue  # the library's own id
            lib_name = os.path.basename(ref)
            if real not in copied:
                copied[real] = lib_name
                dest = os.path.join(frameworks, lib_name)
                shutil.copy2(real, dest)
                os.chmod(dest, 0o755)
                queue.append((real, dest))
            changes.append((ref, "@rpath/" + copied[real]))
        edits[bundled] = changes

    for bundled, changes in edits.items():
        args = ["install_name_tool"]
        for old, new in changes:
            args += ["-change", old, new]
        if bundled != exe:
            args += ["-id", "@rpath/" + os.path.basename(bundled)]
        args.append(bundled)
        subprocess.run(args, check=True, capture_output=True)
        for rp in rpaths(bundled):
            subprocess.run(["install_name_tool", "-delete_rpath", rp, bundled], capture_output=True)
        rpath = "@executable_path/../Frameworks" if bundled == exe else "@loader_path"
        subprocess.run(["install_name_tool", "-add_rpath", rpath, bundled], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", bundled], check=True, capture_output=True)

    # Sanity check: nothing may still point at Homebrew.
    for bundled in edits:
        bad = [d for d in deps(bundled) if d.startswith("/opt/") or d.startswith("/usr/local/")]
        if bad:
            raise SystemExit(f"{bundled} still references {bad}")
    size = os.path.getsize(exe) + sum(os.path.getsize(os.path.join(frameworks, copied[k])) for k in copied)
    libs = f" + {len(copied)} libraries" if copied else " (static)"
    print(f"  bundled {name}{libs} ({size / 1_048_576:.0f} MB, {arch_of(exe)})")


def arch_of(path):
    out = run("file", path)
    return " ".join(a for a in ("arm64", "x86_64") if a in out) or "?"


if __name__ == "__main__":
    main()
