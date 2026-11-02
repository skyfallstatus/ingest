import os, unicodedata as U, sys, errno, subprocess
m=sys.argv[1]; bsd=sys.argv[2] if len(sys.argv)>2 else None
N={'NFC':'Café.bin','NFD':U.normalize('NFD','Café.bin')}
def e(f,*a):
    try: f(*a); return "ok"
    except OSError as x: return errno.errorcode[x.errno]
def p(x): return os.path.join(m,x)
def clear():
    for x in os.listdir(m):
        if x.endswith('.bin') and not x.startswith('._'):
            for f in (x,U.normalize('NFC',x)):
                if e(os.unlink,p(f))=="ok": break
def mk(n):
    fd=os.open(p(n),os.O_CREAT|os.O_WRONLY); os.write(fd,b'hello'); os.close(fd)
def lst(): return [x for x in os.listdir(m) if x.endswith('.bin') and not x.startswith('._')]
print("==",m)
for c in N:
  for o in N:
    for op in ('unlink','rename','open','remount+unlink','listdir-name unlink'):
        if op=='remount+unlink' and not bsd: continue
        clear(); mk(N[c])
        if op=='remount+unlink':
            subprocess.run(f"diskutil unmount {bsd} >/dev/null && diskutil mount nobrowse -mountPoint {m} {bsd} >/dev/null",shell=True,check=True)
        if op=='open': r=e(lambda:os.close(os.open(p(N[o]),os.O_RDONLY)))
        elif op=='rename': r=e(os.rename,p(N[o]),p('zz.bin')); e(os.unlink,p('zz.bin'))
        elif op=='listdir-name unlink':
            if o=='NFC': continue
            x=lst()[0]; r=e(os.unlink,p(x))
        else: r=e(os.unlink,p(N[o]))
        print(f"  created {c}  {op:20s} via {o}: {r:8s} remaining={len(lst())}")
clear()
