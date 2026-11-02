import os, sys, unicodedata as U, errno, time, ctypes
def mk(m, name):
    p = os.path.join(m, name)
    try:
        fd = os.open(p, os.O_CREAT|os.O_WRONLY|os.O_EXCL, 0o644); os.close(fd); return "ok"
    except OSError as e: return errno.errorcode.get(e.errno, str(e.errno))
def rm(m,x):
    for f in (x, U.normalize('NFC', x)):
        try: os.unlink(os.path.join(m, f)); return
        except OSError: pass
def lsnames(m): return set(os.listdir(m))
for m in sys.argv[1:]:
    print("==", m)
    # illegal characters
    res = {}
    for ch in ['\\', ':', '*', '?', '"', '<', '>', '|', '\x01', '\x1f', '\x7f', '/']:
        n = "x" + ch + "y.txt"
        if ch == '/': continue
        r = mk(m, n); ls = [x for x in lsnames(m) if x.startswith("x") and x.endswith("y.txt")]
        res[repr(ch)] = (r, [ascii(x) for x in ls])
        for x in ls:
            rm(m,x)
    for k, v in res.items(): print("  char", k, v)
    # trailing dot/space, leading space, reserved names
    for n in ["trail.", "trail ", " lead", "CON", "AUX.txt", "nul", "a."]:
        r = mk(m, n); ls = [ascii(x) for x in lsnames(m) if x.strip(". ").lower() in (n.strip(". ").lower(),)]
        print("  name", repr(n), r, ls)
        for x in lsnames(m):
            if x.strip(". ").lower() == n.strip(". ").lower(): rm(m,x)
    # length limits
    for L in (255, 256):
        n = "a" * L; print("  len ascii", L, mk(m, n)); 
        rm(m,n[:255])
    for L, c, lbl in ((127, "\U0001F3AC", "emoji(2 UTF-16 units, 4 UTF-8 bytes)"), (128, "\U0001F3AC", "emoji"), (85, "é", "é NFC (2 UTF-8 bytes)"), (127,"é","é NFC 254 bytes"), (128,"é","é NFC 256 bytes"), (255,"é","é NFC 510 bytes"), (256,"é","é 512 bytes")):
        n = c * L
        try:
            r = mk(m, n)
        except Exception as e: r = repr(e)
        print(f"  len {lbl} x{L} utf8={len(n.encode())} utf16={len(n.encode('utf-16-le'))//2}:", r)
        for x in list(lsnames(m)):
            if x.startswith(c) or x.startswith(U.normalize('NFD', c)):
                rm(m,x)
    # deep path
    # case
    r1 = mk(m, "CaseFile.MOV"); r2 = mk(m, "casefile.mov"); print("  case: create", r1, "again-lower", r2, "exists(lower)", os.path.exists(os.path.join(m, "casefile.mov")), [x for x in lsnames(m) if x.lower()=="casefile.mov"])
    rm(m,"CaseFile.MOV")
    r1 = mk(m, "É.mov"); r2 = mk(m, "é.mov"); print("  case-nonascii: É then é:", r1, r2, [ascii(x) for x in lsnames(m) if x.endswith(".mov")])
    for x in lsnames(m):
        if x.endswith(".mov"): rm(m,x)
    print("  (skip Ǆ/ß probes)")
    for x in lsnames(m):
        if x.endswith(".mov"): rm(m,x)
    # normalization
    nfc = "Café.mov"; nfd = U.normalize("NFD", nfc)
    print("  create NFC:", mk(m, nfc)); ls = [x for x in lsnames(m) if x.endswith(".mov")]
    print("    readdir form:", [("NFC" if U.is_normalized("NFC", x) else "") + ("/NFD" if U.is_normalized("NFD", x) else "") for x in ls], [ascii(x) for x in ls])
    print("    open via NFD finds it:", os.path.exists(os.path.join(m, nfd)), " create NFD on top:", mk(m, nfd)); ls = [x for x in lsnames(m) if x.endswith(".mov")]; print("    entries now:", [ascii(x) for x in ls])
    for x in ls:
        rm(m,x)
    print("  create NFD:", mk(m, nfd)); ls = [x for x in lsnames(m) if x.endswith(".mov")]
    print("    readdir form:", [("NFC" if U.is_normalized("NFC", x) else "") + ("/NFD" if U.is_normalized("NFD", x) else "") for x in ls], [ascii(x) for x in ls])
    print("    open via NFC finds it:", os.path.exists(os.path.join(m, nfc)))
    for x in ls:
        rm(m,x)
