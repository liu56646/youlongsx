"""Restore windows with closed ColorBuffers detached instead of dereferencing null."""
from pathlib import Path
import sys

source = Path(sys.argv[1]) / "host/gl/EmulatedEglWindowSurface.cpp"
s = source.read_text()
marker = "VMHOST_SNAP_CLOSED_WINDOW"
if marker not in s:
    old = """        assert(colorBufferRef);
        surface->mAttachedColorBuffer = colorBufferRef->cb;"""
    new = """        // VMHOST_SNAP_CLOSED_WINDOW: a stale window can reference a closed buffer.
        // Preserve the window handle, but leave it detached until the guest attaches one.
        if (colorBufferRef) {
            surface->mAttachedColorBuffer = colorBufferRef->cb;
        } else {
            fprintf(stderr, "VMHOSTSNAP window=%u detached closed colorBuffer=%u drawCtx=%u readCtx=%u\\n",
                    hndl, colorBufferHndl, drawCtx, readCtx);
        }"""
    if s.count(old) != 1:
        raise ValueError("WindowSurface ColorBuffer load anchor missing or ambiguous")
    source.write_text(s.replace(old, new, 1))
