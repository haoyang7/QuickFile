"""Share immutable debug fixture modules within one script-test process."""
import atexit
from functools import lru_cache
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


@lru_cache(maxsize=1)
def shared_native_modules():
    # Each process builds current sources afresh. Keep the libraries alive after
    # individual TestCase classes clean up their own executables and fixture data.
    parent = ROOT / ".build" / "Temporary"
    parent.mkdir(parents=True, exist_ok=True)
    temporary = tempfile.TemporaryDirectory(prefix="script-test-modules-", dir=parent)
    try:
        subprocess.run([
            sys.executable, str(ROOT / "Scripts/Investigations/build-ui-recovery.py"),
            "--modules-only", "--output", temporary.name,
        ], check=True, capture_output=True, text=True, timeout=240, cwd=ROOT)
    except BaseException:
        temporary.cleanup()
        raise
    atexit.register(temporary.cleanup)
    return Path(temporary.name)
