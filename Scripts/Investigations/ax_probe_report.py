"""Bounded summaries of synthetic heap and own-process system-code evidence.

Raw heap reports and instruction bytes remain in the temporary runner directory.
Only grouped counts, symbols, offsets and relevant ownership instructions are
printed by the investigation workflow.
"""
import ctypes
import hashlib
import json
import re
import struct
import subprocess
import sys

DESTROYED = "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification"

# Heap classes, images and stack categories use literal labels. Dynamic symbols
# additionally require independent system-image verification at both output gates.
HEAP_TYPES = ("NSXPCConnection", "NSMutableArray", "NSMutableArray (Storage)",
              "NSArray", "NSDictionary", "NSMutableDictionary", "NSString", "NSData")
HEAP_STACK_PATTERNS = {
    "ax_destroyed": r"\b_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification\b",
    "ax_registration": r"\b_NSAccessibility(?:AddObserver|RegisterObserver)\b",
    "xpc_connection": r"(?:\bxpc_connection_create(?:_mach_service)?\b|\-\[NSXPCConnection initWith)",
    "button_initialization": r"\-\[NSButton initWithFrame:\]",
    "xpc_interface": r"[-+]\[NSXPCInterface [^\]]+\]",
    "xpc_decode": r"-\[(?:NSXPCDecoder|NSXPCConnection) (?:_decode|__decode)[^\]]+\]",
    "xpc_encode": r"-\[NSXPCEncoder [^\]]+\]",
    "cf_array": r"(?:\b(?:__NSArray[IM]_new|CFArrayCreate(?:Mutable)?)\b|[-+]\[(?:__NSArray[IM]|NSArray|NSMutableArray) [^\]]+\])",
    "xpc_container": r"\bxpc_(?:array|dictionary)_create\b",
    "notification_center": r"-\[NSNotificationCenter [^\]]+\]",
}
HEAP_LABELS = ("baseline", "empty-control", "added-10", "registered-10", "removed-10", "removed-20", "removed-30", "observer-exited")
# Exact, OS-owned paths are used only for local verification and never emitted.
HEAP_IMAGES = {
    "AppKit": ("com.apple.AppKit", "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"),
    "Foundation": ("com.apple.Foundation", "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"),
    "CoreFoundation": ("com.apple.CoreFoundation", "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"),
    "libxpc": ("libxpc.dylib", "/usr/lib/system/libxpc.dylib"),
    "libobjc": ("libobjc.A.dylib", "/usr/lib/libobjc.A.dylib"),
    "libmalloc": ("libsystem_malloc.dylib", "/usr/lib/system/libsystem_malloc.dylib"),
    "libdispatch": ("libdispatch.dylib", "/usr/lib/system/libdispatch.dylib"),
}
HEAP_SYMBOL_IMAGES = ("AppKit", "Foundation", "CoreFoundation", "libxpc")
C_SYMBOL = r"[A-Za-z_][A-Za-z_0-9]*"
OBJC_SYMBOL = r"([-+])\[([A-Za-z_][A-Za-z_0-9]*) ([A-Za-z_][A-Za-z_0-9:]*)\]"


def public_system_symbol(image, symbol):
    return (image in HEAP_SYMBOL_IMAGES and type(symbol) is str and len(symbol) <= 128
            and re.fullmatch(rf"(?:{C_SYMBOL}|{OBJC_SYMBOL})", symbol) is not None)


