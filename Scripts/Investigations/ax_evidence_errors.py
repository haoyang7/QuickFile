"""Shared failures for script and imported AX evidence collectors."""


class EvidenceError(Exception):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


class ExitUnconfirmed(EvidenceError):
    def __init__(self):
        super().__init__("process_exit_unconfirmed")
