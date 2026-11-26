#!/usr/bin/env python3
"""Shared enforcement for the three-layer interpreter policy.

The allowlist in tests/interpreter-allowlist.json is the single place where an
exception may be made. Every entry needs a reason and a PR/issue reference, so
a new exception has to be argued in a pull request.
"""
from __future__ import annotations

import json
import re
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST_PATH = ROOT / "tests" / "interpreter-allowlist.json"

INTERPRETER_LIB = re.compile(
    r"^lib(?:python|perl|ruby|lua|tcl|guile)\b", re.IGNORECASE
)
INTERPRETER_ELEMENT = re.compile(
    r"(?:^|[/:])(?:python[0-9.]*|perl|ruby|lua|tcl|tk|guile|node|php|pypy|"
    r"jython|awk|gawk)(?:\.[^/]*)?\.bst$"
)
ANSI = re.compile(r"\x1b\[[0-9;]*m")
SHELL_EXEC = re.compile(
    r"(^|[\s=/])(?:sh|bash|dash|zsh|fish|python[0-9.]*|perl|ruby|lua|tcl|guile)"
    r"(\s|$|\s+-c\b)"
)
NOLOGIN_SHELLS = {"/usr/sbin/nologin", "/sbin/nologin", "/usr/bin/false", "/bin/false"}

SECTIONS = (
    "content_shebang",
    "content_elf",
    "graph_runtime",
    "unit_exec",
    "login_shell",
)

# A member of the initramfs whose name is one of these is an interpreter
# binary, regardless of whether it is a regular file or a symlink.
INTERPRETER_BASENAME = re.compile(
    r"(?:sh|bash|dash|zsh|fish|python[0-9.]*|perl(?:-[0-9.]+)?|ruby|lua|"
    r"node|php|tcl|guile|awk|gawk)"
)

ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
CPIO_MAGIC = (b"070701", b"070702")
CPIO_HEADER = 110
CPIO_TRAILER = "TRAILER!!!"


@dataclass
class Allowlist:
    entries: dict[str, dict[str, dict]] = field(default_factory=dict)
    used: set[tuple[str, str]] = field(default_factory=set)

    def has(self, section: str, key: str) -> bool:
        if key in self.entries.get(section, {}):
            self.used.add((section, key))
            return True
        return False


def load_allowlist(path: Path = ALLOWLIST_PATH) -> Allowlist:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path}: top level must be an object")
    unknown = set(data) - set(SECTIONS) - {"_comment"}
    if unknown:
        raise ValueError(f"{path}: unknown sections: {sorted(unknown)}")
    result = Allowlist()
    for section in SECTIONS:
        items = data.get(section, [])
        if not isinstance(items, list):
            raise ValueError(f"{path}: {section} must be a list")
        table: dict[str, dict] = {}
        for item in items:
            if not isinstance(item, dict):
                raise ValueError(f"{path}: {section} entries must be objects")
            reason = item.get("reason")
            ref = item.get("ref")
            if not reason or not ref:
                raise ValueError(f"{path}: {section} entry needs reason and ref: {item}")
            key = (item.get("path") or item.get("element")
                   or item.get("unit") or item.get("user"))
            if not key:
                raise ValueError(f"{path}: {section} entry needs a key: {item}")
            if key in table:
                raise ValueError(f"{path}: duplicate {section} entry for {key}")
            table[key] = item
        result.entries[section] = table
    return result


def stale_entries(allow: Allowlist) -> list[str]:
    return [
        f"{section}[{key!r}]"
        for section, table in allow.entries.items()
        for key in table
        if (section, key) not in allow.used
    ]


