"""Bounded summaries of synthetic heap and own-process system-code evidence.

Raw heap reports and instruction bytes remain in the temporary runner directory.
Only grouped counts, symbols, offsets and relevant ownership instructions are
printed by the investigation workflow.
"""
import ctypes
from collections import Counter
import hashlib
import json
import re
import struct
import subprocess
import sys
import time
import ax_system_images

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
HEAP_LABELS = ("baseline", "added-10", "registered-10", "removed-10", "removed-20", "removed-30", "observer-exited")
COHORT_FIELDS = ("preexisting_nodes", "new_allocation_nodes", "unknown_nodes")
COHORT_ADDRESS_LIMIT = 128
COHORT_SECONDS = 45
REPORT_BYTE_LIMIT = 16 * 1024 * 1024
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


def validation_failure_counts(result):
    """Project private assertion records into fixed categories, never messages."""
    counts = dict.fromkeys(("heap_baseline", "control_activity", "notifications", "compensation_branches",
                           "allocator_environment", "other"), 0)
    if type(result) is not dict or result.get("coverage") not in ("passed", "measured", "failed"):
        raise ValueError("Invalid fixture result")
    errors = result.get("validation_errors", [])
    if type(errors) is not list or len(errors) > 64 or (result["coverage"] == "failed") != bool(errors):
        raise ValueError("Incomplete validation failures")
    for error in errors:
        if type(error) is not dict or type(error.get("stage")) is not str or not 1 <= len(error["stage"]) <= 64:
            raise ValueError("Invalid validation failure stage")
        stage = error["stage"]
        if stage in HEAP_LABELS:
            category = "heap_baseline"
        elif re.fullmatch(r"control-(?:host|reader)-\d{1,3}", stage):
            category = "control_activity"
        elif stage == "notifications":
            category = "notifications"
        elif stage == "compensation-branches":
            category = "compensation_branches"
        elif stage in ("malloc-scribble", "external-startup-host", "external-startup-reader",
                       "external-startup-complete", "external-startup-final"):
            category = "allocator_environment"
        else:
            category = "other"
        counts[category] += 1
    return counts


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
    require(type(value) is dict and set(value) == {"schema", "status", "checkpoints", "symbols", "omitted_symbols", "symbols_status", "cohorts_status"})
    require(type(value["schema"]) is int and value["schema"] == 4)
    require(value["status"] in ("complete", "partial", "unavailable"))
    require(type(value["checkpoints"]) is list and len(value["checkpoints"]) < len(HEAP_LABELS))
    seen, rows = set(), 0
    fields = {"label", "status", "new_nodes", "new_bytes", "classified_nodes", "unparsed_nodes",
              "groups", "stack_matches", "unknown_stack_nodes", "omitted_groups",
              "image_nodes", "missing_stack_nodes", "unverified_stack_nodes", "allocation_cohorts"}
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
        cohorts = point["allocation_cohorts"]
        require(type(cohorts) is dict and set(cohorts) == {"status", *COHORT_FIELDS})
        require(cohorts["status"] in ("complete", "partial", "unavailable"))
        require(all(integer(cohorts[key]) for key in COHORT_FIELDS[:2]))
        require(cohorts["unknown_nodes"] is None or integer(cohorts["unknown_nodes"]))
        if point["new_nodes"] is None:
            require(cohorts == empty_cohorts(None))
        else:
            require(cohorts["unknown_nodes"] is not None)
            require(sum(cohorts[key] for key in COHORT_FIELDS) == point["new_nodes"])
            require(cohorts["preexisting_nodes"] + cohorts["new_allocation_nodes"] <= COHORT_ADDRESS_LIMIT)
        if cohorts["status"] == "complete":
            require(cohorts["unknown_nodes"] == 0 and point["unparsed_nodes"] == 0)
        if cohorts["status"] == "unavailable":
            require(cohorts["preexisting_nodes"] == cohorts["new_allocation_nodes"] == 0)
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
    require(value["cohorts_status"] in ("complete", "partial", "unavailable"))
    require(value["cohorts_status"] == cohort_status(value["checkpoints"]))
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


def empty_cohorts(nodes):
    return {"status": "complete" if nodes == 0 else "unavailable", "preexisting_nodes": 0,
            "new_allocation_nodes": 0, "unknown_nodes": nodes}


def cohort_status(checkpoints):
    if len(checkpoints) == len(HEAP_LABELS) - 1 and all(
            point["allocation_cohorts"]["status"] == "complete" for point in checkpoints):
        return "complete"
    return ("partial" if any(point["allocation_cohorts"]["status"] != "unavailable" for point in checkpoints)
            else "unavailable")


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
               "missing_stack_nodes": 0, "unverified_stack_nodes": 0, "allocation_cohorts": empty_cohorts(None)}
    if len(report) > REPORT_BYTE_LIMIT:
        return summary
    total = re.search(r"^Process \d+: (\d+) leaks? for (\d+) total leaked bytes\.", report, re.MULTILINE)
    if not total or any(len(value) > 10 or int(value) > limit for value in total.groups()):
        return summary
    summary.update(new_nodes=int(total[1]), new_bytes=int(total[2]))
    summary["allocation_cohorts"] = empty_cohorts(summary["new_nodes"])
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


def leak_allocations(report, point):
    """Private addresses only; a partial leak listing cannot establish a cohort."""
    if point["unparsed_nodes"] != 0 or point["new_nodes"] is None:
        return None
    rows = re.findall(r"^Leak: (0x[0-9a-fA-F]{1,16})\s+size=(\d{1,10})\s+zone:", report, re.MULTILINE)
    nodes = {int(address, 16): int(size) for address, size in rows}
    if (len(nodes) != len(rows) or len(nodes) != point["new_nodes"]
            or sum(nodes.values()) != point["new_bytes"]):
        return None
    return nodes


def heap_allocations(report):
    """Require the complete all-zones address list, including for an empty diff."""
    if len(report) > REPORT_BYTE_LIMIT:
        return None
    total = re.search(r"^All zones: (\d{1,6}) nodes malloced", report, re.MULTILINE)
    rows = re.findall(r"^(0x[0-9a-fA-F]{1,16}): [^\n]+ \((\d{1,10}) bytes\)\s*$", report, re.MULTILINE)
    nodes = {int(address, 16): int(size) for address, size in rows}
    if (not total or int(total[1]) > 100_000 or len(nodes) != len(rows) or len(nodes) != int(total[1])
            or any(size > 1_000_000_000 for size in nodes.values())
            or len(re.findall(r"^0x", report, re.MULTILINE)) != len(rows)):
        return None
    return nodes


