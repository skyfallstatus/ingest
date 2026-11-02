// durable.c - after writing through the FS, WHEN do the bytes appear on the raw device?
// usage: durable <mnt> <rawdev> <mode> <sync>   mode: b(uffered)|n(ocache)  sync: none|fsync|barrier|full
// optional 5th arg: keepfd (scan while file still open)
#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#define BLK 4096
#define N 2048
#define CH (1024*1024)
static uint32_t devbs=512; static uint64_t devsize; static int rawfd;
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int scan(uint32_t scen){
  size_t bs=64*1024*1024; uint8_t *b; posix_memalign((void**)&b,16384,bs); int found=0;
  for(uint64_t off=0;off<devsize;off+=bs){
    size_t n=devsize-off<bs?devsize-off:bs; ssize_t r=pread(rawfd,b,n,off); if(r<=0)break;
    for(size_t i=0;i+16<=(size_t)r;i+=devbs){ if(!memcmp(b+i,"DRBLDRBL",8)){uint32_t s;memcpy(&s,b+i+8,4);if(s==scen)found++;} }
  }
  free(b); return found;
}
int main(int ac,char**av){
  const char*mnt=av[1],*raw=av[2],*mode=av[3],*syn=av[4]; int keep=ac>5;
  rawfd=open(raw,O_RDONLY); if(rawfd<0){perror(raw);return 1;}
  struct stat st; fstat(rawfd,&st);
  if(S_ISREG(st.st_mode)) devsize=st.st_size; else {uint64_t c;ioctl(rawfd,DKIOCGETBLOCKSIZE,&devbs);ioctl(rawfd,DKIOCGETBLOCKCOUNT,&c);devsize=c*devbs;}
  uint32_t scen=(uint32_t)(time(0)&0xffffff)^(getpid()<<8);
  char path[512]; snprintf(path,sizeof path,"%s/d%u.bin",mnt,scen);
  int fd=open(path,O_CREAT|O_RDWR|O_TRUNC,0644); if(fd<0){perror("open");return 1;}
  if(mode[0]=='n') fcntl(fd,F_NOCACHE,1);
  uint8_t *b; posix_memalign((void**)&b,16384,CH); uint64_t idx=0; size_t off=0;
  for(int c=0;c<8;c++){ for(size_t i=0;i<CH;i+=BLK){ memset(b+i,c+1,BLK); memcpy(b+i,"DRBLDRBL",8); memcpy(b+i+8,&scen,4); memcpy(b+i+12,&idx,8); idx++; }
    if(pwrite(fd,b,CH,off)!=CH){perror("pwrite");return 1;} off+=CH; }
  double t0=now(); int rc=0; 
  if(!strcmp(syn,"fsync")) rc=fsync(fd);
  else if(!strcmp(syn,"full")) rc=fcntl(fd,F_FULLFSYNC);
  else if(!strcmp(syn,"barrier")) rc=fcntl(fd,F_BARRIERFSYNC);
  double dt=now()-t0;
  if(!keep) close(fd);
  printf("%-7s %-8s %-6s rc=%d(errno %d) sync=%.1fms  found@t:",mode,syn,keep?"open":"closed",rc,rc?errno:0,dt*1e3);
  double ts[]={0,1,3,6,12,31}; double start=now();
  for(int i=0;i<6;i++){ while(now()-start<ts[i]) usleep(50000); int f=scan(scen); printf(" %.0fs=%d",ts[i],f); fflush(stdout); }
  printf("\n"); if(keep) close(fd);
  printf("PATH %s SCEN %u\n",path,scen);
  return 0;
}
