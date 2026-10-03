#!/usr/bin/env python3
"""Read-only audit of a complete macOS game bundle; never executes game code."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

MAGICS = {bytes.fromhex(x) for x in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
DESKTOP = re.compile(r"/(AppKit|Cocoa|Carbon|OpenGL|OpenAL|ForceFeedback|"
                     r"SecurityFoundation|Quartz|CoreServices)\.framework/")


def tool(*args):
    result = subprocess.run(["xcrun", *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def command_blocks(output):
    return re.split(r"Load command \d+\n", output)[1:]


def inspect(path, root, sdk, details):
    relative = str(path.relative_to(root))
    record = {"path": relative, "sha256": digest(path), "size_bytes": path.stat().st_size}
    record["architectures"] = tool("lipo", "-archs", path).strip().split()
    if "arm64" not in record["architectures"]:
        record["blockers"] = ["No ordinary arm64 slice; emu's direct ARM64 route cannot load this binary."]
        return record
    commands = tool("otool", "-arch", "arm64", "-l", path)
    header = tool("otool", "-arch", "arm64", "-hv", path)
    kind = next((x for x in ("EXECUTE", "DYLIB", "BUNDLE") if re.search(r"\b" + x + r"\b", header)), "UNKNOWN")
    deps = []
    rpaths = []
    platforms = []
    encryption = []
    entry_offsets = []
    for block in command_blocks(commands):
        cmd = re.search(r"\bcmd (\S+)", block)
        if not cmd:
            continue
        cmd = cmd.group(1)
        if cmd in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB"}:
            match = re.search(r"\bname (.*?) \(offset \d+\)", block)
            if match:
                name = match.group(1)
                framework = re.search(r"/([^/]+)\.framework/", name)
                deps.append({"path": name, "load_command": cmd,
                             "desktop_framework": bool(DESKTOP.search(name)),
                             "framework_in_iphone_sdk": (sdk / "System/Library/Frameworks" / (framework.group(1) + ".framework")).is_dir() if framework else None,
                             "versioned_macos_path": "/Versions/" in name})
        elif cmd == "LC_RPATH":
            match = re.search(r"\bpath (.*?) \(offset \d+\)", block)
            if match:
                rpaths.append(match.group(1))
        elif cmd == "LC_BUILD_VERSION":
            match = re.search(r"\bplatform\s+(\S+)", block)
            if match:
                platforms.append(match.group(1))
        elif cmd.startswith("LC_VERSION_MIN_"):
            platforms.append(cmd)
        elif cmd.startswith("LC_ENCRYPTION_INFO"):
            match = re.search(r"\bcryptid\s+(\d+)", block)
            if match:
                encryption.append(int(match.group(1)))
        elif cmd == "LC_MAIN":
            match = re.search(r"\bentryoff\s+(\d+)", block)
            if match:
                entry_offsets.append(int(match.group(1)))
    record.update(file_type=kind, platforms=platforms, dependencies=deps,
                  rpaths=rpaths, encryption_ids=encryption, entry_offsets=entry_offsets)
    blockers = []
    if any(encryption):
        blockers.append("Encrypted image; no modification or decryption is attempted.")
    if kind == "EXECUTE":
        blockers.append("MH_EXECUTE does not meet SnowRunner's MH_DYLIB validator; loading and startup must be independently verified on iOS.")
    if any(p not in {"2", "IOS"} for p in platforms):
        blockers.append("Image targets a non-iOS platform; any retargeting must be performed on a separate copy.")
    if any(d["desktop_framework"] or d["framework_in_iphone_sdk"] is False for d in deps):
        blockers.append("Desktop or SDK-missing frameworks require API compatibility analysis.")
    if any(d["versioned_macos_path"] for d in deps):
        blockers.append("Versioned macOS framework paths require mapping even when an iOS framework exists.")
    record["blockers"] = blockers
    for option in ("imports", "exports", "inits"):
        try:
            output = tool("dyld_info", "-arch", "arm64", "-" + option, path)
            detail = details / (relative.replace("/", "__") + "." + option + ".txt")
            detail.write_text(output)
            record[option + "_report"] = str(detail)
            if option == "imports":
                record["sdl_import_lines"] = [line.strip() for line in output.splitlines() if re.search(r"\b_?SDL_", line)]
                record["objc_class_import_lines"] = [line.strip() for line in output.splitlines() if "OBJC_CLASS_$_" in line]
        except RuntimeError as error:
            record[option + "_error"] = str(error)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Complete Stray.app (or another macOS .app)")
    parser.add_argument("--out", type=Path, required=True, help="Separate directory for audit reports")
    args = parser.parse_args()
    root = args.app.expanduser().resolve()
    out = args.out.expanduser().resolve()
    if out == root or root in out.parents:
        parser.error("Report directory must be outside the source game bundle")
    plist = root / "Contents/Info.plist"
    if not plist.is_file():
        parser.error("Expected a complete macOS .app containing Contents/Info.plist")
    info = plistlib.loads(plist.read_bytes())
    executable = root / "Contents/MacOS" / info.get("CFBundleExecutable", "")
    if not executable.is_file():
        parser.error("CFBundleExecutable is missing; the download or extraction may be incomplete")
    out.mkdir(parents=True, exist_ok=True)
    details = out / "symbols"
    details.mkdir(exist_ok=True)
    sdk = Path(tool("--sdk", "iphoneos", "--show-sdk-path").strip())
    records, errors, seen = [], [], set()
    extensions = Counter()
    shader_paths = []
    total_bytes = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if root not in resolved.parents or resolved in seen:
            continue
        seen.add(resolved)
        extensions[path.suffix.lower()] += 1
        total_bytes += path.stat().st_size
        if path.suffix.lower() == ".metallib":
            shader_paths.append(str(path.relative_to(root)))
        try:
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic in MAGICS:
                records.append(inspect(path, root, sdk, details))
        except (OSError, RuntimeError) as error:
            errors.append({"path": str(path.relative_to(root)), "error": str(error)})
    main_record = next((r for r in records if (root / r["path"]).resolve() == executable.resolve()), None)
    if main_record is None:
        errors.append({"path": str(executable.relative_to(root)), "error": "Main executable was not successfully audited as Mach-O"})
    report = {"created_utc": datetime.now(timezone.utc).isoformat(), "app": str(root),
              "bundle_identifier": info.get("CFBundleIdentifier"),
              "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
              "main_executable": str(executable.relative_to(root)), "main_file_type": main_record.get("file_type") if main_record else None,
              "unique_file_count": len(seen), "total_bytes": total_bytes,
              "asset_extensions": dict(extensions), "metal_libraries": shader_paths,
              "binaries": records, "errors": errors,
              "assessment": "Static inspection only. ARM64, Metal, or loadable dependencies do not establish iOS compatibility."}
    (out / "audit.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    lines = ["# Stray macOS binary audit", "", report["assessment"], "",
             f"Source: `{root}`", f"Version: {report['version']} ({report['build']})",
             f"Main image type: {report['main_file_type']}",
             f"Mach-O images: {len(records)}; standalone Metal libraries: {len(shader_paths)}", ""]
    for record in records:
        lines += [f"## {record['path']}", "", f"Architectures: {', '.join(record['architectures'])}", ""]
        lines += ["- " + item for item in record["blockers"]]
        if not record["blockers"]:
            lines += ["- No blockers found by these limited static checks; runtime testing is still required."]
        lines += [""]
    if errors:
        lines += ["## Incomplete checks", ""] + [f"- {e['path']}: {e['error']}" for e in errors]
    (out / "AUDIT.md").write_text("\n".join(lines) + "\n")
    print(f"Audited {len(records)} Mach-O images. Reports: {out}")
    if errors:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