def allocation_history(report, addresses):
    """Read frozen NoCompact history, never use an address/stack match as identity.

    malloc_history may repeat an event for several queried addresses inside the
    same historical allocation. Every graph is queried with the identical address
    set; retain those multiplicities instead of deduplicating allocation events.
    """
    if (len(report) > REPORT_BYTE_LIMIT or not report.endswith("\n")
            or not report.startswith("malloc_history Report Version:  2.0\n")):
        return None
    events = {address: Counter() for address in addresses}
    for line in report.splitlines()[1:]:
        if not line or line == "----" or re.fullmatch(r"no stack logs found for 0x[0-9a-fA-F]{1,16}", line):
            continue
        event = re.fullmatch(r"(ALLOC|FREE|VM_ALLOC|VM_FREE)\s+(0x[0-9a-fA-F]{1,16})-(0x[0-9a-fA-F]{1,16})"
                             r" \[size=(\d{1,16})\]:\s+.+", line)
        if not event:
            return None
        kind, address, end, size = event.groups()
        address, end, size = int(address, 16), int(end, 16), int(size)
        if end - address + 1 != size:
            return None
        if kind in ("ALLOC", "FREE") and address in events:
            events[address][(kind, size)] += 1
    return events


def allocation_generation(before, after, before_size, after_size):
    # Missing, truncated or compacted histories cannot certify a generation.
    if (not before or not after or not before[("ALLOC", before_size)]
            or not after[("ALLOC", after_size)] or before - after):
        return None
    if before == after and before_size == after_size:
        return "preexisting_nodes"
    added = after - before
    if any(kind == "ALLOC" for kind, _ in added) and any(kind == "FREE" for kind, _ in added):
        return "new_allocation_nodes"
    return None


def collect_allocation_cohorts(graph_directory, checkpoints, reports):
    """Bounded offline attribution; this cannot change the live heap verdict."""
    allocations = {point["label"]: leak_allocations(reports[point["label"]], point) for point in checkpoints}
    candidates = sorted({address for nodes in allocations.values() if nodes for address in nodes})[:COHORT_ADDRESS_LIMIT]
    if not candidates:
        return
    deadline = time.monotonic() + COHORT_SECONDS

    def run(name, command):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return ""
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=min(15, remaining))
            (graph_directory / f"{name}.txt").write_text(result.stdout + result.stderr)
            return result.stdout if result.returncode == 0 and not result.stderr else ""
        except (OSError, subprocess.TimeoutExpired):
            return ""

    baseline = graph_directory / "baseline.memgraph"
    before = heap_allocations(run("baseline-allocations", ["heap", "--noContent", "--addresses", "all", str(baseline)]))
    if before is None:
        return
    history_addresses = [address for address in candidates if address in before]
    address_args = [hex(address) for address in history_addresses]
    old_history = (allocation_history(run("baseline-history", ["malloc_history", str(baseline), *address_args]), history_addresses)
                   if history_addresses else None)
    for point in checkpoints:
        nodes = allocations[point["label"]]
        if not nodes:
            continue
        graph = graph_directory / f"{point['label']}.memgraph"
        new = heap_allocations(run(f"{point['label']}-allocations", ["heap", "--noContent", "--addresses", "all",
                                f"--diffFrom={baseline}", str(graph)]))
        history = (allocation_history(run(f"{point['label']}-history", ["malloc_history", str(graph), *address_args]), history_addresses)
                   if old_history is not None and any(address in nodes for address in history_addresses) else None)
        cohorts = point["allocation_cohorts"]
        for address in candidates:
            if address not in nodes:
                continue
            kind = None
            if address not in before and new is not None and new.get(address) == nodes[address]:
                kind = "new_allocation_nodes"
            elif address in before and history is not None:
                kind = allocation_generation(old_history[address], history[address], before[address], nodes[address])
                # heap's independent allocation diff must agree with the history.
                if new is None or (kind == "preexisting_nodes" and address in new):
                    kind = None
                if kind == "new_allocation_nodes" and new.get(address) != nodes[address]:
                    kind = None
            if kind:
                cohorts[kind] += 1
                cohorts["unknown_nodes"] -= 1
        cohorts["status"] = ("complete" if cohorts["unknown_nodes"] == 0 else "partial"
                             if cohorts["preexisting_nodes"] or cohorts["new_allocation_nodes"] else "unavailable")


def collect_heap_diagnostics(graph_directory, records):
    """Analyze captured graphs only after the owned fixture has stopped."""
    checkpoints = []
    symbols = {}
    resolver = SystemSymbols()
    remaining = 32
    reports = {}
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
            report = result.stdout if result.returncode in (0, 1) else ""
            point = heap_diff_summary(report,
                                      resolver=resolver, symbol_counts=counts)
            for key, count in counts.items():
                symbols.setdefault(key, {})[label] = count
        except (OSError, subprocess.TimeoutExpired):
            report = ""
            point = heap_diff_summary("")
        point["label"] = label
        reports[label] = report
        if len(point["groups"]) > remaining:
            point["omitted_groups"] += len(point["groups"]) - remaining
            point["groups"] = point["groups"][:remaining]
            point["status"] = "partial"
        remaining -= len(point["groups"])
        checkpoints.append(point)
    collect_allocation_cohorts(graph_directory, checkpoints, reports)
    status = ("complete" if len(checkpoints) == len(HEAP_LABELS) - 1
              and all(point["status"] == "complete" for point in checkpoints) else
              "partial" if checkpoints else "unavailable")
    # Global dictionary, not a frame sequence or a repeated per-checkpoint stack.
    selected = sorted(symbols, key=lambda key: (-sum(symbols[key].values()), key))[:24]
    omitted = max(0, len(symbols) - len(selected))
    symbol_status = ("unavailable" if not checkpoints else "complete" if status == "complete" and not omitted
                     and all(not point["missing_stack_nodes"] and not point["unverified_stack_nodes"]
                             for point in checkpoints) else "partial")
    summary = {"schema": 4, "status": status, "checkpoints": checkpoints,
               "symbols": [{"image": image, "symbol": symbol, "nodes": symbols[(image, symbol)]}
                           for image, symbol in sorted(selected)],
               "omitted_symbols": omitted, "symbols_status": symbol_status, "cohorts_status": cohort_status(checkpoints)}
    validate_heap_diagnostics_summary(summary)
    (records / "heap-diagnostics.json").write_text(json.dumps(summary) + "\n")