def needed_libs(blob: bytes) -> list[str]:
    """Return DT_NEEDED names from an ELF blob, without external tools."""
    if len(blob) < 20 or blob[:4] != b"\x7fELF":
        return []
    elf_class, data_encoding = blob[4], blob[5]
    if elf_class not in (1, 2) or data_encoding not in (1, 2):
        raise ValueError("malformed ELF ident")
    endian = "<" if data_encoding == 1 else ">"

    if elf_class == 2:
        shoff, = struct.unpack_from(endian + "Q", blob, 0x28)
        shentsize, shnum = struct.unpack_from(endian + "HH", blob, 0x3A)
        hdr_fmt = endian + "IIQQQQII"
    else:
        shoff, = struct.unpack_from(endian + "I", blob, 0x20)
        shentsize, shnum = struct.unpack_from(endian + "HH", blob, 0x2E)
        hdr_fmt = endian + "IIIIIIII"
    if shentsize == 0 or shnum == 0:
        return []
    if shoff + shentsize * shnum > len(blob):
        raise ValueError("ELF section table out of bounds")

    sections = []
    for i in range(shnum):
        off = shoff + i * shentsize
        fields = struct.unpack_from(hdr_fmt, blob, off)
        sections.append({
            "type": fields[1],
            "offset": fields[4],
            "size": fields[5],
            "link": fields[6],
        })

    dynamic = next((s for s in sections if s["type"] == 6), None)
    if dynamic is None:
        return []
    strtab = sections[dynamic["link"]]
    strings = blob[strtab["offset"]:strtab["offset"] + strtab["size"]]

    entry_fmt = endian + ("QQ" if elf_class == 2 else "II")
    step = struct.calcsize(entry_fmt)
    needed = []
    for off in range(dynamic["offset"], dynamic["offset"] + dynamic["size"], step):
        tag, val = struct.unpack_from(entry_fmt, blob, off)
        if tag == 0:
            break
        if tag != 1:  # DT_NEEDED
            continue
        if val >= len(strings):
            raise ValueError("ELF DT_NEEDED offset out of bounds")
        name = strings[val:].split(b"\0", 1)[0].decode("utf-8", "replace")
        needed.append(name)
    return needed


def check_content(files: Iterable[tuple[str, bytes]], allow: Allowlist) -> list[str]:
    errors: list[str] = []
    for path, blob in files:
        if path.startswith(("usr/share/licenses/", "usr/share/doc/")):
            continue
        if blob.startswith(b"#!"):
            if not allow.has("content_shebang", path):
                interpreter = blob.split(b"\n", 1)[0].decode("utf-8", "replace")
                errors.append(
                    f"[content] shebang in {path}: {interpreter!r} is not allowlisted "
                    "(content_shebang); add an entry with a reason in "
                    "tests/interpreter-allowlist.json or remove the script"
                )
        elif blob.startswith(b"\x7fELF"):
            try:
                libs = needed_libs(blob)
            except ValueError as exc:
                errors.append(f"[content] malformed ELF {path}: {exc}")
                continue
            for lib in libs:
                if INTERPRETER_LIB.match(lib) and not allow.has("content_elf", path):
                    errors.append(
                        f"[content] ELF {path} links {lib} (DT_NEEDED) and is not "
                        "allowlisted (content_elf); add an entry with a reason in "
                        "tests/interpreter-allowlist.json or drop the dependency"
                    )
    return errors


@dataclass(frozen=True)
class InitramfsMember:
    """One cpio entry from the compressed initramfs."""
    path: str
    mode: int
    payload: bytes


def _align4(offset: int) -> int:
    return (offset + 3) & ~3


def _parse_cpio(blob: bytes, start: int) -> tuple[int, list[InitramfsMember]]:
    """Parse one newc/crc cpio archive; return (offset past it, members)."""
    members: list[InitramfsMember] = []
    offset = start
    while True:
        if offset + CPIO_HEADER > len(blob):
            raise ValueError("truncated cpio header")
        magic = blob[offset:offset + 6]
        if magic not in CPIO_MAGIC:
            raise ValueError(f"bad cpio magic {magic!r}")
        fields = blob[offset:offset + CPIO_HEADER].decode("ascii")
        vals = [int(fields[i:i + 8], 16) for i in range(6, 102, 8)]
        mode, filesize, namesize = vals[1], vals[6], vals[11]

        name_start = offset + CPIO_HEADER
        name_end = name_start + namesize
        if name_end > len(blob):
            raise ValueError("truncated cpio name")
        name = blob[name_start:name_end].split(b"\0", 1)[0].decode("utf-8", "replace")
        data_start = _align4(name_end)
        data_end = data_start + filesize
        if data_end > len(blob):
            raise ValueError("truncated cpio data")
        payload = blob[data_start:data_end]
        offset = _align4(data_end)

        if name == CPIO_TRAILER:
            return offset, members
        path = name[2:] if name.startswith("./") else name.lstrip("/")
        members.append(InitramfsMember(path=path, mode=mode, payload=payload))


