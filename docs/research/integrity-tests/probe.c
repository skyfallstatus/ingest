// probe.c - per-volume fcntl/rename/timestamps/name probes (test images only)
#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/time.h>
#include <sys/mount.h>
#include <sys/xattr.h>
#include <sys/param.h>
#include <sys/vnode.h>
#include <sys/clonefile.h>
#include <stdio.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void R(const char*what,int rc){printf("  %-46s rc=%d%s%s\n",what,rc,rc<0?" ":"",rc<0?strerror(errno):"");}
int main(int ac,char**av){const char*m=av[1];char p[1024],q[1024];
  struct statfs sf;statfs(m,&sf);printf("== %s fstype=%s fsubtype=%u iosize=%u bsize=%u\n",m,sf.f_fstypename,sf.f_fssubtype,sf.f_iosize,sf.f_bsize);
  snprintf(p,sizeof p,"%s/p.bin",m);unlink(p);int fd=open(p,O_CREAT|O_RDWR,0644);
  // preallocation
  fstore_t fs={F_ALLOCATECONTIG|F_ALLOCATEALL,F_PEOFPOSMODE,0,64*1024*1024,0};double t=now();int rc=fcntl(fd,F_PREALLOCATE,&fs);printf("  F_PREALLOCATE contig|all 64MiB rc=%d %s bytesalloc=%lld %.2fms\n",rc,rc?strerror(errno):"",(long long)fs.fst_bytesalloc,(now()-t)*1e3);
  struct stat st;fstat(fd,&st);printf("    after prealloc st_size=%lld st_blocks=%lld\n",st.st_size,st.st_blocks);
  rc=ftruncate(fd,64*1024*1024);R("ftruncate to 64MiB",rc);fstat(fd,&st);printf("    after ftruncate st_size=%lld st_blocks=%lld\n",st.st_size,st.st_blocks);
  // holes? read back zeros at 32MiB
  char z[4096];memset(z,1,4096);ssize_t n=pread(fd,z,4096,32*1024*1024);int nz=0;for(int i=0;i<4096;i++)nz+=z[i]!=0;printf("    pread hole n=%zd nonzero=%d\n",n,nz);
  t=now();rc=ftruncate(fd,1024*1024);printf("  ftruncate down rc=%d %.2fms\n",rc,(now()-t)*1e3);
  fstore_t f2={F_ALLOCATEALL,F_PEOFPOSMODE,0,8*1024*1024,0};rc=fcntl(fd,F_PREALLOCATE,&f2);printf("  F_PREALLOCATE all 8MiB rc=%d %s alloc=%lld\n",rc,rc?strerror(errno):"",(long long)f2.fst_bytesalloc);
  fstore_t f3={F_ALLOCATEALL,F_PEOFPOSMODE,0,(off_t)1<<40,0};rc=fcntl(fd,F_PREALLOCATE,&f3);printf("  F_PREALLOCATE 1TiB (over free) rc=%d %s alloc=%lld\n",rc,rc?strerror(errno):"",(long long)f3.fst_bytesalloc);
  // sync family on file
  write(fd,"x",1);
  t=now();rc=fsync(fd);printf("  fsync(file) rc=%d %.2fms\n",rc,(now()-t)*1e3);
  t=now();rc=fcntl(fd,F_BARRIERFSYNC);printf("  F_BARRIERFSYNC(file) rc=%d %s %.2fms\n",rc,rc?strerror(errno):"",(now()-t)*1e3);
  t=now();rc=fcntl(fd,F_FULLFSYNC);printf("  F_FULLFSYNC(file) rc=%d %s %.2fms\n",rc,rc?strerror(errno):"",(now()-t)*1e3);
  // log2phys
  struct log2phys lp={0};lp.l2p_contigbytes=1024*1024;lp.l2p_devoffset=0;rc=fcntl(fd,F_LOG2PHYS_EXT,&lp);printf("  F_LOG2PHYS_EXT rc=%d %s contig=%lld devoff=%lld\n",rc,rc?strerror(errno):"",lp.l2p_contigbytes,lp.l2p_devoffset);
  struct radvisory ra={0,1024*1024};rc=fcntl(fd,F_RDADVISE,&ra);R("F_RDADVISE",rc);
  close(fd);
  // directory fsync
  int dfd=open(m,O_RDONLY);
  t=now();rc=fsync(dfd);printf("  fsync(dir) rc=%d %s %.2fms\n",rc,rc?strerror(errno):"",(now()-t)*1e3);
  t=now();rc=fcntl(dfd,F_FULLFSYNC);printf("  F_FULLFSYNC(dir) rc=%d %s %.2fms\n",rc,rc?strerror(errno):"",(now()-t)*1e3);
  t=now();rc=fcntl(dfd,F_BARRIERFSYNC);printf("  F_BARRIERFSYNC(dir) rc=%d %s %.2fms\n",rc,rc?strerror(errno):"",(now()-t)*1e3);
  // read-only fd variants
  int rfd=open(p,O_RDONLY);t=now();rc=fcntl(rfd,F_FULLFSYNC);printf("  F_FULLFSYNC(read-only fd) rc=%d %s %.2fms\n",rc,rc?strerror(errno):"",(now()-t)*1e3);close(rfd);
  // volume sync without fd
  // rename variants
  snprintf(q,sizeof q,"%s/p2.bin",m);unlink(q);
  int f=open(q,O_CREAT|O_WRONLY,0644);close(f);
  rc=renamex_np(p,q,RENAME_EXCL);printf("  renamex_np(RENAME_EXCL) onto existing rc=%d %s\n",rc,rc?strerror(errno):"");
  rc=renameatx_np(AT_FDCWD,p,AT_FDCWD,q,RENAME_SWAP);printf("  RENAME_SWAP rc=%d %s\n",rc,rc?strerror(errno):"");
  rc=rename(p,q);R("rename over existing",rc);
  snprintf(p,sizeof p,"%s/clone.bin",m);rc=clonefile(q,p,0);printf("  clonefile rc=%d %s\n",rc,rc?strerror(errno):"");unlink(p);unlink(q);
  // volume capabilities
  struct attrlist al={0};al.bitmapcount=ATTR_BIT_MAP_COUNT;al.volattr=ATTR_VOL_INFO|ATTR_VOL_CAPABILITIES;struct{uint32_t l;vol_capabilities_attr_t c;}__attribute__((packed)) b;
  if(getattrlist(m,&al,&b,sizeof b,0)==0){uint32_t fmt=b.c.capabilities[VOL_CAPABILITIES_FORMAT]&b.c.valid[VOL_CAPABILITIES_FORMAT],itf=b.c.capabilities[VOL_CAPABILITIES_INTERFACES]&b.c.valid[VOL_CAPABILITIES_INTERFACES];
   printf("  caps CASE_SENSITIVE=%d CASE_PRESERVING=%d 2TB_FILESIZE=%d NO_ROOT_TIMES=%d SPARSE=%d FAST_STATFS=%d SYMBOLIC=%d HARDLINKS=%d JOURNAL=%d HIDDEN=%d\n",!!(fmt&VOL_CAP_FMT_CASE_SENSITIVE),!!(fmt&VOL_CAP_FMT_CASE_PRESERVING),!!(fmt&VOL_CAP_FMT_2TB_FILESIZE),!!(fmt&VOL_CAP_FMT_NO_ROOT_TIMES),!!(fmt&VOL_CAP_FMT_SPARSE_FILES),!!(fmt&VOL_CAP_FMT_FAST_STATFS),!!(fmt&VOL_CAP_FMT_SYMBOLICLINKS),!!(fmt&VOL_CAP_FMT_HARDLINKS),!!(fmt&VOL_CAP_FMT_JOURNAL),!!(fmt&VOL_CAP_FMT_HIDDEN_FILES));
   printf("  ifaces NAMEDSTREAMS=%d EXTENDED_ATTR=%d BULKATTR=%d RENAME_EXCL=%d RENAME_SWAP=%d EXCHANGEDATA=%d CLONE=%d ALLOCATE=%d FLOCK=%d\n",!!(itf&VOL_CAP_INT_NAMEDSTREAMS),!!(itf&VOL_CAP_INT_EXTENDED_ATTR),!!(itf&VOL_CAP_INT_READDIRATTR),!!(itf&VOL_CAP_INT_RENAME_EXCL),!!(itf&VOL_CAP_INT_RENAME_SWAP),!!(itf&VOL_CAP_INT_EXCHANGEDATA),!!(itf&VOL_CAP_INT_CLONE),!!(itf&VOL_CAP_INT_ALLOCATE),!!(itf&VOL_CAP_INT_FLOCK));
  }
  char lg[256]; 
  long nm=pathconf(m,_PC_NAME_MAX),pm=pathconf(m,_PC_PATH_MAX),cs=pathconf(m,_PC_CASE_SENSITIVE),cp=pathconf(m,_PC_CASE_PRESERVING),nb=pathconf(m,_PC_NAME_CHARS_MAX),sz=pathconf(m,_PC_FILESIZEBITS);printf("  pathconf NAME_MAX=%ld PATH_MAX=%ld CASE_SENS=%ld CASE_PRES=%ld NAME_CHARS_MAX=%ld FILESIZEBITS=%ld\n",nm,pm,cs,cp,nb,sz);
  return 0;}
