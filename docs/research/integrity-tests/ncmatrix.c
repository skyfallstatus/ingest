// ncmatrix.c - which F_NOCACHE writes leave pages in the UBC? (+ dirty-invalidate safety)
#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
static long pg;
static int res(int fd,size_t sz,int *tot){ size_t np=(sz+pg-1)/pg;*tot=np; void*m=mmap(0,sz,PROT_READ,MAP_SHARED,fd,0); if(m==MAP_FAILED)return -1; char*v=malloc(np);int c=0; if(mincore(m,sz,v)==0)for(size_t i=0;i<np;i++)c+=v[i]&MINCORE_INCORE?1:0; else c=-2; munmap(m,sz);free(v);return c;}
static void one(const char*mnt,size_t size,size_t chunk,size_t bufoff,size_t fileoff){
  char p[512];snprintf(p,sizeof p,"%s/m.bin",mnt);unlink(p);
  int fd=open(p,O_CREAT|O_RDWR,0644);fcntl(fd,F_NOCACHE,1);
  uint8_t*b;posix_memalign((void**)&b,16384,chunk+16384);memset(b,0xAB,chunk+16384);
  size_t off=fileoff; if(fileoff){ /* prefix hole-free start */ uint8_t z[1];(void)z; ftruncate(fd,fileoff);}
  size_t left=size;while(left){size_t n=left<chunk?left:chunk;ssize_t w=pwrite(fd,b+bufoff,n,off);if(w!=(ssize_t)n){perror("pwrite");break;}off+=n;left-=n;}
  int rc=fcntl(fd,F_FULLFSYNC);int t;int fd2=open(p,O_RDONLY);int r=res(fd2,off,&t);close(fd2);
  printf("  size=%-9zu chunk=%-8zu bufoff=%-5zu fileoff=%-5zu full=%d resident=%d/%d\n",size,chunk,bufoff,fileoff,rc,r,t);
  close(fd);unlink(p);free(b);
}
int main(int c,char**v){pg=sysconf(_SC_PAGESIZE);const char*m=v[1];printf("== %s\n",m);
  size_t sizes[]={1000,4096,15000,16384,17000,65536,100000,1048576,1048577,8388608+5000};
  for(int i=0;i<10;i++) one(m,sizes[i],1048576,0,0);
  puts("  -- small chunks");
  one(m,8388608,4096,0,0); one(m,8388608,1000,0,0); one(m,8388608,16384,0,0); one(m,8388608,65536,0,0);
  puts("  -- misaligned memory buffer");
  one(m,8388608,1048576,7,0); one(m,8388608,1048576,512,0); one(m,8388608,1048576,4096,0);
  puts("  -- misaligned file offset");
  one(m,8388608,1048576,0,512); one(m,8388608,1048576,0,4096);
  // dirty invalidate
  char p[512];snprintf(p,sizeof p,"%s/dirty.bin",m);unlink(p);int fd=open(p,O_CREAT|O_RDWR,0644);uint8_t*b=malloc(1<<20);memset(b,0x5A,1<<20);pwrite(fd,b,1<<20,0);
  uint8_t*mp=mmap(0,1<<20,PROT_READ,MAP_SHARED,fd,0);int rc=msync(mp,1<<20,MS_INVALIDATE);int e=errno;munmap(mp,1<<20);
  memset(b,0,1<<20);fcntl(fd,F_NOCACHE,1);pread(fd,b,1<<20,0);int ok=1;for(int i=0;i<1<<20;i++)if(b[i]!=0x5A){ok=0;break;}
  printf("  dirty buffered write then msync(MS_INVALIDATE) w/o sync: rc=%d errno=%d data_intact=%d\n",rc,rc?e:0,ok);close(fd);unlink(p);
  return 0;}
