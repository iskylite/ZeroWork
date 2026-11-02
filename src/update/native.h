#import <Foundation/Foundation.h>
extern int zw_update_verify_signature(const unsigned char *, const unsigned char *, const unsigned char *, size_t);
extern int zw_update_newer(const char *, const char *);
extern const char *zw_update_trust_json(void);
extern void ZWFail(NSString *message);
extern NSDictionary *ZWManifest(NSData *envelope);
extern void ZWVerifyCode(NSString *path, NSString *identifier);
extern void ZWVerifyApp(NSString *path, NSString *version);
extern void ZWExtract(NSString *zip, NSString *destination, uint64_t limit);
extern NSString *ZWSHA256(NSString *path);
extern void ZWWrite(NSString *path, id json);
extern NSDictionary *ZWRead(NSString *path);
extern void ZWSyncDirectory(NSString *path);
extern BOOL ZWAlive(pid_t pid, uint64_t birth);
extern uint64_t ZWBirth(pid_t pid);
extern NSString *ZWCanonical(NSString *path);
extern NSString *ZWRoot(NSString *target, NSString *data);
extern void ZWPrivateDirectory(NSString *path);
extern BOOL ZWValidHTTPS(NSURL *url, BOOL redirects);
extern NSString *const ZWFeed;
extern NSString *const ZWReleases;
typedef struct {
    int state; // 0 idle,1 checking,2 available,3 download,4 verify,5 ready,6 prepare,7 prepared,8 committed,9 cancelled,10 error,11 aborted
    uint64_t generation, received, expected;
    char version[96], message[2048], notes[16385];
} ZWUpdateStatus;
