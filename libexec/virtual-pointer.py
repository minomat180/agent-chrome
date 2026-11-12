#!/usr/bin/env python3
"""Hold a virtual pointer device on a wlroots compositor for as long as we run.

A headless cage has no input devices, so Chrome reports `(any-pointer: none)`
and `(hover: none)`: a desktop browser without a mouse. That is both a
fingerprint ("headless default") and a functional problem, because sites that
branch on `(hover: hover)` / `(pointer: fine)` serve their touch layout.

This client binds zwlr_virtual_pointer_manager_v1, creates one virtual pointer
and then just keeps the connection open. The device disappears when the client
exits, which is why a one-shot `wlrctl pointer move` does not help.

Speaks the Wayland wire protocol directly so it has no dependencies.
usage: virtual-pointer.py [WAYLAND_DISPLAY]   (default: $WAYLAND_DISPLAY)
"""
import os, socket, struct, sys

def main():
    name = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("WAYLAND_DISPLAY")
    if not name:
        sys.exit("virtual-pointer: no WAYLAND_DISPLAY")
    path = name if name.startswith("/") else os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), name)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)

    def send(obj, opcode, payload=b""):
        s.sendall(struct.pack("<IHH", obj, opcode, 8 + len(payload)) + payload)

    def wl_string(text):
        raw = text.encode() + b"\0"
        return struct.pack("<I", len(raw)) + raw + b"\0" * (-len(raw) % 4)

    buf = b""
    def events():
        nonlocal buf
        while True:
            while len(buf) >= 8:
                obj, opcode, size = struct.unpack_from("<IHH", buf)
                if len(buf) < size:
                    break
                body, buf = buf[8:size], buf[size:]
                yield obj, opcode, body
            chunk = s.recv(65536)
            if not chunk:
                return
            buf += chunk

    REGISTRY, CALLBACK, MANAGER, POINTER = 2, 3, 4, 5
    send(1, 1, struct.pack("<I", REGISTRY))   # wl_display.get_registry
    send(1, 0, struct.pack("<I", CALLBACK))   # wl_display.sync
    manager = None
    for obj, opcode, body in events():
        if obj == REGISTRY and opcode == 0:   # wl_registry.global
            gname, slen = struct.unpack_from("<II", body)
            iface = body[8:8 + slen - 1].decode()
            version = struct.unpack_from("<I", body, 8 + slen + (-slen % 4))[0]
            if iface == "zwlr_virtual_pointer_manager_v1":
                manager = (gname, iface, min(version, 2))
        elif obj == CALLBACK:                 # sync done: registry is complete
            break
    if not manager:
        sys.exit("virtual-pointer: compositor has no zwlr_virtual_pointer_manager_v1")
    gname, iface, version = manager
    send(REGISTRY, 0, struct.pack("<I", gname) + wl_string(iface) + struct.pack("<II", version, MANAGER))  # bind
    send(MANAGER, 0, struct.pack("<II", 0, POINTER))   # create_virtual_pointer(seat=null)
    # One motion + frame so the seat definitely announces the capability.
    send(POINTER, 0, struct.pack("<Iii", 0, 256, 256)) # motion(time, dx, dy) as wl_fixed
    send(POINTER, 4)                                   # frame
    print("virtual-pointer: holding device on", name, flush=True)
    for _ in events():                                 # block until the compositor goes away
        pass

if __name__ == "__main__":
    main()
