#ifndef ZENIT_MISSING_POOLS_CURSOR_H
#define ZENIT_MISSING_POOLS_CURSOR_H
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

// The caller owns one cursor per thread. Only completed lines advance the
// offset, so a concurrent stderr write cannot lose or double-count a record.
typedef struct {
    dev_t device;
    ino_t inode;
    off_t offset;
    uint64_t matches;
    int seen;
} ZenitMissingPoolsCursor;

static uint64_t zenitReadMissingPools(ZenitMissingPoolsCursor *cursor, const char *path, uint64_t threadID) {
    FILE *log=fopen(path,"r");
    if(!log) return cursor->matches;
    struct stat info;
    if(fstat(fileno(log),&info)!=0) {fclose(log);return cursor->matches;}
    if(!cursor->seen || cursor->device!=info.st_dev || cursor->inode!=info.st_ino || info.st_size<cursor->offset) {
        *cursor=(ZenitMissingPoolsCursor){.device=info.st_dev,.inode=info.st_ino,.seen=1};
    }
    if(fseeko(log,cursor->offset,SEEK_SET)!=0) {fclose(log);return cursor->matches;}
    char line[2048],thread[48];
    snprintf(thread,sizeof(thread),"(0x%llx)",(unsigned long long)threadID);
    while(fgets(line,sizeof(line),log)) {
        int missing=strstr(line,"MISSING POOLS:")!=NULL;
        int matching=strstr(line,thread)!=NULL;
        int complete=strchr(line,'\n')!=NULL;
        // Skip long non-diagnostic lines without treating each buffer chunk
        // as a separate line. libobjc's record prefix fits in the first chunk.
        while(!complete && fgets(line,sizeof(line),log)) complete=strchr(line,'\n')!=NULL;
        if(!complete) break; // Re-read this unfinished line after the next append.
        off_t end=ftello(log);
        if(end<0) break;
        if(missing && matching) cursor->matches++;
        cursor->offset=end;
    }
    fclose(log);
    return cursor->matches;
}
#endif