def iter_initramfs_members(blob: bytes) -> list[InitramfsMember]:
    """Walk a dracut initramfs.

    Dracut prepends optional uncompressed cpio archives (early microcode) before
    a zstd-compressed newc/crc cpio archive. Every member is exposed so the gate
    can inspect paths inside the archive, not just the top-level image tar.
    """
    import compression.zstd  # Python 3.14 stdlib; available on the CI runner.

    members: list[InitramfsMember] = []
    pos = 0
    while pos < len(blob):
        # Dracut pads each concatenated archive with zero bytes to an alignment
        # boundary. Skip that padding before looking for the next archive magic.
        if blob[pos] == 0:
            pos += 1
            continue
        if blob[pos:pos + 6] in CPIO_MAGIC:
            pos, entries = _parse_cpio(blob, pos)
            members.extend(entries)
            pos = _align4(pos)
        elif blob[pos:pos + 4] == ZSTD_MAGIC:
            raw = compression.zstd.ZstdDecompressor().decompress(blob[pos:])
            inner = 0
            while inner < len(raw) and raw[inner:inner + 6] in CPIO_MAGIC:
                inner, entries = _parse_cpio(raw, inner)
                members.extend(entries)
                inner = _align4(inner)
            break
        else:
            raise ValueError(
                f"unexpected initramfs data at offset {pos}: {blob[pos:pos + 6]!r}"
            )
    return members


def _is_interpreter_name(path: str) -> bool:
    name = path.rstrip("/").rsplit("/", 1)[-1]
    return bool(INTERPRETER_BASENAME.fullmatch(name))


def check_initramfs(members: Iterable[InitramfsMember]) -> list[str]:
    """Fail on any interpreter binary or shebang script inside the initramfs.

    There is deliberately no allowlist parameter. Hard rule 1 covers boot
    artifacts, so a shell in the initramfs is a violation even if a script in
    `/usr` would be allowlisted. The only way to make this check pass is to
    remove the offenders from the initramfs or redesign the boot path without
    an interpreter.
    """
    errors: list[str] = []
    for member in members:
        if not member.path:
            continue
        reasons = []
        if _is_interpreter_name(member.path):
            reasons.append("interpreter binary")
        is_regular = (member.mode & 0o170000) == 0o100000
        if is_regular and member.payload.startswith(b"#!"):
            shebang = member.payload.split(b"\n", 1)[0].decode("utf-8", "replace")
            reasons.append(f"shebang {shebang!r}")
        if not reasons:
            continue
        errors.append(
            f"[initramfs] {' + '.join(reasons)} at /{member.path} violates hard "
            "rule 1; remove it from the initramfs or redesign the boot path "
            "without an interpreter"
        )
    return errors


def graph_elements(target: str = "base/os-stack.bst") -> list[str]:
    """Query the runtime graph. Script elements cannot have runtime deps, so the
    shipped payload stack is the meaningful target, not oci/mjolnir.bst itself.
    """
    proc = subprocess.run(
        ["just", "bst", "show", target, "--deps", "run", "--format", "%{name}"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        tail = "\n".join(proc.stderr.splitlines()[-5:])
        raise RuntimeError(f"just bst show {target} failed ({proc.returncode}): {tail}")
    return [
        line for line in (ANSI.sub("", x).strip() for x in proc.stdout.splitlines())
        if line.endswith(".bst")
    ]


def check_graph(elements: Iterable[str], allow: Allowlist) -> list[str]:
    errors = []
    for element in elements:
        if INTERPRETER_ELEMENT.search(element) and not allow.has("graph_runtime", element):
            errors.append(
                f"[graph] {element} is a runtime dependency of base/os-stack.bst and "
                "is not allowlisted (graph_runtime); remove it or argue an exception "
                "in tests/interpreter-allowlist.json"
            )
    return errors


def check_units(units: Iterable[tuple[str, str]], allow: Allowlist) -> list[str]:
    errors = []
    for path, text in units:
        for lineno, line in enumerate(text.splitlines(), 1):
            if not re.match(r"\s*ExecStart(?:Pre|Post)?=", line):
                continue
            value = line.split("=", 1)[1]
            if SHELL_EXEC.search(value) and not allow.has("unit_exec", f"{path}:{lineno}"):
                errors.append(
                    f"[unit] {path}:{lineno}: ExecStart uses an interpreter or shell: "
                    f"{value.strip()!r}; use a direct binary path, or allowlist with a reason"
                )
    return errors


def check_login_shells(sysusers_text: str, allow: Allowlist) -> list[str]:
    errors = []
    for line in sysusers_text.splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[0] != "u":
            continue
        user, shell = fields[1], fields[5]
        if shell not in NOLOGIN_SHELLS and not allow.has("login_shell", user):
            errors.append(
                f"[unit] sysusers entry for {user!r} has shell {shell!r}, which is not "
                "a nologin shell; change it or allowlist it with a reason"
            )
    return errors
