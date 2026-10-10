"""Bounded summaries of synthetic heap and own-process system-code evidence.

Raw heap reports and instruction bytes remain in the temporary runner directory.
Only grouped counts, symbols, offsets and relevant ownership instructions are
printed by the investigation workflow.
"""
import hashlib
import json
import re
import struct
import subprocess

DESTROYED = "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification"


def allocation_stack(report):
    return [{"image": image, "symbol": symbol, "offset": int(offset)}
            for image, symbol, offset in re.findall(
                r"^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+?)\s+\+\s+(\d+)\s*$",
                report, re.MULTILINE)]


def allocation_groups(report):
    """Aggregate individual leaked allocations without exporting addresses."""
    groups = {}
    for block in re.split(r"(?=^Leak: )", report, flags=re.MULTILINE):
        header = re.match(r"Leak: 0x[0-9a-fA-F]+\s+size=(\d+)\s+zone: \S+([^\n]*)", block)
        if not header:
            continue
        stack = allocation_stack(block.split("Binary Images:", 1)[0])
        if not stack:
            raise RuntimeError("Leaked allocation has no allocation stack")
        kind = header[2].strip()
        key = (kind, int(header[1]), json.dumps(stack, sort_keys=True))
        group = groups.setdefault(key, {"type": kind, "allocation_bytes": int(header[1]),
                                       "count": 0, "allocation_stack": stack})
        group["count"] += 1
    return list(groups.values())


def leak_groups(report):
    groups = []
    for block in re.split(r"(?=STACK OF \d+ INSTANCES? OF )", report):
        header = re.match(r"STACK OF (\d+) INSTANCES? OF '([^']+)':", block)
        if not header:
            continue
        block = block.split("Binary Images:", 1)[0]
        tree = re.search(r"^\s*(\d+) \(([^)]+)\) ROOT (?:LEAK|CYCLE):", block, re.MULTILINE)
        # leaks includes the root classification inside the quoted type label.
        # Keep it separately so callers compare the actual class, not decoration.
        root = re.fullmatch(r"ROOT (LEAK|CYCLE): (.+)", header[2])
        # Keep allocation provenance, not just the root class. Strip runtime
        # addresses and retain only symbols from the no-content/no-sources scan.
        stack = allocation_stack(block.split("====", 1)[0])
        groups.append({"root_instances": int(header[1]), "root_type": root[2] if root else header[2],
                       "root_kind": root[1] if root else None,
                       "allocation_stack": stack,
                       "tree_nodes": int(tree[1]) if tree else None,
                       "display_size": tree[2] if tree else None,
                       "destroyed_return_offsets": sorted(set(map(int, re.findall(re.escape(DESTROYED) + r" \+ (\d+)", block))))})
    return groups


def disassemble_symbols(state, work, records):
    raw = json.loads((state / "symbol-code.json").read_text())
    summaries = []
    for index, symbol in enumerate(raw):
        start = symbol["start"]
        code = b"".join(struct.pack("<I", word) for word in symbol["words"])
        # A minimal local Mach-O section lets Xcode's decoder read this bounded
        # own-process code range without LLDB attachment or extra dependencies.
        header = struct.pack("<IIIIIIII", 0xfeedfacf, 0x100000c, 0, 1, 1, 152, 0, 0)
        segment = struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", start, len(code), 184, len(code), 7, 5, 1, 0)
        section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", start, len(code), 184, 2, 0, 0, 0x80000400, 0, 0, 0)
        object_file = work / f"system-symbol-{index}.o"
        object_file.write_bytes(header + segment + section + code)
        result = subprocess.run(["xcrun", "llvm-objdump", "--disassemble", "--no-show-raw-insn", str(object_file)],
                                capture_output=True, text=True, timeout=30, check=True)
        # This full disassembly stays local, not in the workflow's printed JSON.
        (records / f"system-symbol-{index}-disassembly.txt").write_text(result.stdout)
        branches = {entry["offset"]: entry for entry in symbol["branches"]}
        instructions = []
        for line in result.stdout.splitlines():
            match = re.match(r"\s*([0-9a-f]+):\s+(.*)", line)
            if not match:
                continue
            offset = int(match[1], 16) - start
            text = " ".join(match[2].split())
            branch = branches.get(offset)
            if branch:
                target = branch["resolved"] or branch["symbol"]
                references = branch.get("stubReferences", [])
                selectors = [entry["selector"] for entry in references if "selector" in entry]
                if target == "unknown" and len(selectors) == 1:
                    target = "selector-stub:" + selectors[0]
                text = text.split()[0] + " " + target + f" +{branch['symbolOffset']}"
            else:
                def normalize(value):
                    address = int(value[0], 16)
                    if start <= address < start + len(code):
                        return f"function+{address - start}"
                    if text.startswith("adrp "):
                        return "image-page"
                    return value[0]
                text = re.sub(r"0x[0-9a-f]+", normalize, text)
            instructions.append({"offset": offset, "instruction": text})
        if len(instructions) != len(symbol["words"]) or not symbol["boundedBySymbol"]:
            raise RuntimeError("System-symbol decoding was incomplete or unbounded")
        interesting = ("copy", "Copy", "setObject:forKey:", "initWithKeyOptions:", "release", "autorelease", "_NSAccessibilityNotify")
        selected = set()
        for position, instruction in enumerate(instructions):
            if any(term in instruction["instruction"] for term in interesting):
                selected.update(range(max(0, position - 4), min(len(instructions), position + 4)))
        selected.update(range(max(0, len(instructions) - 12), len(instructions)))
        summaries.append({"symbol": symbol["name"], "image_offset": hex(symbol["imageOffset"]),
                          "byte_count": len(code), "code_sha256": hashlib.sha256(code).hexdigest(),
                          "decoded_instructions": len(instructions), "bounded_by_next_symbol": True,
                          "calls": [{"offset": item["offset"], "symbol": item["symbol"],
                                    "symbol_offset": item["symbolOffset"], "resolved": item["resolved"],
                                    "stub_references": item.get("stubReferences", [])}
                                    for item in symbol["branches"] if item["symbol"] != symbol["name"]],
                          "references": symbol["references"],
                          "ownership_instructions": [instructions[position] for position in sorted(selected)]})
    return summaries