def _grouped_total_trees(report):
    """Validate every group and report totals when a grouped aggregate is present."""
    body = report.split("Binary Images:", 1)[0]
    if not re.search(r"^ +\d+ \([^)]+\) <<", body, re.MULTILINE):
        return None
    # Composition depends on this module through frozen-node helpers. Defer the
    # import and reuse its grammar once per tree, without a second report parse.
    from ax_composition import _group_tree

    totals = list(re.finditer(r"^Process \d+: (\d+) leaks? for (\d+) total leaked bytes\.$", body, re.MULTILINE))
    if len(totals) != 1:
        raise ValueError("Invalid grouped totals")
    total = totals[0]
    blocks = re.split(r"(?=^STACK OF )", body[total.end():], flags=re.MULTILINE)
    if blocks[0].strip() or "STACK OF " in body[:total.start()]:
        raise ValueError("Invalid grouped prefix")
    groups, roots, byte_ranges = [], [], []
    for block in blocks[1:]:
        header, _, remainder = block.partition("\n")
        match = re.fullmatch(r"STACK OF (\d{1,6}) INSTANCES? OF '(ROOT LEAK|ROOT CYCLE): ([^\n']+)':", header)
        if not match or remainder.count("\n====\n") != 1:
            raise ValueError("Invalid grouped header")
        _, tree = remainder.split("\n====\n")
        lines = [line for line in tree.splitlines() if line.strip()]
        first = re.fullmatch(r" +(\d+) \(([^)]+)\) (?:<< TOTAL >>|ROOT (?:LEAK|CYCLE): .+)", lines[0]) if lines else None
        if not first:
            raise ValueError("Invalid grouped tree")
        own_rows, group_roots, group_bytes = _group_tree(lines, int(match[1]), match[2], match[3], int(total[2]), [])
        if (sum(root["count"] for root in group_roots) != int(first[1])
                or sum(count for _, count, _, _ in own_rows) != int(first[1])):
            raise ValueError("Incomplete grouped tree")
        byte_ranges.append(group_bytes)
        roots.extend(group_roots)
        groups.append((int(first[1]), first[2]))
    if (sum(root["count"] for root in roots) != int(total[1]) or not
            sum(low for low, _ in byte_ranges) <= int(total[2]) <= sum(high for _, high in byte_ranges)):
        raise ValueError("Grouped report totals disagree")
    return groups


def leak_groups(report):
    groups = []
    try:
        validated = _grouped_total_trees(report)
    except ValueError:
        validated = []
    for block in re.split(r"(?=STACK OF \d+ INSTANCES? OF )", report):
        header = re.match(r"STACK OF (\d+) INSTANCES? OF '([^']+)':", block)
        if not header:
            continue
        block = block.split("Binary Images:", 1)[0]
        tree = re.search(r"^\s*(\d+) \(([^)]+)\) ROOT (?:LEAK|CYCLE):", block, re.MULTILINE)
        # leaks includes the root classification inside the quoted type label.
        # Keep it separately so callers compare the actual class, not decoration.
        root = re.fullmatch(r"ROOT (LEAK|CYCLE): (.+)", header[2])
        nodes, size = (int(tree[1]), tree[2]) if tree else (None, None)
        _, separator, tree_text = block.partition("\n====\n")
        tree_lines = [line for line in tree_text.splitlines() if line.strip()]
        if validated is not None:
            nodes, size = validated[len(groups)] if len(groups) < len(validated) else (None, None)
        elif separator and tree_lines and not re.fullmatch(
                r"\s+\d+ \([^)]+\) ROOT (?:LEAK|CYCLE): .+", tree_lines[0]):
            nodes, size = None, None
        groups.append({"root_instances": int(header[1]), "root_type": root[2] if root else header[2],
                       "root_kind": root[1] if root else None,
                       "tree_nodes": nodes,
                       "display_size": size,
                       "destroyed_return_offsets": sorted(set(map(int, re.findall(re.escape(DESTROYED) + r" \+ (\d+)", block))))})
    return groups


# The terminal report is independent of allocation cohorts. Its two text views
# describe one later snapshot; neither counts nor stack equality bind it to a
# node from the preceding live scans. Bounds also apply at the public gate.
TERMINAL_ROOT_LIMIT = 16
TERMINAL_GROUP_LIMIT = 96
TERMINAL_FRAME_LIMIT = 96
TERMINAL_IMAGE_FRAME_LIMIT = 96
TERMINAL_NODE_LIMIT = 4096
TERMINAL_SECONDS = 45
TERMINAL_FRAME = re.compile(r"(\d{1,3})\s+(\S+)\s+(0x[0-9a-fA-F]{1,16})\s+(.+?)\s+\+ (\d{1,10})\s*")


def empty_terminal_snapshot():
    return {"schema": 3, "status": "unavailable", "capture_status": "not-run", "capture_exit_code": None,
            "analysis_status": "not-run", "tool_exit_codes": {"grouped": None, "list": None},
            "parsing_status": "unavailable", "stacks_status": "unavailable",
            "frame_order": "allocation-first", "leak_nodes": None, "leak_bytes": None,
            "root_instances": 0, "root_groups": [], "allocation_groups": [], "allocation_type_totals": None,
            "omitted_root_groups": 0, "omitted_allocation_groups": 0}


def terminal_frames(text):
    """Private frame tokens; retain repeated symbols and reject ambiguous indices."""
    frames, unparsed = [], 0
    for line in text.splitlines():
        if not line.strip():
            continue
        match = TERMINAL_FRAME.fullmatch(line)
        if match:
            frames.append((int(match[1]), match[2], int(match[3], 16), match[4], int(match[5])))
        else:
            unparsed += 1
    indices = [frame[0] for frame in frames]
    if len(indices) != len(set(indices)) or len(indices) > 512 or any(index > 511 for index in indices):
        raise ValueError("Ambiguous terminal frames")
    if indices not in (sorted(indices), sorted(indices, reverse=True)):
        raise ValueError("Unordered terminal frames")
    return tuple(sorted(frames)), unparsed


def terminal_reported_image(raw_image):
    """Classify report labels only; this does not verify a loaded image."""
    return next((name for name, (reported, _) in HEAP_IMAGES.items() if raw_image in (name, reported)), "other")


