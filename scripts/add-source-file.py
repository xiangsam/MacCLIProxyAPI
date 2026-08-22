#!/usr/bin/env python3
"""Register a Swift file in MacCLIProxyAPI.xcodeproj.

project.yml exists but xcodegen is not installed here, so project.pbxproj is hand-maintained.
This inserts the four entries Xcode needs (build file, file reference, group child, sources
phase) next to an existing sibling file in the same directory.

Usage: scripts/add-source-file.py Core/Services/Foo.swift [more.swift ...]
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "MacCLIProxyAPI.xcodeproj", "project.pbxproj")


def uid(seed):
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def sibling(text, directory, skip):
    """An already-registered file from the same directory, used as the insertion anchor."""
    for match in re.finditer(r"([0-9A-F]{24}) /\* (\S+\.swift) \*/ = \{isa = PBXFileReference", text):
        ref, name = match.group(1), match.group(2)
        if name == skip:
            continue
        if os.path.exists(os.path.join(ROOT, directory, name)) and f"{ref} /* {name} */," in text:
            return ref, name
    return None, None


def add(text, rel):
    directory, name = os.path.split(rel)
    if f"/* {name} */ = {{isa = PBXFileReference" in text:
        return text, f"skip {rel} (already registered)"

    anchor_ref, anchor_name = sibling(text, directory, name)
    if not anchor_ref:
        raise SystemExit(f"no registered sibling found for {rel}; add it in Xcode instead")

    file_ref, build_ref = uid(rel + "#file"), uid(rel + "#build")

    text = text.replace(
        f"\t\t{anchor_ref} /* {anchor_name} */ = {{isa = PBXFileReference;",
        f"\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n"
        f"\t\t{anchor_ref} /* {anchor_name} */ = {{isa = PBXFileReference;",
        1,
    )
    text = text.replace(
        f"\t\t\t\t{anchor_ref} /* {anchor_name} */,",
        f"\t\t\t\t{file_ref} /* {name} */,\n\t\t\t\t{anchor_ref} /* {anchor_name} */,",
        1,
    )

    anchor_build = re.search(
        r"([0-9A-F]{24}) /\* " + re.escape(anchor_name) + r" in Sources \*/ = \{isa = PBXBuildFile",
        text,
    ).group(1)
    text = text.replace(
        f"\t\t{anchor_build} /* {anchor_name} in Sources */ = {{isa = PBXBuildFile;",
        f"\t\t{build_ref} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref} /* {name} */; }};\n"
        f"\t\t{anchor_build} /* {anchor_name} in Sources */ = {{isa = PBXBuildFile;",
        1,
    )
    text = text.replace(
        f"\t\t\t\t{anchor_build} /* {anchor_name} in Sources */,",
        f"\t\t\t\t{build_ref} /* {name} in Sources */,\n\t\t\t\t{anchor_build} /* {anchor_name} in Sources */,",
        1,
    )
    return text, f"added {rel} (anchor: {anchor_name})"


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    with open(PBX) as handle:
        text = handle.read()
    for rel in sys.argv[1:]:
        if not os.path.exists(os.path.join(ROOT, rel)):
            raise SystemExit(f"missing file: {rel}")
        text, note = add(text, rel)
        print(note)
    with open(PBX, "w") as handle:
        handle.write(text)


if __name__ == "__main__":
    main()
