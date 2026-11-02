# Test-only: smallest possible ASC MHL writer, to prove hand-writing is feasible.
import os, sys, hashlib, datetime, socket, xxhash, unicodedata
from xml.sax.saxutils import escape
root = sys.argv[1]; proc = sys.argv[2] if len(sys.argv) > 2 else "transfer"
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def c4(data):
    n = int.from_bytes(hashlib.sha512(data).digest(), "big"); s = ""
    while n: n, r = divmod(n, 58); s = B58[r] + s
    return "c4" + s.rjust(88, "1")
now = datetime.datetime.now().astimezone().replace(microsecond=0)
stamp = now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%d_%H%M%SZ")
rows = []
for d, dirs, files in os.walk(root):
    dirs[:] = sorted(x for x in dirs if x != "ascmhl")
    for f in sorted(files):
        if f == ".DS_Store": continue
        p = os.path.join(d, f); rel = os.path.relpath(p, root)
        h = xxhash.xxh64()
        with open(p, "rb") as fh:
            while (b := fh.read(1 << 20)): h.update(b)
        st = os.stat(p)
        mt = datetime.datetime.fromtimestamp(int(st.st_mtime)).astimezone().isoformat()
        rows.append(f'    <hash>\n      <path size="{st.st_size}" lastmodificationdate="{mt}">{escape(rel)}</path>\n'
                    f'      <xxh64 action="original" hashdate="{now.isoformat()}">{h.hexdigest()}</xxh64>\n    </hash>\n')
xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">\n  <creatorinfo>\n'
       f'    <creationdate>{now.isoformat()}</creationdate>\n    <hostname>{escape(socket.gethostname())}</hostname>\n'
       '    <tool version="0.1">card-ingest-test</tool>\n  </creatorinfo>\n  <processinfo>\n'
       f'    <process>{proc}</process>\n  </processinfo>\n  <hashes>\n' + "".join(rows) + '  </hashes>\n</hashlist>\n').encode("utf-8")
folder = os.path.basename(os.path.normpath(root))
name = f"0001_{folder}_{stamp}.mhl"; dest = os.path.join(root, "ascmhl"); os.makedirs(dest)
open(os.path.join(dest, name), "wb").write(xml)
chain = ('<?xml version="1.0" encoding="UTF-8"?>\n<ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">\n'
         f'  <hashlist sequencenr="1">\n    <path>{escape(name)}</path>\n    <c4>{c4(xml)}</c4>\n  </hashlist>\n</ascmhldirectory>\n').encode()
open(os.path.join(dest, "ascmhl_chain.xml"), "wb").write(chain)
print(name)