def terminal_stack(frames, unparsed, resolver, budget):
    public = []
    filtered = unverified = limited = 0
    for index, raw_image, address, symbol, offset in frames:
        image = terminal_reported_image(raw_image)
        if image not in HEAP_SYMBOL_IMAGES:
            filtered += 1
        elif not budget[0]:
            limited += 1
        else:
            # Bound independent lookups, including failures, not just output.
            budget[0] -= 1
            if resolver.verified(image, symbol, address, offset):
                public.append({"index": index, "image": image, "symbol": symbol})
            else:
                unverified += 1
    missing = frames[-1][0] + 1 - len(frames) if frames else None
    omitted = len(frames) - len(public)
    status = "missing" if not frames else "partial" if omitted or missing or unparsed else "complete"
    return {"status": status, "reported_frames": len(frames), "missing_frames": missing,
            "unparsed_lines": unparsed, "omitted_frames": omitted, "filtered_frames": filtered,
            "unverified_frames": unverified, "budget_omitted_frames": limited, "frames": public}


def terminal_other_images(frames, context, budget):
    """Image-only evidence; it neither consumes nor repairs symbol coverage."""
    public, reasons = [], dict.fromkeys(ax_system_images.REASONS, 0)
    for index, raw_image, address, *_ in frames:
        if terminal_reported_image(raw_image) != "other":
            continue
        if not budget[0]:
            reasons["budget_omitted"] += 1
            continue
        budget[0] -= 1
        ranges = context["ranges"]
        if ranges is None:
            reasons["report_images_invalid"] += 1
            continue
        matches = [identifier for start, end, identifier in ranges if start <= address <= end]
        if not matches:
            reasons["report_range_missing"] += 1
        elif matches[0] is None:
            reasons["report_uuid_ambiguous"] += 1
        else:
            if "catalog" not in context:
                try:
                    context["catalog"] = ax_system_images.loaded_system_images(context.get("cleanup_path"))
                except (ax_system_images.ImageWorkerCleanupError, ax_system_images.ImageWorkerArtifactError) as error:
                    context["catalog"], context["cleanup_error"] = None, error
            catalog = context["catalog"]
            if catalog is None:
                reasons["local_catalog_unavailable"] += 1
            elif matches[0] not in catalog:
                reasons["uuid_not_verified"] += 1
            else:
                public.append({"index": index, **catalog[matches[0]]})
    count = len(public) + sum(reasons.values())
    return {"status": "not-needed" if not count else "partial" if sum(reasons.values()) else "complete",
            "frames": public, "reason_counts": reasons}


def terminal_roots(body, nodes):
    roots, root_keys = [], set()
    validated = _grouped_total_trees(body)
    blocks = re.split(r"(?=^STACK OF )", body, flags=re.MULTILINE)[1:]
    for block in blocks:
        header, _, remainder = block.partition("\n")
        match = re.fullmatch(r"STACK OF (\d+) INSTANCES? OF 'ROOT (LEAK|CYCLE): ([^\n]+)':", header)
        stack, separator, tree = remainder.partition("\n====\n")
        tree_lines = [line for line in tree.splitlines() if line.strip()]
        first = re.fullmatch(r"\s+(\d+) \([^)]+\) ROOT (LEAK|CYCLE): (.+)", tree_lines[0]) if tree_lines else None
        if not match or not separator:
            raise ValueError("Invalid terminal root group")
        if validated is not None:
            tree_nodes, _ = validated[len(roots)]
            if tree_nodes > TERMINAL_NODE_LIMIT:
                raise ValueError("Invalid terminal root group")
        elif first:
            if ((match[2], match[3]) != (first[2], first[3])
                    or not 1 <= int(match[1]) <= int(first[1]) <= TERMINAL_NODE_LIMIT):
                raise ValueError("Invalid terminal root group")
            tree_nodes = int(first[1])
        else:
            raise ValueError("Invalid terminal root group")
        frames, unparsed = terminal_frames(stack)
        key = (match[2], match[3], frames)
        if key in root_keys:
            raise ValueError("Duplicate terminal root group")
        root_keys.add(key)
        roots.append({"type": match[3] if match[3] in HEAP_TYPES else "unknown", "kind": match[2],
                      "instances": int(match[1]), "tree_nodes": tree_nodes, "private_stack": (frames, unparsed)})
    if sum(root["tree_nodes"] for root in roots) != nodes:
        raise ValueError("Incomplete terminal root groups")
    return roots