class SystemSymbols:
    """Verify report symbols against this runner's Apple shared-cache metadata.

    No target attachment or target-memory reads. Hidden C symbols and complex names
    cannot be independently looked up at the public-output gate and stay private.
    """
    class Info(ctypes.Structure):
        _fields_ = [("path", ctypes.c_char_p), ("base", ctypes.c_void_p),
                    ("symbol", ctypes.c_char_p), ("address", ctypes.c_void_p)]

    def __init__(self):
        self.library = None
        self.cache = {}
        if sys.platform != "darwin":
            return
        try:
            self.framework = ctypes.CDLL(HEAP_IMAGES["AppKit"][1])
            self.library = ctypes.CDLL(None)
            signatures = {
                "dladdr": ([ctypes.c_void_p, ctypes.POINTER(self.Info)], ctypes.c_int),
                "dlsym": ([ctypes.c_void_p, ctypes.c_char_p], ctypes.c_void_p),
                "objc_getClass": ([ctypes.c_char_p], ctypes.c_void_p),
                "sel_registerName": ([ctypes.c_char_p], ctypes.c_void_p),
                "class_getInstanceMethod": ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_void_p),
                "class_getClassMethod": ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_void_p),
                "method_getImplementation": ([ctypes.c_void_p], ctypes.c_void_p),
            }
            for name, (arguments, result) in signatures.items():
                function = getattr(self.library, name)
                function.argtypes, function.restype = arguments, result
        except (OSError, AttributeError):
            self.library = None

    def metadata(self, address):
        if not self.library:
            return None
        info = self.Info()
        if not self.library.dladdr(address, ctypes.byref(info)) or not info.path or not info.symbol or not info.address:
            return None
        try:
            return (info.path.decode("ascii"), info.symbol.decode("ascii"), info.address)
        except UnicodeDecodeError:
            return None

    def lookup(self, image, symbol):
        if not public_system_symbol(image, symbol):
            return None
        key = (image, symbol)
        if key in self.cache:
            return self.cache[key]
        address = None
        if self.library:
            method = re.fullmatch(OBJC_SYMBOL, symbol)
            if method:
                cls = self.library.objc_getClass(method[2].encode("ascii"))
                if cls:
                    selector = self.library.sel_registerName(method[3].encode("ascii"))
                    getter = (self.library.class_getInstanceMethod if method[1] == "-"
                              else self.library.class_getClassMethod)
                    implementation = getter(cls, selector)
                    if implementation:
                        address = self.library.method_getImplementation(implementation)
            else:
                # Darwin RTLD_DEFAULT; dlsym results are still checked by dladdr.
                address = self.library.dlsym(ctypes.c_void_p(-2), symbol.encode("ascii"))
        metadata = self.metadata(address) if address else None
        value = address if metadata == (HEAP_IMAGES[image][1], symbol, address) else None
        self.cache[key] = value
        return value

    def verified(self, image, symbol, address, offset):
        if not public_system_symbol(image, symbol):
            return False
        start = self.lookup(image, symbol)
        return (start is not None and address - start == offset
                and self.metadata(address) == (HEAP_IMAGES[image][1], symbol, start))


def heap_stack_summary(stack, resolver):
    """Return fixed classifications and independently verified, unordered names."""
    frames = re.findall(r"^\d+\s+(\S+)\s+(0x[0-9a-fA-F]{1,16})\s+(.+?)\s+\+ (\d{1,10})\s*$", stack, re.MULTILINE)
    images, symbols = set(), set()
    unverified = False
    for raw_image, address, symbol, offset in frames:
        image = next((name for name, (reported, _) in HEAP_IMAGES.items()
                      if raw_image in (name, reported)), None)
        if image:
            images.add(image)
        if image in HEAP_SYMBOL_IMAGES:
            if resolver and resolver.verified(image, symbol, int(address, 16), int(offset)):
                symbols.add((image, symbol))
            else:
                unverified = True
    matches = {name for name, pattern in HEAP_STACK_PATTERNS.items()
               if any(re.search(pattern, frame[2]) for frame in frames)}
    return images, symbols, matches, not frames, unverified


