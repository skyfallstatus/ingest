#!/usr/bin/env python3
"""Writes a disk image window's .DS_Store without Finder: no AppleScript, so no automation prompt.

Usage: dmg-layout.py <mounted image> <volume name> <app bundle name>
Standard library only. Two record types do the work: Iloc places an icon, icvp sets the background, which is
named by a classic Alias record built from the mounted volume's real ids.
"""
import os, plistlib, struct, sys, time

MAC_EPOCH = 2082844800


def utf16(s):
    return s.encode("utf-16-be")


def blob(data):
    return b"blob" + struct.pack(">I", len(data)) + data


def record(name, code, value):
    return struct.pack(">I", len(utf16(name)) // 2) + utf16(name) + code + value


def alias(mount, volume, rel):
    """An Alias record, version 2, for a file on the mounted volume. Finder keeps the background through this."""
    path = os.path.join(mount, rel)
    st, vol, parent = os.stat(path), os.stat(mount), os.stat(os.path.dirname(path))
    name = os.path.basename(path)
    def pascal(s, size):
        b = s.encode("mac_roman", "replace")[: size - 1]
        return bytes([len(b)]) + b.ljust(size - 1, b"\0")
    vol_date = int(vol.st_birthtime) + MAC_EPOCH
    fixed = b"\0\0\0\0" + b"\0\0" + struct.pack(">H", 2) + struct.pack(">H", 0)
    fixed += pascal(volume, 28) + struct.pack(">I", vol_date) + b"H+" + struct.pack(">H", 5)
    fixed += struct.pack(">I", parent.st_ino) + pascal(name, 64) + struct.pack(">I", st.st_ino)
    fixed += struct.pack(">I", int(st.st_birthtime) + MAC_EPOCH) + b"\0\0\0\0" + b"\0\0\0\0"
    fixed += struct.pack(">hh", -1, -1) + struct.pack(">I", 0) + struct.pack(">H", 0) + b"\0" * 10
    def tag(t, data):
        out = struct.pack(">HH", t, len(data)) + data
        return out + (b"\0" if len(data) % 2 else b"")
    extra = tag(0, os.path.basename(os.path.dirname(path)).encode("mac_roman", "replace"))
    extra += tag(1, struct.pack(">I", parent.st_ino))
    extra += tag(2, f"{volume}:{rel.replace('/', ':')}".encode("mac_roman", "replace"))
    extra += tag(14, struct.pack(">H", len(name)) + utf16(name))
    extra += tag(15, struct.pack(">H", len(volume)) + utf16(volume))
    extra += tag(18, ("/" + rel).encode())
    extra += tag(19, f"/Volumes/{volume}".encode())
    extra += struct.pack(">HH", 0xFFFF, 0)
    data = bytearray(fixed + extra)
    data[4:6] = struct.pack(">H", len(data))
    return bytes(data)


def store(records):
    """A buddy-allocated file holding one B-tree of one leaf node, which is all a window this small needs."""
    records = sorted(records, key=lambda r: (r[0].lower(), r[1]))
    leaf = struct.pack(">II", 0, len(records)) + b"".join(record(*r) for r in records)
    assert len(leaf) <= 0x1000
    tree = struct.pack(">IIIII", 2, 0, len(records), 1, 0x1000)     # block 2 is the root node, a leaf
    # Offsets count from byte 4. Block 0 is the allocator's own, block 1 the tree's header, block 2 the leaf.
    allocator, header, node = 0x1000, 0x800, 0x2000
    addresses = [allocator | 12, header | 11, node | 12]            # an address is its offset | log2(size)
    root = struct.pack(">II", len(addresses), 0) + b"".join(struct.pack(">I", a) for a in addresses)
    root += b"\0" * ((256 - len(addresses)) * 4)
    root += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
    free = {w: [1 << w] for w in list(range(5, 11)) + list(range(14, 31))}  # every buddy that isn't used
    free[12] = [0x3000]
    for width in range(32):
        offsets = free.get(width, [])
        root += struct.pack(">I", len(offsets)) + b"".join(struct.pack(">I", o) for o in offsets)
    data = bytearray(4 + 0x4000)
    data[0:36] = struct.pack(">I", 1) + b"Bud1" + struct.pack(">III", allocator, 0x1000, allocator) + b"\0" * 16
    for offset, block in ((allocator, root), (header, tree), (node, leaf)):
        data[4 + offset:4 + offset + len(block)] = block
    return bytes(data)


def main():
    mount, volume, app = sys.argv[1:4]
    window = plistlib.dumps({"ContainerShowSidebar": False, "ShowPathbar": False, "ShowSidebar": False, "ShowStatusBar": False,
                             "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 0,
                             "WindowBounds": "{{240, 180}, {600, 488}}"}, fmt=plistlib.FMT_BINARY)
    view = plistlib.dumps({"arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0, "backgroundColorRed": 1.0,
                           "backgroundImageAlias": alias(mount, volume, ".background/background.tiff"), "backgroundType": 2,
                           "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": 128.0, "labelOnBottom": True,
                           "showIconPreview": True, "showItemInfo": False, "textSize": 13.0, "viewOptionsVersion": 1},
                          fmt=plistlib.FMT_BINARY)
    def place(x, y):
        return blob(struct.pack(">IIII", x, y, 0xFFFFFFFF, 0xFFFF0000))
    records = [(".", b"bwsp", blob(window)), (".", b"icvp", blob(view)), (".", b"vSrn", b"long" + struct.pack(">I", 1)),
               (app, b"Iloc", place(170, 220)), ("Applications", b"Iloc", place(430, 220)), ("Read Me First.txt", b"Iloc", place(300, 375))]
    with open(os.path.join(mount, ".DS_Store"), "wb") as f:
        f.write(store(records))
    now = time.time()
    os.utime(mount, (now, now))


main()
