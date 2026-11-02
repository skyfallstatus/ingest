// tamper.c - decide whether a read path really reached the device.
// Write file through the FS, FULLFSYNC, locate blocks on the RAW device of a
// DISK IMAGE, invert the bytes there behind the cache, then read through the FS.
//   original bytes back => came from UBC ("cache"); inverted => came from device.
// usage: tamper <mnt> <rawdev> <bsd-name-for-remount or ->   (DISK IMAGES ONLY)
#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#ifdef WITH_CI
#include "cingest.h"    // adds the app's own read path to the methods tested: see README
#endif

#define BLK 4096
#ifndef NBODY
#define NBODY 2048
#endif
#ifndef TAIL
#define TAIL 5000
#endif
#define FSIZE ((size_t)NBODY*BLK + TAIL)
#define NBLK ((FSIZE+BLK-1)/BLK)
#define CHUNK (1024*1024)

static uint32_t devbs; static uint64_t devsize; static int rawfd; static const char *rawpath;
static void openraw(void){ if(rawfd>0)close(rawfd); rawfd=open(rawpath,O_RDWR); if(rawfd<0){perror(rawpath);exit(1);} struct stat st; fstat(rawfd,&st); if(S_ISREG(st.st_mode)){devbs=512;devsize=st.st_size;fcntl(rawfd,F_NOCACHE,1);} else {uint64_t c; ioctl(rawfd,DKIOCGETBLOCKSIZE,&devbs); ioctl(rawfd,DKIOCGETBLOCKCOUNT,&c); devsize=c*devbs;} }
static long pgsz;

static void fill(uint8_t *b, uint32_t scen, uint64_t idx) {
  memset(b, 0, 24); memcpy(b, "TMPRTMPR", 8); memcpy(b+8, &scen, 4); memcpy(b+12, &idx, 8);   // bytes 20 to 23 too, or expected() depends on the stack
  uint64_t x = 0x9E3779B97F4A7C15ULL ^ (((uint64_t)scen<<32) | idx);
  for (size_t i=24;i<BLK;i++){ x^=x<<13;x^=x>>7;x^=x<<17;b[i]=(uint8_t)x; }
}
static void *aalloc(size_t n){ void*p; if(posix_memalign(&p,16384,n))abort(); return p; }

static int resident(const char *path){          // pages in UBC, via mincore
  int fd=open(path,O_RDONLY); if(fd<0) return -1;
  size_t np=(FSIZE+pgsz-1)/pgsz;
  void *m=mmap(0,FSIZE,PROT_READ,MAP_SHARED,fd,0);
  if(m==MAP_FAILED){close(fd);return -2;}
  char *v=malloc(np); int c=0;
  if(mincore(m,FSIZE,v)==0) for(size_t i=0;i<np;i++) c+=(v[i]&MINCORE_INCORE)?1:0; else c=-3;
  munmap(m,FSIZE); close(fd); free(v); return c;
}

static int writefile(const char *path,uint32_t scen,int nocache,int syncmode){
  unlink(path);
  int fd=open(path,O_CREAT|O_RDWR|O_TRUNC,0644); if(fd<0){perror("open");return -1;}
  if(nocache && fcntl(fd,F_NOCACHE,1)) perror("F_NOCACHE");
  uint8_t *buf=aalloc(CHUNK+BLK);
  size_t off=0; uint64_t idx=0;
  while(off<FSIZE){
    size_t n=FSIZE-off<CHUNK?FSIZE-off:CHUNK;
    for(size_t i=0;i<n;i+=BLK) { uint8_t t[BLK]; fill(t,scen,idx++); memcpy(buf+i,t,(n-i)<BLK?(n-i):BLK); }
    if(getenv("WCHUNK")){size_t wc=atoi(getenv("WCHUNK"));for(size_t k=0;k<n;k+=wc){size_t q=n-k<wc?n-k:wc;if(pwrite(fd,buf+k,q,off+k)!=(ssize_t)q){perror("pw");return -1;}}off+=n;continue;}
    ssize_t w=pwrite(fd,buf,n,off); if(w!=(ssize_t)n){perror("pwrite");return -1;}
    off+=n;
  }
  int rc=0;
  if(syncmode==1) rc=fcntl(fd,F_FULLFSYNC);
  else if(syncmode==2) rc=fsync(fd);
  else if(syncmode==3) rc=fcntl(fd,F_BARRIERFSYNC);
  if(rc) printf("  sync mode %d failed errno=%d %s\n",syncmode,errno,strerror(errno));
  close(fd); free(buf); return 0;
}