def validate_heap_diagnostics_summary(value):
    """Fail closed before a caller prints diagnostics into a public CI log."""
    def require(condition):
        if not condition:
            raise ValueError("Invalid bounded heap diagnostic summary")

    integer = lambda item: type(item) is int and 0 <= item <= 1_000_000_000
    require(type(value) is dict and set(value) == {"schema", "status", "checkpoints", "symbols", "omitted_symbols", "symbols_status"})
    require(type(value["schema"]) is int and value["schema"] == 3)
    require(value["status"] in ("complete", "partial", "unavailable"))
    require(type(value["checkpoints"]) is list and len(value["checkpoints"]) < len(HEAP_LABELS))
    seen, rows = set(), 0
    fields = {"label", "status", "new_nodes", "new_bytes", "classified_nodes", "unparsed_nodes",
              "groups", "stack_matches", "unknown_stack_nodes", "omitted_groups",
              "image_nodes", "missing_stack_nodes", "unverified_stack_nodes"}
    for point in value["checkpoints"]:
        require(type(point) is dict and set(point) == fields)
        require(type(point["label"]) is str and point["label"] in HEAP_LABELS[1:] and point["label"] not in seen)
        seen.add(point["label"])
        require(point["status"] in ("complete", "partial", "unavailable"))
        for key in ("new_nodes", "new_bytes", "unparsed_nodes"):
            require(point[key] is None or integer(point[key]))
        for key in ("classified_nodes", "unknown_stack_nodes", "omitted_groups", "missing_stack_nodes", "unverified_stack_nodes"):
            require(integer(point[key]))
        for key in ("unknown_stack_nodes", "missing_stack_nodes", "unverified_stack_nodes"):
            require(point[key] <= point["classified_nodes"])
        require(type(point["image_nodes"]) is dict and set(point["image_nodes"]) == set(HEAP_IMAGES))
        require(all(integer(count) and count <= point["classified_nodes"] for count in point["image_nodes"].values()))
        require(type(point["stack_matches"]) is dict and set(point["stack_matches"]) == set(HEAP_STACK_PATTERNS))
        require(all(integer(count) for count in point["stack_matches"].values()))
        require(type(point["groups"]) is list)
        rows += len(point["groups"])
        require(rows <= 32)
        for group in point["groups"]:
            require(type(group) is dict and set(group) == {"type", "size", "count"})
            require(type(group["type"]) is str and group["type"] in (*HEAP_TYPES, "unknown"))
            require(integer(group["size"]) and integer(group["count"]))
        if point["status"] == "complete":
            require(point["unparsed_nodes"] == 0 and point["omitted_groups"] == 0)
            require(point["new_nodes"] == point["classified_nodes"] == sum(group["count"] for group in point["groups"]))
            require(point["new_bytes"] == sum(group["size"] * group["count"] for group in point["groups"]))
    if value["status"] == "complete":
        require(seen == set(HEAP_LABELS[1:]) and all(point["status"] == "complete" for point in value["checkpoints"]))
    require(integer(value["omitted_symbols"]))
    require(value["symbols_status"] in ("complete", "partial", "unavailable"))
    if value["symbols_status"] == "complete":
        require(value["omitted_symbols"] == 0 and value["status"] == "complete")
        require(all(not point["missing_stack_nodes"] and not point["unverified_stack_nodes"] for point in value["checkpoints"]))
    require(type(value["symbols"]) is list and len(value["symbols"]) <= 24)
    resolver = SystemSymbols() if value["symbols"] else None
    seen_symbols = set()
    for entry in value["symbols"]:
        require(type(entry) is dict and set(entry) == {"image", "symbol", "nodes"})
        require(type(entry["image"]) is str and public_system_symbol(entry["image"], entry["symbol"]))
        key = (entry["image"], entry["symbol"])
        require(key not in seen_symbols and resolver.lookup(*key) is not None)
        seen_symbols.add(key)
        require(type(entry["nodes"]) is dict and bool(entry["nodes"]) and set(entry["nodes"]) <= seen)
        for label, count in entry["nodes"].items():
            point = next(point for point in value["checkpoints"] if point["label"] == label)
            require(integer(count) and 0 < count <= point["image_nodes"][entry["image"]])
    require(len(json.dumps(value, ensure_ascii=True).encode("utf-8")) <= 16 * 1024)


