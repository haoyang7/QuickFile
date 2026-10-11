"""Bounded lexical evidence for parser failures and candidate baseline traces.

Unknown text loses its meaning. Decoding reproduces allowlisted syntax and stable
anonymous identities for local experiments; it cannot recover original text.
"""
import json
import re

from ax_probe_report import HEAP_LABELS, HEAP_TYPES

EVIDENCE_LIMIT = 2 * 1024 * 1024
DOCUMENT_LIMIT = 34
LINE_LIMIT = 4096
LINE_LENGTH_LIMIT = 16384
TOKEN_LIMIT = 65536
IDENTITY_LIMIT = 200000
INTEGER_LIMIT = 1_000_000_000
# Only literal, reviewed vocabulary may leave the private report directory.
WORDS = frozenset(("Thread", *(f"x{i}" for i in range(31)))) | frozenset(re.findall(r"[A-Za-z_][A-Za-z_0-9]*", " ".join(HEAP_TYPES) + " " + """
Process leak leaks for total leaked bytes STACK OF INSTANCE INSTANCES ROOT CYCLE LEAK
BACK TO TOTAL Binary Images Protocol Connection NSXPCInterface xpc_connection_t
 dispatch_mach_t __NSMallocBlock__ CFDictionary Value Storage Key NSSet
 dispatch_queue_t serial dispatch_group_t unknown NSAccessibilityRemoteUIElement
 NSAccessibilityRemoteUIElementProtocol LNDaemonApplicationInterface _connection
 _remoteObjectInterface _methodInfo list __strong __weak capture __block _object
 storage _values _userQueue _exportInfo _replyGroup _importInfo _interruptionHandler
 _repliesRequested _dCache _eCache _repliesExpected Tracing Found root roots referencing
This is a reverse reference tree showing how the specified block is referenced
The top node is the specified block the next level down are blocks that reference that and so on
The number at the start of each line is the number of paths to roots going through that node
This reverse reference tree can be imported into Instruments using Import Sample Data to allow data mining
Region Stack __DATA Kernel Pointers Into User Space offset
Swift Metadata metadata calloc in _dispatch_continuation_alloc_from_heap
_dispatch_malloc_continuation_alloc _dispatch_alloc_continuation_alloc _dispatch_async_f_slow
"""))
# Path separators stay inside opaque lexemes, even when every component is allowlisted.
PUNCT = frozenset('<>[]():;,+-=>.!|\'"{}*?&%#@~`^$─│├└┌┐┘┬┴┼→←↳')
LEX = re.compile(r"[ \t]+|[" + re.escape("".join(sorted(PUNCT))) + r"]|[^ \t" + re.escape("".join(sorted(PUNCT))) + r"]+")
ADDRESS = r"0x[0-9a-fA-F]{1,16}"
ERROR_TEXT = (
    "Missing unique leak totals", "Invalid leak totals", "Tree/list totals differ",
    "Unsupported tree header", "Unparsed tree prefix", "Missing tree boundary",
    "Unsupported ungrouped tree", "Missing tree", "Incomplete subtree", "Unsupported tree row",
    "Unsupported edge syntax", "Counted back edge", "Unbound cycle back edge",
    "Contradictory back edge", "Uncounted tree node", "Duplicate or unlisted tree node",
    "Root/header mismatch", "Root instance count mismatch", "Incomplete tree membership",
    "Unsupported object description", "Invalid object", "Unsupported object suffix",
    "Unbound trace result", "Unsupported trace preamble", "Trace path count mismatch",
    "Incomplete trace root", "Unsupported trace row", "Invalid trace paths", "Unsupported region",
    "Unsupported reverse object", "Unbound reference slot", "Unsupported reference label",
    "Missing reverse reference slot", "Conflicting trace object", "Unbound trace tree",
    "Invalid reverse nesting", "Missing trace tree",
)
ERROR_CODES = {message: message.lower().replace("/", "_").replace(" ", "_") for message in ERROR_TEXT}
ERRORS = frozenset((*ERROR_CODES.values(), "other_parser_error", "none"))