// locate blocks on raw device
static int dups=0;
static int locate(uint32_t scen,uint64_t *where){ dups=0;
  size_t bs=64*1024*1024; uint8_t *b=aalloc(bs+devbs); int found=0;
  memset(where,0xff,sizeof(uint64_t)*NBLK);
  for(uint64_t off=0;off<devsize;off+=bs){
    size_t n=devsize-off<bs?devsize-off:bs;
    ssize_t r=pread(rawfd,b,n,off); if(r<=0){printf("  !! raw pread off=%llu r=%zd errno=%d %s\n",off,r,errno,strerror(errno));break;}
    for(size_t i=0;i+24<=(size_t)r;i+=devbs){
      if(memcmp(b+i,"TMPRTMPR",8)==0){
        uint32_t s; memcpy(&s,b+i+8,4);
        if(s==scen){ uint64_t idx; memcpy(&idx,b+i+12,8);
          if(idx<NBLK){ if(where[idx]==~0ULL){where[idx]=off+i;found++;} else dups++; } }
      }
    }
  }
  free(b); return found;
}

static int tamper(uint64_t *where){
  uint8_t *b=aalloc(BLK*2); int done=0;
  for(int i=0;i<NBLK;i++){
    if(where[i]==~0ULL) continue;
    if(pread(rawfd,b,BLK,where[i])!=BLK){perror("raw pread");continue;}
    for(int k=24;k<BLK;k++) b[k]^=0xFF;
    if(pwrite(rawfd,b,BLK,where[i])!=BLK){perror("raw pwrite");continue;}
    done++;
  }
  free(b); return done;
}

typedef struct{int cache,dev,mix;}cls;
static void classify(uint8_t *data,size_t len,uint32_t scen,cls *body,cls *tail){
  uint8_t o[BLK];
  for(size_t i=0;i*BLK<len;i++){
    size_t n=len-i*BLK; if(n>BLK)n=BLK;
    fill(o,scen,i); uint8_t *p=data+i*BLK; int same=0,inv=0;
    for(size_t k=24;k<n;k++){ if(p[k]==o[k])same++; else if(p[k]==(uint8_t)(o[k]^0xFF))inv++; }
    size_t tot=n-24; cls *c=(i<NBODY)?body:tail;
    if((size_t)same==tot)c->cache++; else if((size_t)inv==tot)c->dev++; else c->mix++;
  }
}

enum {R_PLAIN,R_NC,R_NC_NORA,R_NC_MISALIGN_BUF,R_NC_4K_CHUNK,R_NC_UNALIGNED_LEN,
      R_INV_PLAIN,R_INV_NC,R_SYNCINV_NC,R_KILL_PLAIN,R_KILL_NC,R_DEACT_NC,R_MMAP,R_OTHER_NC,R_OTHER_INV_NC,R_CI,R_CI_OTHER,R_REMOUNT,R_COUNT};
static const char *rname[]={"plain read","F_NOCACHE read","F_NOCACHE+RDAHEAD0","F_NOCACHE misaligned buf","F_NOCACHE 4K chunks","F_NOCACHE 1000-byte chunks",
  "msync(INVALIDATE)+plain","msync(INVALIDATE)+NOCACHE","msync(SYNC|INVAL)+NOCACHE","msync(KILLPAGES)+plain","msync(KILLPAGES)+NOCACHE","msync(DEACTIVATE)+NOCACHE","mmap read","3rd-party read,then NOCACHE","3rd-party,msync(INV)+NOCACHE","ci_hash_uncached","3rd-party,ci_hash_uncached","unmount/mount+plain"};

#ifdef WITH_CI
// The hash of the whole file as the device now holds it, or as the cache would still have it.
static uint64_t expected(uint32_t scen,int inverted){
  ci_xxh64 x; ci_xxh64_init(&x,0); uint8_t b[BLK];
  for(size_t i=0;i*BLK<FSIZE;i++){ fill(b,scen,i); if(inverted) for(int k=24;k<BLK;k++) b[k]^=0xFF; size_t n=FSIZE-i*BLK; ci_xxh64_update(&x,b,n<BLK?n:BLK); }
  return ci_xxh64_final(&x);
}
#endif

static int do_msync(const char*path,int fl){
  int fd=open(path,O_RDONLY); void*m=mmap(0,FSIZE,PROT_READ,MAP_SHARED,fd,0);
  int rc=(m==MAP_FAILED)?-2:msync(m,FSIZE,fl); int e=errno;
  if(m!=MAP_FAILED)munmap(m,FSIZE); close(fd);
  if(rc)printf("  msync flags=%x rc=%d errno=%d %s\n",fl,rc,e,strerror(e)); return rc;
}