def terminal_snapshot_summary(grouped, listed, resolver, image_worker_receipt=None, image_worker_error=None):
    """Parse observed leaks v4 grouped/v3 list syntax, without a node-to-root join.

    A grouped header owns the stack immediately before its tree. The list view
    contributes whole-snapshot type/size/stack counts only, not descendant links.
    Unknown formatting fails closed instead of guessing NSXPC-specific syntax.
    """
    result = empty_terminal_snapshot()
    image_context = {}
    try:
        reports = []
        for text in (grouped, listed):
            if len(text.encode()) > REPORT_BYTE_LIMIT:
                raise ValueError("Terminal report budget")
            body = text.split("\nBinary Images:", 1)[0]
            totals = re.findall(r"^Process \d+: (\d+) leaks? for (\d+) total leaked bytes\.\s*$", text, re.MULTILINE)
            if len(totals) != 1:
                raise ValueError("Terminal totals unavailable")
            nodes, size = map(int, totals[0])
            if nodes > TERMINAL_NODE_LIMIT or size > 1_000_000_000:
                raise ValueError("Terminal node budget")
            reports.append((body, nodes, size))
        if reports[0][1:] != reports[1][1:]:
            raise ValueError("Terminal views disagree")
        result.update(leak_nodes=reports[0][1], leak_bytes=reports[0][2])
        allocation_counts, addresses = Counter(), set()
        type_totals = {kind: dict.fromkeys(("nodes", "bytes", "retained_nodes", "retained_bytes", "omitted_nodes", "omitted_bytes"), 0)
                       for kind in (*HEAP_TYPES, "unknown")}
        blocks = reports[1][0].split("\nLeak: ")[1:]
        if len(blocks) != result["leak_nodes"]:
            raise ValueError("Incomplete terminal list")
        byte_count = 0
        for block in blocks:
            header, separator, stack = block.partition("\n\tCall stack:")
            match = re.fullmatch(r"(0x[0-9a-fA-F]{1,16})\s+size=(\d+)\s+zone:\s*\S+\s{2,}([^\n]+)", header)
            if not match or int(match[1], 16) in addresses:
                raise ValueError("Invalid terminal list row")
            addresses.add(int(match[1], 16))
            size = int(match[2])
            byte_count += size
            kind = re.split(r"\s{2,}", match[3])[0]
            kind = kind if kind in HEAP_TYPES else "unknown"
            type_totals[kind]["nodes"] += 1
            type_totals[kind]["bytes"] += size
            frames, unparsed = terminal_frames(stack if separator else "")
            allocation_counts[(kind, size, frames, unparsed)] += 1
        if byte_count != result["leak_bytes"]:
            raise ValueError("Terminal list bytes disagree")
        roots = terminal_roots(reports[0][0], result["leak_nodes"])
        result["root_instances"] = sum(root["instances"] for root in roots)
        budget = [TERMINAL_FRAME_LIMIT]
        image_budget = [TERMINAL_IMAGE_FRAME_LIMIT]
        try:
            image_context = {"ranges": ax_system_images.report_images(grouped)}
        except ValueError:
            image_context = {"ranges": None}
        image_context["cleanup_path"] = image_worker_receipt
        if image_worker_error is not None:
            image_context.update(catalog=None, cleanup_error=image_worker_error)
        for root in roots[:TERMINAL_ROOT_LIMIT]:
            frames, unparsed = root.pop("private_stack")
            # Fixed report-label buckets explain the image prefilter, without
            # publishing unknown labels or claiming independent verification.
            images = dict.fromkeys((*HEAP_IMAGES, "other"), 0)
            for _, raw_image, *_ in frames:
                images[terminal_reported_image(raw_image)] += 1
            root["reported_image_counts"] = images
            root["reported_filtered_reason_counts"] = {
                "known_image_excluded": sum(images[name] for name in HEAP_IMAGES if name not in HEAP_SYMBOL_IMAGES),
                "unrecognized_image": images["other"]}
            root["stack"] = terminal_stack(frames, unparsed, resolver, budget)
            root["other_image_identity"] = terminal_other_images(frames, image_context, image_budget)
            result["root_groups"].append(root)
        result["omitted_root_groups"] = max(0, len(roots) - TERMINAL_ROOT_LIMIT)
        for (kind, size, frames, unparsed), count in list(sorted(allocation_counts.items()))[:TERMINAL_GROUP_LIMIT]:
            result["allocation_groups"].append({"type": kind, "size": size, "count": count,
                                               "stack": terminal_stack(frames, unparsed, resolver, budget)})
            type_totals[kind]["retained_nodes"] += count
            type_totals[kind]["retained_bytes"] += count * size
        for counts in type_totals.values():
            counts["omitted_nodes"] = counts["nodes"] - counts["retained_nodes"]
            counts["omitted_bytes"] = counts["bytes"] - counts["retained_bytes"]
        result["allocation_type_totals"] = type_totals
        result["omitted_allocation_groups"] = max(0, len(allocation_counts) - TERMINAL_GROUP_LIMIT)
        result["parsing_status"] = "complete"
        rows = result["root_groups"] + result["allocation_groups"]
        result["stacks_status"] = ("partial" if result["omitted_root_groups"] or result["omitted_allocation_groups"]
            or any(row["stack"]["status"] != "complete" for row in rows) else "complete")
    except (ValueError, TypeError):
        # No partially interpreted raw text or unsafely associated frames escape.
        result = empty_terminal_snapshot()
    if "cleanup_error" in image_context:
        error = image_context["cleanup_error"]
        error.snapshot = result
        raise error
    return result


def capture_terminal_snapshot(pid, graph, timeout=60):
    result = empty_terminal_snapshot()
    try:
        captured = subprocess.run(["leaks", "--noContent", "--fullStacks", f"--outputGraph={graph}", str(pid)],
                                  capture_output=True, text=True, timeout=timeout)
        graph.with_suffix(".capture.txt").write_text(captured.stdout + captured.stderr)
        result["capture_exit_code"] = captured.returncode
        result["capture_status"] = "complete" if captured.returncode in (0, 1) and graph.is_file() else "failed"
    except subprocess.TimeoutExpired:
        result["capture_status"] = "timeout"
    except OSError:
        result["capture_status"] = "failed"
    return result


def collect_terminal_snapshot(graph, records, capture):
    """Called only after the host exits; bounded tools consume the single graph."""
    result = dict(capture)
    cleanup_path = records / "terminal-image-worker.json"
    cleanup_error = None
    try:
        ax_system_images.write_worker_cleanup(cleanup_path, True)
    except ax_system_images.ImageWorkerArtifactError as error:
        cleanup_error = error
    if result["capture_status"] == "complete":
        deadline = time.monotonic() + TERMINAL_SECONDS
        codes, reports = dict(result["tool_exit_codes"]), {}
        analysis_status = "complete"
        try:
            for name, flag in (("grouped", "--groupByType"), ("list", "--list")):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired("terminal analysis", TERMINAL_SECONDS)
                output = subprocess.run(["leaks", "--noContent", flag, "--nosources", "--fullStacks", str(graph)],
                                        capture_output=True, text=True, timeout=remaining)
                (records / f"terminal-{name}.txt").write_text(output.stdout + output.stderr)
                codes[name] = output.returncode
                if output.returncode not in (0, 1) or len(output.stdout.encode()) > REPORT_BYTE_LIMIT:
                    analysis_status = "failed"
                reports[name] = output.stdout
            if analysis_status == "complete":
                try:
                    result.update(terminal_snapshot_summary(reports["grouped"], reports["list"], SystemSymbols(), cleanup_path, cleanup_error))
                except (ax_system_images.ImageWorkerCleanupError, ax_system_images.ImageWorkerArtifactError) as error:
                    result.update(error.snapshot)
                    cleanup_error = error
        except subprocess.TimeoutExpired:
            analysis_status = "timeout"
        except OSError:
            analysis_status = "failed"
        result.update(capture_status=capture["capture_status"], capture_exit_code=capture["capture_exit_code"],
                      analysis_status=analysis_status, tool_exit_codes=codes)
    result["status"] = ("unavailable" if result["parsing_status"] != "complete" else
                        "complete" if result["stacks_status"] == "complete" else "partial")
    try:
        validate_terminal_snapshot(result, cleanup_path, cleanup_error)
    except (ax_system_images.ImageWorkerCleanupError, ax_system_images.ImageWorkerArtifactError) as error:
        cleanup_error = cleanup_error or error
    (records / "terminal-snapshot.json").write_text(json.dumps(result, indent=2) + "\n")
    if cleanup_error is not None:
        raise cleanup_error
    collect_terminal_cache_identity(records, result, reports.get("grouped") if result["capture_status"] == "complete" else None)
    return result


