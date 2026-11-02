// ts.c set/read timestamps precisely; usage: ts set <file> | ts get <file>
#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/time.h>
static void show(const char*f){struct stat s;if(stat(f,&s)){perror("stat");return;}
 printf("  mtime=%ld.%09ld birth=%ld.%09ld atime=%ld.%09ld ctime=%ld.%09ld\n",s.st_mtimespec.tv_sec,s.st_mtimespec.tv_nsec,s.st_birthtimespec.tv_sec,s.st_birthtimespec.tv_nsec,s.st_atimespec.tv_sec,s.st_atimespec.tv_nsec,s.st_ctimespec.tv_sec,s.st_ctimespec.tv_nsec);}
int main(int c,char**v){
 if(!strcmp(v[1],"get")){show(v[2]);return 0;}
 const char*f=v[2]; int fd=open(f,O_CREAT|O_RDWR,0644);write(fd,"x",1);close(fd);
 struct{struct timespec cr,mod;}__attribute__((packed)) b;
 // 2026-03-15T12:34:57.123456789Z mtime, 2026-03-14T08:09:11.987654321Z birth
 b.cr.tv_sec=1773475751;b.cr.tv_nsec=987654321;b.mod.tv_sec=1773578097;b.mod.tv_nsec=123456789;
 struct attrlist al={0};al.bitmapcount=ATTR_BIT_MAP_COUNT;al.commonattr=ATTR_CMN_CRTIME|ATTR_CMN_MODTIME;
 int r=setattrlist(f,&al,&b,sizeof b,0);printf("  setattrlist rc=%d %s\n",r,r?strerror(errno):"");show(f);
 return 0;}