def encode_evidence(value):
    return (json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")


def _int(value, limit=INTEGER_LIMIT, minimum=0):
    return type(value) is int and minimum <= value <= limit


def validate_evidence(value):
    """Reject arbitrary fields, strings and out-of-bound public evidence."""
    def require(ok):
        if not ok:
            raise ValueError("Invalid parser evidence")
    def pair(item):
        return (type(item) is list and len(item) == 2 and _int(item[0], IDENTITY_LIMIT, 1)
                and _int(item[1], minimum=1))
    require(type(value) is dict and set(value) == {"schema", "status", "documents", "omitted_documents"})
    require(type(value["schema"]) is int and value["schema"] == 1)
    require(value["status"] in ("complete", "truncated"))
    require(_int(value["omitted_documents"]) and type(value["documents"]) is list and len(value["documents"]) <= DOCUMENT_LIMIT)
    indices = set()
    for doc in value["documents"]:
        require(type(doc) is dict and set(doc) == {"tool", "label", "tool_index", "graph_sha256", "error", "status", "lines", "nodes", "target"})
        require(doc["tool"] in ("tree", "trace") and doc["label"] in HEAP_LABELS)
        require(_int(doc["tool_index"], 127) and doc["tool_index"] not in indices)
        indices.add(doc["tool_index"])
        require(type(doc["graph_sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", doc["graph_sha256"]) is not None)
        require(type(doc["error"]) is str and doc["error"] in ERRORS and doc["status"] in ("complete", "truncated"))
        require(doc["error"] != "none" or (doc["tool"] == "trace" and doc["label"] == "baseline"))
        require(type(doc["nodes"]) is list and len(doc["nodes"]) <= 100000 and all(pair(item) for item in doc["nodes"]))
        require(len({item[0] for item in doc["nodes"]}) == len(doc["nodes"]))
        require((doc["tool"] == "tree" and doc["target"] is None) or (doc["tool"] == "trace" and not doc["nodes"] and pair(doc["target"])))
        require(type(doc["lines"]) is list and len(doc["lines"]) <= LINE_LIMIT)
        count = 0
        for line in doc["lines"]:
            require(type(line) is list)
            count += len(line)
            require(count <= TOKEN_LIMIT)
            width = 0
            for token in line:
                require(type(token) is list and len(token) in (2, 3) and type(token[0]) is str)
                tag = token[0]
                if tag == "slot":
                    require(len(token) == 3 and _int(token[1], IDENTITY_LIMIT, 1) and _int(token[2]))
                    width += 1
                else:
                    require(len(token) == 2)
                    item = token[1]
                    if tag == "word":
                        require(type(item) is str and item in WORDS)
                        width += 1
                    elif tag == "punct":
                        require(type(item) is str and item in PUNCT)
                        width += 1
                    elif tag in ("space", "tab"):
                        require(_int(item, LINE_LENGTH_LIMIT, 1))
                        width += item
                    elif tag in ("address", "opaque"):
                        require(_int(item, IDENTITY_LIMIT, 1))
                        width += 1
                    elif tag == "number":
                        require(_int(item))
                        width += 1
                    elif tag == "pid":
                        require(type(item) is int and item == 0)
                        width += 1
                    else:
                        require(False)
            require(width <= LINE_LENGTH_LIMIT + 32)
    require(value["status"] == ("truncated" if value["omitted_documents"] or any(doc["status"] == "truncated" for doc in value["documents"]) else "complete"))
    require(len(encode_evidence(value)) <= EVIDENCE_LIMIT)
    return value


def thread_register(text):
    """Recognize only the bounded ARM64 register terminal syntax."""
    match = re.fullmatch(r"Thread ([0-9]{1,10})( +)([^\r\n\t]{1,1024}?)( +)\$(x(?:[0-9]|[12][0-9]|30))", text)
    if (match and int(match[1]) <= INTEGER_LIMIT and match[3].strip()
            and match[3].isprintable()):
        return match
    return None


def _numbers(line):
    """Exact lexical contexts, independent of whether a graph parses."""
    spans = set()
    patterns = (
        r"^Process \d+: (\d+) leaks? for (\d+) total leaked bytes\.$",
        r"^STACK OF (\d+) INSTANCES? OF ",
        r"^[ +!:|]*(\d+) (?=\(|<|0x|Region |Kernel |Thread )",
        r"^Found (\d+) roots? referencing:",
        r"(?:0x[0-9a-fA-F]{1,16}>?) \[(\d+)\]",
        r"\] +\+(\d+):",
        # Preserve structural offsets even when the formatter omits address/size.
        # This does not make an unknown root acceptable to the graph parser.
        r"^[ +!:|]*\d+ <[^<>\n]+> +\+(\d+):",
        r"--> offset (\d+)(?:$| )",
        r"\] +\+\d+: [^\n]*? \+ (\d+) 0x[0-9a-fA-F]{1,16}(?: --> offset \d+)?$",
    )
    for pattern in patterns:
        for match in re.finditer(pattern, line):
            spans.update(match.span(index) for index in range(1, len(match.groups()) + 1))
    return spans


class Collector:
    def __init__(self):
        self.value = {"schema": 1, "status": "complete", "documents": [], "omitted_documents": 0}
        self.addresses, self.opaque, self.threads = {}, {}, {}

    @staticmethod
    def _id(mapping, raw):
        if raw not in mapping:
            if len(mapping) >= IDENTITY_LIMIT:
                raise OverflowError
            mapping[raw] = len(mapping) + 1
        return mapping[raw]

    def record(self, tool, label, tool_index, graph_sha256, report, error, nodes=None, target=None):
        if len(self.value["documents"]) >= DOCUMENT_LIMIT:
            self.value["omitted_documents"] += 1
            self.value["status"] = "truncated"
            return
        doc = {"tool": tool, "label": label, "tool_index": tool_index, "graph_sha256": graph_sha256,
               "error": "none" if error is None else ERROR_CODES.get(str(error), "other_parser_error"), "status": "complete",
               "lines": [], "nodes": [], "target": None}
        try:
            doc["nodes"] = [[self._id(self.addresses, address), size] for address, size in (nodes or {}).items()]
            if target is not None:
                doc["target"] = [self._id(self.addresses, target[0]), target[1]]
            count = 0
            for line_index, line in enumerate(report.splitlines()):
                if line_index >= LINE_LIMIT or len(line) > LINE_LENGTH_LIMIT:
                    doc["status"] = "truncated"
                    break
                numbers = _numbers(line)
                # Replace the whole private display field, including any names,
                # paths, numbers or addresses, only after exact syntax recognition.
                thread_row = re.fullmatch(r"([ +!:|]+)([0-9]{1,10}) (Thread .+?) *", line)
                thread = thread_register(thread_row[3]) if thread_row else None
                replacements = {}
                if thread:
                    start = thread_row.start(3)
                    replacements[start + thread.start(1)] = (
                        start + thread.end(1), ["number", self._id(self.threads, int(thread[1]))])
                    replacements[start + thread.start(3)] = (
                        start + thread.end(3), ["opaque", self._id(self.opaque, thread[3])])
                pid = re.match(r"^Process (\d+):", line)
                # Preserve an actual base+offset relation only after private equality checking.
                slots = {}
                slot = re.search(r"(" + ADDRESS + r")>? \[\d+\] +\+(\d+):.*? (" + ADDRESS + r")(?: --> offset \d+)?$", line)
                if slot and len(slot[2]) <= 10 and int(slot[2]) <= INTEGER_LIMIT and int(slot[1], 16) + int(slot[2]) == int(slot[3], 16):
                    slots[slot.span(3)] = ["slot", self._id(self.addresses, int(slot[1], 16)), int(slot[2])]
                tokens = []
                replaced_until = -1
                for match in LEX.finditer(line):
                    if match.start() < replaced_until:
                        continue
                    raw = match[0]
                    if match.start() in replacements:
                        replaced_until, token = replacements[match.start()]
                    elif match.span() in slots:
                        token = slots[match.span()]
                    elif raw.isspace() and set(raw) <= {" ", "\t"}:
                        # Keep mixed whitespace order rather than expanding to columns.
                        for run in re.finditer(r" +|\t+", raw):
                            tokens.append(["space" if run[0][0] == " " else "tab", len(run[0])])
                        continue
                    elif raw in PUNCT:
                        token = ["punct", raw]
                    elif pid and match.span() == pid.span(1):
                        token = ["pid", 0]
                    elif match.span() in numbers and raw.isascii() and raw.isdigit() and len(raw) <= 10 and int(raw) <= INTEGER_LIMIT:
                        token = ["number", int(raw)]
                    elif re.fullmatch(ADDRESS, raw):
                        token = ["address", self._id(self.addresses, int(raw, 16))]
                    elif raw in WORDS:
                        token = ["word", raw]
                    else:
                        token = ["opaque", self._id(self.opaque, raw)]
                    tokens.append(token)
                count += len(tokens)
                if count > TOKEN_LIMIT:
                    doc["status"] = "truncated"
                    break
                doc["lines"].append(tokens)
        except OverflowError:
            doc["status"] = "truncated"
        self.value["documents"].append(doc)
        # Bound the canonical bytes, including metadata and the complete list.
        if len(encode_evidence(self.value)) > EVIDENCE_LIMIT:
            doc["status"] = "truncated"
            while doc["lines"] and len(encode_evidence(self.value)) > EVIDENCE_LIMIT:
                del doc["lines"][len(doc["lines"]) // 2:]
            if len(encode_evidence(self.value)) > EVIDENCE_LIMIT:
                self.value["documents"].pop()
                self.value["omitted_documents"] += 1
        if doc["status"] == "truncated":
            self.value["status"] = "truncated"
        # Status can add one byte; leave a small margin at the cap.
        if len(encode_evidence(self.value)) > EVIDENCE_LIMIT - 64:
            self.value["documents"].pop()
            self.value["omitted_documents"] += 1
            self.value["status"] = "truncated"


def fake_address(identity):
    return identity * (1 << 40)


def decode_document(doc):
    """Return (report, anonymous_nodes, anonymous_target); opaque meaning is lost."""
    def decode(token):
        tag, item = token[:2]
        if tag in ("word", "punct"):
            return item
        if tag in ("space", "tab"):
            return (" " if tag == "space" else "\t") * item
        if tag == "pid":
            return "1"
        if tag == "number":
            return str(item)
        if tag in ("address", "slot"):
            return hex(fake_address(item) + (token[2] if tag == "slot" else 0))
        return "opaque" + str(item)
    report = "\n".join("".join(decode(token) for token in line) for line in doc["lines"]) + "\n"
    nodes = {fake_address(identity): size for identity, size in doc["nodes"]}
    target = None if doc["target"] is None else (fake_address(doc["target"][0]), doc["target"][1])
    return report, nodes, target