def validate_terminal_snapshot(value, image_worker_receipt=None, image_worker_error=None):
    """Validate all fields, then prune only unverified image identities in place.

    The symbol gate is unchanged. A fresh image catalog failure cannot discard
    the preexisting terminal evidence or publish a merely well-formed identity.
    """
    def require(condition):
        if not condition:
            raise ValueError("Invalid bounded terminal snapshot")

    integer = lambda item: type(item) is int and 0 <= item <= 1_000_000_000
    require(type(value) is dict and set(value) == set(empty_terminal_snapshot()))
    require(type(value["schema"]) is int and value["schema"] == 3 and value["frame_order"] == "allocation-first")
    require(value["capture_status"] in ("not-run", "complete", "timeout", "failed"))
    require(value["analysis_status"] in ("not-run", "complete", "timeout", "failed"))
    require(value["parsing_status"] in ("unavailable", "complete") and value["stacks_status"] in ("unavailable", "complete", "partial"))
    require(type(value["tool_exit_codes"]) is dict and set(value["tool_exit_codes"]) == {"grouped", "list"})
    for code in [value["capture_exit_code"], *value["tool_exit_codes"].values()]:
        require(code is None or type(code) is int and -128 <= code <= 255)
    require(type(value["root_groups"]) is list and len(value["root_groups"]) <= TERMINAL_ROOT_LIMIT)
    require(type(value["allocation_groups"]) is list and len(value["allocation_groups"]) <= TERMINAL_GROUP_LIMIT)
    for key in ("root_instances", "omitted_root_groups", "omitted_allocation_groups"):
        require(integer(value[key]) and value[key] <= TERMINAL_NODE_LIMIT)
    for key in ("leak_nodes", "leak_bytes"):
        require(value[key] is None or integer(value[key]))
    resolver, frame_count = SystemSymbols(), 0
    image_count, image_identities = 0, []
    rows = value["root_groups"] + value["allocation_groups"]
    for root, entries in ((True, value["root_groups"]), (False, value["allocation_groups"])):
        for row in entries:
            fields = ({"type", "kind", "instances", "tree_nodes", "stack", "reported_image_counts", "reported_filtered_reason_counts",
                       "other_image_identity"}
                      if root else {"type", "size", "count", "stack"})
            require(type(row) is dict and set(row) == fields and row["type"] in (*HEAP_TYPES, "unknown"))
            if root:
                require(row["kind"] in ("LEAK", "CYCLE") and integer(row["instances"]) and integer(row["tree_nodes"])
                        and 1 <= row["instances"] <= row["tree_nodes"] <= TERMINAL_NODE_LIMIT)
            else:
                require(integer(row["size"]) and integer(row["count"]) and 1 <= row["count"] <= TERMINAL_NODE_LIMIT)
            stack = row["stack"]
            require(type(stack) is dict and set(stack) == {"status", "reported_frames", "missing_frames", "unparsed_lines", "omitted_frames",
                                                          "filtered_frames", "unverified_frames", "budget_omitted_frames", "frames"})
            require(all(integer(stack[key]) for key in ("reported_frames", "unparsed_lines", "omitted_frames",
                                                        "filtered_frames", "unverified_frames", "budget_omitted_frames")))
            require(stack["omitted_frames"] == stack["filtered_frames"] + stack["unverified_frames"] + stack["budget_omitted_frames"])
            require(stack["reported_frames"] <= 512 and stack["unparsed_lines"] <= REPORT_BYTE_LIMIT)
            require(stack["missing_frames"] is None if not stack["reported_frames"] else
                    integer(stack["missing_frames"]) and stack["missing_frames"] + stack["reported_frames"] <= 512)
            require(type(stack["frames"]) is list and len(stack["frames"]) + stack["omitted_frames"] == stack["reported_frames"])
            indices = []
            for frame in stack["frames"]:
                require(type(frame) is dict and set(frame) == {"index", "image", "symbol"})
                require(integer(frame["index"]) and frame["index"] < stack["reported_frames"] + stack["missing_frames"])
                require(public_system_symbol(frame["image"], frame["symbol"]) and resolver.lookup(frame["image"], frame["symbol"]) is not None)
                indices.append(frame["index"])
            require(indices == sorted(set(indices)))
            if root:
                images, reasons = row["reported_image_counts"], row["reported_filtered_reason_counts"]
                require(type(images) is dict and set(images) == {*HEAP_IMAGES, "other"}
                        and all(integer(count) for count in images.values())
                        and sum(images.values()) == stack["reported_frames"])
                require(type(reasons) is dict and set(reasons) == {"known_image_excluded", "unrecognized_image"}
                        and all(integer(count) for count in reasons.values())
                        and reasons["unrecognized_image"] == images["other"]
                        and reasons["known_image_excluded"] == sum(images[name] for name in HEAP_IMAGES if name not in HEAP_SYMBOL_IMAGES)
                        and sum(reasons.values()) == stack["filtered_frames"])
                retained_images = Counter(frame["image"] for frame in stack["frames"])
                require(all(retained_images[image] <= images[image] for image in HEAP_SYMBOL_IMAGES))
                identity = row["other_image_identity"]
                require(type(identity) is dict and set(identity) == {"status", "frames", "reason_counts"})
                why = identity["reason_counts"]
                require(type(why) is dict and set(why) == set(ax_system_images.REASONS)
                        and all(integer(count) for count in why.values()))
                require(type(identity["frames"]) is list and len(identity["frames"]) <= TERMINAL_IMAGE_FRAME_LIMIT
                        and len(identity["frames"]) + sum(why.values()) == images["other"])
                identity_indices = []
                for frame in identity["frames"]:
                    require(type(frame) is dict and set(frame) == {"index", "basename", "uuid"})
                    require(integer(frame["index"]) and frame["index"] < stack["reported_frames"] + stack["missing_frames"]
                            and frame["index"] not in indices)
                    image = {key: frame[key] for key in ("basename", "uuid")}
                    require(ax_system_images.safe_identity(image))
                    identity_indices.append(frame["index"])
                require(identity_indices == sorted(set(identity_indices)))
                image_count += images["other"] - why["budget_omitted"]
                expected_identity = ("not-needed" if not images["other"] else "partial" if sum(why.values()) else "complete")
                require(identity["status"] == expected_identity)
                if identity["frames"]:
                    image_identities.append(identity)
            frame_count += len(indices)
            expected = ("missing" if not stack["reported_frames"] else "partial" if
                        stack["missing_frames"] or stack["omitted_frames"] or stack["unparsed_lines"] else "complete")
            require(stack["status"] == expected)
    require(frame_count + sum(row["stack"]["unverified_frames"] for row in rows) <= TERMINAL_FRAME_LIMIT)
    require(image_count <= TERMINAL_IMAGE_FRAME_LIMIT)
    if value["parsing_status"] == "complete":
        require(value["capture_status"] == value["analysis_status"] == "complete" and value["capture_exit_code"] in (0, 1)
                and all(code in (0, 1) for code in value["tool_exit_codes"].values()))
        require(integer(value["leak_nodes"]) and value["leak_nodes"] <= TERMINAL_NODE_LIMIT and integer(value["leak_bytes"]))
        roots = sum(row["instances"] for row in value["root_groups"])
        nodes = sum(row["count"] for row in value["allocation_groups"])
        size = sum(row["count"] * row["size"] for row in value["allocation_groups"])
        tree_nodes = sum(row["tree_nodes"] for row in value["root_groups"])
        require(roots <= value["root_instances"] <= value["leak_nodes"] and tree_nodes <= value["leak_nodes"])
        require(nodes <= value["leak_nodes"] and size <= value["leak_bytes"])
        require(value["omitted_root_groups"] or roots == value["root_instances"] and tree_nodes == value["leak_nodes"])
        require(value["omitted_allocation_groups"] or nodes == value["leak_nodes"] and size == value["leak_bytes"])
        totals = value["allocation_type_totals"]
        require(type(totals) is dict and set(totals) == {*HEAP_TYPES, "unknown"})
        for kind, counts in totals.items():
            require(type(counts) is dict and set(counts) == {"nodes", "bytes", "retained_nodes", "retained_bytes", "omitted_nodes", "omitted_bytes"}
                    and all(integer(count) for count in counts.values()))
            entries = [row for row in value["allocation_groups"] if row["type"] == kind]
            require(counts["retained_nodes"] == sum(row["count"] for row in entries)
                    and counts["retained_bytes"] == sum(row["count"] * row["size"] for row in entries))
            for metric in ("nodes", "bytes"):
                require(counts[metric] == counts["retained_" + metric] + counts["omitted_" + metric])
            for prefix in ("", "retained_", "omitted_"):
                require(counts[prefix + "nodes"] or not counts[prefix + "bytes"])
        require(sum(counts["nodes"] for counts in totals.values()) == value["leak_nodes"]
                and sum(counts["bytes"] for counts in totals.values()) == value["leak_bytes"])
        omitted_nodes = sum(counts["omitted_nodes"] for counts in totals.values())
        omitted_types = sum(counts["omitted_nodes"] > 0 for counts in totals.values())
        require(omitted_types <= value["omitted_allocation_groups"] <= omitted_nodes)
        require(value["omitted_allocation_groups"] or not omitted_nodes)
        expected = "partial" if value["omitted_root_groups"] or value["omitted_allocation_groups"] or any(row["stack"]["status"] != "complete" for row in rows) else "complete"
        require(value["stacks_status"] == value["status"] == expected)
    else:
        require(not rows and value["leak_nodes"] is None and value["leak_bytes"] is None
                and value["allocation_type_totals"] is None
                and value["root_instances"] == value["omitted_root_groups"] == value["omitted_allocation_groups"] == 0
                and value["stacks_status"] == value["status"] == "unavailable")
    require(len(json.dumps(value).encode()) <= 65536)
    # Do not repair malformed input. Only after the entire original object has
    # passed validation may this optional evidence be normalized. Both callers
    # publish this same object. One fresh worker serves all roots, even on None.
    cleanup_error = image_worker_error
    image_catalog = None
    exited, artifacts_cleaned = ax_system_images.worker_cleanup_state(image_worker_receipt)
    if cleanup_error is None and not exited:
        cleanup_error = ax_system_images.ImageWorkerCleanupError()
    elif cleanup_error is None and not artifacts_cleaned:
        cleanup_error = ax_system_images.ImageWorkerArtifactError()
    if cleanup_error is None and image_identities:
        try:
            image_catalog = ax_system_images.loaded_system_images(image_worker_receipt)
        except (ax_system_images.ImageWorkerCleanupError, ax_system_images.ImageWorkerArtifactError) as error:
            cleanup_error = error
    if image_identities:
        for identity in image_identities:
            retained = []
            for frame in identity["frames"]:
                image = {key: frame[key] for key in ("basename", "uuid")}
                reason = ("local_catalog_unavailable" if image_catalog is None else
                          "uuid_not_verified" if image_catalog.get(image["uuid"]) != image else None)
                if reason:
                    identity["reason_counts"][reason] += 1
                    identity["status"] = "partial"
                else:
                    retained.append(frame)
            identity["frames"] = retained
    if cleanup_error is not None:
        raise cleanup_error