def heap_diff_summary(report, *, resolver=None, symbol_counts=None):
    """Summarize `leaks --list --diffFrom` without exposing arbitrary text.

    At most 32 type/size groups and fixed image/stack counters are exported.
    Counts/sizes are bounded, and unsupported/truncated input cannot claim
    complete object classification. Stack coverage is reported separately;
    matches and independently verified symbols are evidence, not causal verdicts.
    """
    limit = 1_000_000_000
    summary = {"status": "unavailable", "new_nodes": None, "new_bytes": None,
               "classified_nodes": 0, "unparsed_nodes": None, "groups": [],
               "stack_matches": {name: 0 for name in HEAP_STACK_PATTERNS},
               "unknown_stack_nodes": 0, "omitted_groups": 0,
               "image_nodes": {name: 0 for name in HEAP_IMAGES},
               "missing_stack_nodes": 0, "unverified_stack_nodes": 0}
    if len(report) > 16 * 1024 * 1024:
        return summary
    total = re.search(r"^Process \d+: (\d+) leaks? for (\d+) total leaked bytes\.", report, re.MULTILINE)
    if not total or any(len(value) > 10 or int(value) > limit for value in total.groups()):
        return summary
    summary.update(new_nodes=int(total[1]), new_bytes=int(total[2]))
    groups = {}
    parsed_bytes = 0
    for block in report.split("Binary Images:", 1)[0].split("\nLeak: ")[1:]:
        header = re.match(r"0x[0-9a-fA-F]+\s+size=(\d+)\s+zone:\s+\S+\s+([^\n]*)", block)
        if not header or len(header[1]) > 10 or int(header[1]) > limit:
            continue
        size = int(header[1])
        # leaks separates a type description, language, and image with 2+ spaces.
        description = re.split(r"\s{2,}", header[2].strip())[0]
        kind = description if description in HEAP_TYPES else "unknown"
        key = (kind, size)
        groups[key] = groups.get(key, 0) + 1
        summary["classified_nodes"] += 1
        parsed_bytes += size
        stack = block.partition("Call stack:")[2]
        images, symbols, matches, missing, unverified = heap_stack_summary(stack, resolver)
        for name in images:
            summary["image_nodes"][name] += 1
        for name in matches:
            summary["stack_matches"][name] += 1
        summary["missing_stack_nodes"] += missing
        summary["unverified_stack_nodes"] += unverified
        if symbol_counts is not None:
            for key in symbols:
                symbol_counts[key] = symbol_counts.get(key, 0) + 1
        if not matches:
            summary["unknown_stack_nodes"] += 1
    summary["unparsed_nodes"] = max(0, summary["new_nodes"] - summary["classified_nodes"])
    summary["groups"] = [{"type": kind, "size": size, "count": count}
                         for (kind, size), count in sorted(groups.items())[:32]]
    summary["omitted_groups"] = max(0, len(groups) - 32)
    summary["status"] = ("complete" if summary["classified_nodes"] == summary["new_nodes"]
                         and parsed_bytes == summary["new_bytes"] and not summary["omitted_groups"] else "partial")
    return summary


def collect_heap_diagnostics(graph_directory, records):
    """Analyze captured graphs only after the owned fixture has stopped."""
    checkpoints = []
    symbols = {}
    resolver = SystemSymbols()
    remaining = 32
    # The baseline is the comparison origin, not a new-node checkpoint. leaks
    # rejects --diffFrom when both arguments refer to the same file.
    for label in HEAP_LABELS[1:]:
        graph = graph_directory / f"{label}.memgraph"
        if not graph.is_file():
            continue
        command = ["leaks", "--noContent", "--nosources", "--fullStacks", "--list",
                   f"--diffFrom={graph_directory / 'baseline.memgraph'}", str(graph)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            (graph_directory / f"{label}-diff.txt").write_text(result.stdout + result.stderr)
            counts = {}
            point = heap_diff_summary(result.stdout if result.returncode in (0, 1) else "",
                                      resolver=resolver, symbol_counts=counts)
            for key, count in counts.items():
                symbols.setdefault(key, {})[label] = count
        except subprocess.TimeoutExpired:
            point = heap_diff_summary("")
        point["label"] = label
        if len(point["groups"]) > remaining:
            point["omitted_groups"] += len(point["groups"]) - remaining
            point["groups"] = point["groups"][:remaining]
            point["status"] = "partial"
        remaining -= len(point["groups"])
        checkpoints.append(point)
    status = ("complete" if len(checkpoints) == len(HEAP_LABELS) - 1
              and all(point["status"] == "complete" for point in checkpoints) else
              "partial" if checkpoints else "unavailable")
    # Global dictionary, not a frame sequence or a repeated per-checkpoint stack.
    selected = sorted(symbols, key=lambda key: (-sum(symbols[key].values()), key))[:24]
    omitted = max(0, len(symbols) - len(selected))
    symbol_status = ("unavailable" if not checkpoints else "complete" if status == "complete" and not omitted
                     and all(not point["missing_stack_nodes"] and not point["unverified_stack_nodes"]
                             for point in checkpoints) else "partial")
    summary = {"schema": 3, "status": status, "checkpoints": checkpoints,
               "symbols": [{"image": image, "symbol": symbol, "nodes": symbols[(image, symbol)]}
                           for image, symbol in sorted(selected)],
               "omitted_symbols": omitted, "symbols_status": symbol_status}
    validate_heap_diagnostics_summary(summary)
    (records / "heap-diagnostics.json").write_text(json.dumps(summary) + "\n")


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
        groups.append({"root_instances": int(header[1]), "root_type": root[2] if root else header[2],
                       "root_kind": root[1] if root else None,
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