int main(int ac,char**av){
  const char*mnt=av[1],*raw=av[2],*bsd=av[3]; int syncmode=ac>4?atoi(av[4]):1;
  pgsz=sysconf(_SC_PAGESIZE);
  rawpath=raw; openraw();
  printf("mnt=%s raw=%s devbs=%u devsize=%llu pagesize=%ld file=%zu syncmode=%d\n",mnt,raw,devbs,devsize,pgsz,FSIZE,syncmode);
  size_t np=(FSIZE+pgsz-1)/pgsz; printf("total pages=%zu\n",np);
  printf("%-5s %-27s | %6s %7s %7s | %6s %6s %4s | %4s %4s %4s | res_after\n","write","read method","res_wr","on_dev","res_prd","cache","dev","mix","tc","td","tm");
  uint64_t *where=malloc(sizeof(uint64_t)*NBLK);
  uint8_t *buf=aalloc(FSIZE+2*CHUNK);
  uint32_t scen=(uint32_t)time(NULL)*1024u ^ (getpid()<<20);
  for(int w=0;w<2;w++) for(int r=0;r<R_COUNT;r++){
    if(r==R_REMOUNT && bsd[0]=='-') continue;
#ifndef WITH_CI
    if(r==R_CI||r==R_CI_OTHER) continue;
#endif
    scen++;
    char path[512]; snprintf(path,sizeof path,"%s/s%u.bin",mnt,scen);
    if(writefile(path,scen,w,syncmode)) return 1;
    if(r==R_OTHER_NC||r==R_OTHER_INV_NC||r==R_CI_OTHER){ int f=open(path,O_RDONLY); uint8_t *t=aalloc(CHUNK); while(read(f,t,CHUNK)>0); close(f); free(t);}
    int res_w=resident(path);
    int found=locate(scen,where); if(dups) printf("  !! %d duplicate on-device copies\n",dups);
    int t=tamper(where);
    int res_pre=resident(path);
    switch(r){
      case R_INV_PLAIN: case R_INV_NC: case R_OTHER_INV_NC: do_msync(path,MS_INVALIDATE);break;
      case R_SYNCINV_NC: do_msync(path,MS_SYNC|MS_INVALIDATE);break;
      case R_KILL_PLAIN: case R_KILL_NC: do_msync(path,MS_KILLPAGES);break;
      case R_DEACT_NC: do_msync(path,MS_DEACTIVATE);break;
      case R_REMOUNT: { char cmd[512]; snprintf(cmd,sizeof cmd,"diskutil unmount %s >/dev/null && diskutil mount nobrowse -mountPoint %s %s >/dev/null",bsd,mnt,bsd); if(system(cmd)) printf("  remount failed\n"); openraw(); break; }
      default: break;
    }
#ifdef WITH_CI
    if(r==R_CI||r==R_CI_OTHER){
      int inv=0; ci_result cr=ci_hash_uncached(path,NULL,&inv,NULL);
      const char *from=cr.stage?"READ FAILED":cr.hash==expected(scen,1)?"device":cr.hash==expected(scen,0)?"CACHE":"MIXED";
      printf("%-5s %-27s | %6d %3d/%-3d %7d | all %-11s bytes %llu invalidated %d | %d\n",w?"NOCAC":"BUFRD",rname[r],res_w,found,NBLK,res_pre,from,cr.bytes,inv,resident(path));
      fflush(stdout); unlink(path); continue;
    }
#endif
    int fd=open(path,O_RDONLY); if(fd<0){perror("reopen");return 1;}
    int nc=(r==R_NC||r==R_NC_NORA||r==R_NC_MISALIGN_BUF||r==R_NC_4K_CHUNK||r==R_NC_UNALIGNED_LEN||r==R_INV_NC||r==R_SYNCINV_NC||r==R_KILL_NC||r==R_DEACT_NC||r==R_OTHER_NC||r==R_OTHER_INV_NC);
    if(nc) fcntl(fd,F_NOCACHE,1);
    if(r==R_NC_NORA) fcntl(fd,F_RDAHEAD,0);
    uint8_t *dst=buf; size_t chunk=CHUNK;
    if(r==R_NC_MISALIGN_BUF) dst=buf+7;
    if(r==R_NC_4K_CHUNK) chunk=4096;
    if(r==R_NC_UNALIGNED_LEN) chunk=1000;
    size_t got=0;
    if(r==R_MMAP){ void*m=mmap(0,FSIZE,PROT_READ,MAP_SHARED,fd,0); memcpy(dst,m,FSIZE); munmap(m,FSIZE); got=FSIZE; }
    else while(got<FSIZE){ ssize_t n=read(fd,dst+got,chunk); if(n<=0){perror("read");break;} got+=n; }
    close(fd);
    cls body={0},tail={0}; classify(dst,got,scen,&body,&tail);
    int res_after=resident(path);
    printf("%-5s %-27s | %6d %3d/%-3d %7d | %6d %6d %4d | %4d %4d %4d | %d\n",w?"NOCAC":"BUFRD",rname[r],res_w,found,NBLK,res_pre,body.cache,body.dev,body.mix,tail.cache,tail.dev,tail.mix,res_after);
    fflush(stdout);
    unlink(path);
  }
  return 0;
}