CACHE_IDENTITY_REASONS = ("binding_unavailable", "report_images_invalid", "report_range_missing", "report_uuid_ambiguous",
                          "budget_omitted", "lookup_unavailable", "cache_changed", "uuid_missing", "uuid_duplicate",
                          "image_excluded", "identity_changed", "output_budget")
CACHE_RECORD_LIMIT = 49152  # Private binding manifest plus the independently bounded native packet.


def terminal_cache_identity(terminal, reason="binding_unavailable"):
    reasons = dict.fromkeys(CACHE_IDENTITY_REASONS, 0)
    if reason:
        reasons[reason] = 1
    return {"schema": 1, "source": "active-shared-cache", "status": "unavailable",
            "terminal_sha256": hashlib.sha256(json.dumps(terminal, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "active_cache_uuid": None, "frames": [], "reason_counts": reasons}


def terminal_cache_bindings(grouped, terminal):
    """Derive private root/frame UUIDs from the report, never a claimed map."""
    if type(grouped) is not str or len(grouped.encode()) > REPORT_BYTE_LIMIT or terminal["parsing_status"] != "complete":
        raise ValueError("Cache binding source unavailable")
    totals = re.findall(r"^Process \d+: (\d+) leaks? for (\d+) total leaked bytes\.\s*$", grouped, re.MULTILINE)
    if len(totals) != 1 or tuple(map(int, totals[0])) != (terminal["leak_nodes"], terminal["leak_bytes"]):
        raise ValueError("Cache binding totals differ")
    roots = terminal_roots(grouped.split("\nBinary Images:", 1)[0], terminal["leak_nodes"])
    if len(roots[:TERMINAL_ROOT_LIMIT]) != len(terminal["root_groups"]):
        raise ValueError("Cache binding roots differ")
    try:
        ranges = ax_system_images.report_images(grouped)
    except ValueError:
        ranges = None
    bindings, reasons, remaining = [], dict.fromkeys(CACHE_IDENTITY_REASONS, 0), 96
    for root_index, (root, published) in enumerate(zip(roots, terminal["root_groups"])):
        frames, unparsed = root["private_stack"]
        images = dict.fromkeys((*HEAP_IMAGES, "other"), 0)
        for _, label, *_ in frames:
            images[terminal_reported_image(label)] += 1
        if (any(root[key] != published[key] for key in ("type", "kind", "instances", "tree_nodes"))
                or images != published["reported_image_counts"] or len(frames) != published["stack"]["reported_frames"]
                or unparsed != published["stack"]["unparsed_lines"]
                or (frames[-1][0] + 1 - len(frames) if frames else None) != published["stack"]["missing_frames"]):
            raise ValueError("Cache binding root differs")
        for index, label, address, *_ in frames:
            if terminal_reported_image(label) != "other":
                continue
            if not remaining:
                reasons["budget_omitted"] += 1
                continue
            remaining -= 1
            matches = [] if ranges is None else [identifier for start, end, identifier in ranges if start <= address <= end]
            if ranges is None:
                reasons["report_images_invalid"] += 1
            elif not matches:
                reasons["report_range_missing"] += 1
            elif matches[0] is None:
                reasons["report_uuid_ambiguous"] += 1
            else:
                bindings.append({"root_index": root_index, "index": index, "uuid": matches[0]})
    return bindings, reasons


def read_cache_file(path, limit):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > limit:
        raise ValueError("Cache input unavailable")
    with path.open("rb") as stream:
        payload = stream.read(limit + 1)
    if len(payload) > limit:
        raise ValueError("Cache input budget")
    return payload


def collect_terminal_cache_identity(records, terminal, grouped):
    # The old terminal is already durable. This optional work only follows exit
    # and never runs against the AX target or a report-provided executable path.
    packet = {"schema": 1, "status": "unavailable"}
    try:
        bindings, reasons = terminal_cache_bindings(grouped, terminal)
        terminal_bytes = read_cache_file(records / "terminal-snapshot.json", 65536)
    except (OSError, ValueError, TypeError, KeyError):
        pass
    else:
        try:
            # Existing terminal-grouped.txt combines stdout+stderr. Preserve the
            # exact parsed stdout separately; do not reinterpret the mixed log.
            (records / "terminal-cache-grouped.txt").write_text(grouped)
        except OSError as error:
            raise ax_system_images.ImageWorkerArtifactError() from error
        identifiers = list(dict.fromkeys(row["uuid"] for row in bindings))
        lookup = ax_system_images.shared_cache_images(identifiers, records / "terminal-image-worker.json") if identifiers else None
        packet = {"schema": 1, "status": "bound", "terminal_sha256": hashlib.sha256(terminal_bytes).hexdigest(),
                  "grouped_sha256": hashlib.sha256(grouped.encode()).hexdigest(), "bindings": bindings,
                  "reason_counts": reasons, "lookup": lookup}
    encoded = json.dumps(packet, separators=(",", ":")) + "\n"
    if len(encoded.encode()) > CACHE_RECORD_LIMIT:
        encoded = '{"schema":1,"status":"unavailable"}\n'
    try:
        (records / "terminal-cache-images.json").write_text(encoded)
    except OSError as error:
        raise ax_system_images.ImageWorkerArtifactError() from error


def recheck_terminal_cache_identity(records, terminal, cleanup_path):
    """A separate optional field; never edits the schema-3 terminal object."""
    result = terminal_cache_identity(terminal)
    try:
        packet = json.loads(read_cache_file(records / "terminal-cache-images.json", CACHE_RECORD_LIMIT),
                            object_pairs_hook=ax_system_images.unique_object)
        if type(packet) is not dict or set(packet) != {"schema", "status", "terminal_sha256", "grouped_sha256", "bindings", "reason_counts", "lookup"}:
            return result
        if type(packet["schema"]) is not int or packet["schema"] != 1 or packet["status"] != "bound":
            return result
        terminal_bytes = read_cache_file(records / "terminal-snapshot.json", 65536)
        grouped_bytes = read_cache_file(records / "terminal-cache-grouped.txt", REPORT_BYTE_LIMIT)
        if (packet["terminal_sha256"] != hashlib.sha256(terminal_bytes).hexdigest()
                or packet["grouped_sha256"] != hashlib.sha256(grouped_bytes).hexdigest()):
            return result
        original = json.loads(terminal_bytes, object_pairs_hook=ax_system_images.unique_object)
        # The earlier loaded-image fresh gate may prune only that optional field.
        def stable(value):
            value = json.loads(json.dumps(value))
            for root in value["root_groups"]:
                root.pop("other_image_identity")
            return value
        if stable(original) != stable(terminal):
            return result
        bindings, reasons = terminal_cache_bindings(grouped_bytes.decode("utf-8"), terminal)
        # JSON equality treats bool as int. Canonical bytes preserve exact types.
        canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"))
        if canonical(packet["bindings"]) != canonical(bindings) or canonical(packet["reason_counts"]) != canonical(reasons):
            return result
        identifiers = list(dict.fromkeys(row["uuid"] for row in bindings))
        lookup = packet["lookup"]
        if lookup is not None:
            if not identifiers:
                return result
            ax_system_images.validate_cache_lookup(lookup, identifiers)
        if not identifiers:
            if lookup is not None:
                return result
            result["reason_counts"] = reasons
        elif lookup is None:
            reasons["lookup_unavailable"] += len(bindings)
            result["reason_counts"] = reasons
        else:
            fresh = ax_system_images.shared_cache_images(identifiers, cleanup_path)
            if fresh is None:
                reasons["lookup_unavailable"] += len(bindings)
            elif fresh["active_cache_uuid"] != lookup["active_cache_uuid"]:
                reasons["cache_changed"] += len(bindings)
            else:
                result["active_cache_uuid"] = fresh["active_cache_uuid"]
                positions = {identifier: index for index, identifier in enumerate(identifiers)}
                for binding in bindings:
                    index = positions[binding["uuid"]]
                    before, after = lookup["result"][index], fresh["result"][index]
                    reason = before["reason"] if before["reason"] != "verified" else after["reason"]
                    if reason != "verified":
                        reasons[reason] += 1
                    elif before != after:
                        reasons["identity_changed"] += 1
                    else:
                        result["frames"].append({**binding, "basename": after["basename"]})
            result["reason_counts"] = reasons
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        return terminal_cache_identity(terminal)
    total = len(result["frames"]) + sum(result["reason_counts"].values())
    result["status"] = ("not-needed" if not total else "complete" if not sum(result["reason_counts"].values()) else
                        "partial" if result["frames"] else "unavailable")
    # Include the field's actual case nesting/indentation, not just compact JSON.
    if len(json.dumps({"trials": [{"terminal_cache_image_identity": result}]}, indent=2).encode()) > ax_system_images.CACHE_OUTPUT_LIMIT:
        return terminal_cache_identity(terminal, "output_budget")
    return result


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
