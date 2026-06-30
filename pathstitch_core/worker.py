"""Persistent Pathstitch geometry worker.

A long-lived process that replaces the old per-operation `python -m ...` spawn.
The Swift `PythonBridge` launches one of these per app session and streams
requests to it over stdin/stdout, so the heavy `ezdxf` / `shapely` / `OCC`
imports are paid **once** at startup instead of on every operation (the main
loading-screen cause). See AGENTS.md (Rule 11).

Wire protocol — length-prefixed frames, both directions:

    [4 bytes big-endian uint32 length][<length> bytes of UTF-8 JSON]

Request JSON:   {"id": <int>, "module": "dxf_ops"|"step_ops", "op": <str>, "args": {...}}
Response JSON:  {"id": <int>, "status": "ok"|"error", ...}

The JSON payload is intentionally the same shape the CLI used, so swapping the
codec for MessagePack later (Stage 2) is a localized change to framing only.
"""
import sys
import json
import struct

# `dxf_ops` is comparatively light and used by nearly every request, so import
# it eagerly; the first op should be instant. `step_ops` pulls in OpenCASCADE,
# so it is imported lazily on first use (see `_get_operations`).
from pathstitch_core import dxf_ops

_MODULES = {"dxf_ops": dxf_ops.OPERATIONS}


def _get_operations(module):
    """Returns a module's op dispatch table, importing the module lazily."""
    if module in _MODULES:
        return _MODULES[module]
    if module == "step_ops":
        from pathstitch_core import step_ops
        _MODULES[module] = step_ops.OPERATIONS
        return _MODULES[module]
    if module == "jig_ops":
        from pathstitch_core import jig_ops
        _MODULES[module] = jig_ops.OPERATIONS
        return _MODULES[module]
    if module == "construct_ops":
        from pathstitch_core import construct_ops
        _MODULES[module] = construct_ops.OPERATIONS
        return _MODULES[module]
    if module == "manufacture_ops":
        from pathstitch_core import manufacture_ops
        _MODULES[module] = manufacture_ops.OPERATIONS
        return _MODULES[module]
    return None


def _read_exact(stream, n):
    """Reads exactly `n` bytes from `stream`, or returns None on EOF."""
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def _write_frame(stream, obj):
    payload = json.dumps(obj).encode("utf-8")
    stream.write(struct.pack(">I", len(payload)))
    stream.write(payload)
    stream.flush()


def _dispatch(module, op, args):
    ops = _get_operations(module)
    if ops is None:
        return {"status": "error", "message": f"Unknown module: {module}"}
    fn = ops.get(op)
    if fn is None:
        return {"status": "error", "message": f"Unknown operation: {op}"}
    return fn(args)


def serve():
    # The frame channel is the *real* stdout. We must guarantee nothing else ever
    # writes a single byte to it, or the length-prefixed frames get corrupted and
    # the Swift side reads a bogus length and hangs forever (the STEP-import
    # "infinite processing" bug). A Python-level `print()` is the obvious risk, but
    # the subtler one is native C++ libraries: OpenCASCADE's STEP writer dumps a
    # "Statistics on Transfer" banner straight to file descriptor 1, bypassing
    # Python's sys.stdout entirely. So redirect at the OS level: dup the real
    # stdout to a private fd used *only* for frames, then point fd 1 (and
    # sys.stdout) at stderr so every stray write — Python or native — is harmless.
    import os
    real_stdout_fd = os.dup(1)
    os.dup2(2, 1)            # fd 1 now goes to stderr → OCC/C++ output can't corrupt frames
    frame_out = os.fdopen(real_stdout_fd, "wb")
    sys.stdout = sys.stderr
    frame_in = sys.stdin.buffer

    while True:
        header = _read_exact(frame_in, 4)
        if header is None:
            break  # stdin closed → the app is shutting us down; exit cleanly.
        (length,) = struct.unpack(">I", header)
        payload = _read_exact(frame_in, length)
        if payload is None:
            break

        req_id = None
        try:
            req = json.loads(payload.decode("utf-8"))
            req_id = req.get("id")
            result = _dispatch(req.get("module"), req.get("op"), req.get("args", {}))
            if not isinstance(result, dict):
                result = {"status": "error", "message": "Operation returned a non-dict result."}
        except Exception as e:
            # An op raising must never take the worker down — report and continue.
            result = {"status": "error", "message": f"Worker error: {e}"}

        result["id"] = req_id
        try:
            _write_frame(frame_out, result)
        except Exception:
            break  # stdout closed → nothing more we can do.


if __name__ == "__main__":
    serve()
