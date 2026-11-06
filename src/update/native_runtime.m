#import "native.h"
#import <AppKit/AppKit.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <pthread.h>

static pthread_mutex_t statusLock=PTHREAD_MUTEX_INITIALIZER;
static ZWUpdateStatus status;
static NSString *rootPath,*targetPath,*dataPath,*transactionPath;
static NSDictionary *manifest;
static NSData *manifestEnvelope;
static BOOL presented=NO;
static BOOL automatic=YES;
static double lastCheck=0;
static BOOL decisionSent=NO;
static _Atomic(double) prepareStarted=0;
static void SetState(int state) {
    if(state==10 && status.state!=10)status.failure_stage=(status.state>=5 && status.state<=8)?6:status.state;
    else if(state!=10)status.failure_stage=0;
    status.state=state;
}
static void Publish(int state,NSString *message) {
    pthread_mutex_lock(&statusLock);SetState(state);
    if(message)strlcpy(status.message,message.UTF8String,sizeof(status.message));
    pthread_mutex_unlock(&statusLock);
}
static uint64_t Generation(void){pthread_mutex_lock(&statusLock);uint64_t g=status.generation;pthread_mutex_unlock(&statusLock);return g;}
static BOOL Current(uint64_t g){return Generation()==g;}
static void PublishGeneration(uint64_t generation,int state,NSString *message){pthread_mutex_lock(&statusLock);if(status.generation==generation){SetState(state);if(message)strlcpy(status.message,message.UTF8String,sizeof(status.message));}pthread_mutex_unlock(&statusLock);}
static dispatch_queue_t InstallationQueue(void){static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("com.zerowork.update.install",DISPATCH_QUEUE_SERIAL);});return queue;}
static NSString *Transaction(void){pthread_mutex_lock(&statusLock);NSString *value=transactionPath;pthread_mutex_unlock(&statusLock);return value;}
static void SetTransaction(NSString *value){pthread_mutex_lock(&statusLock);transactionPath=value;pthread_mutex_unlock(&statusLock);}

static NSString *Version(void){return [NSBundle.mainBundle objectForInfoDictionaryKey:@"ZeroWorkReleaseVersion"]?:@"0.3.0";}
static NSString *ArchivePath(void){return [rootPath stringByAppendingPathComponent:@"verified.zip"];}
static NSString *EnvelopePath(void){return [rootPath stringByAppendingPathComponent:@"envelope.json"];}
static NSString *CurrentBundle(void){return ZWCanonical(NSBundle.mainBundle.bundlePath);}
static void Alert(NSString *message) {
    [NSApplication sharedApplication];NSAlert *alert=[NSAlert new];alert.messageText=@"ZeroWork 更新恢复";alert.informativeText=message;[alert addButtonWithTitle:@"关闭"];[alert addButtonWithTitle:@"打开官方发布页"];
    if([alert runModal]==NSAlertSecondButtonReturn)[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:ZWReleases]];
}
static BOOL ValidTransaction(NSString *path){return [path.stringByDeletingLastPathComponent isEqual:rootPath] && [path.lastPathComponent hasPrefix:@"txn-"] && ![path.lastPathComponent containsString:@"/"];}
static BOOL Terminal(NSString *stage){return [@[@"healthy",@"old_restored_verified",@"aborted_before_replace",@"cancelled"] containsObject:stage];}

// Must run before data-scope lock, configuration and migrations. A nonce grants
// data access only after the helper has durably marked data as potentially changed.
int zw_update_startup_gate(const char *data) {
    @autoreleasepool { @try {
        targetPath=CurrentBundle();dataPath=[NSString stringWithUTF8String:data];rootPath=ZWRoot(targetPath,dataPath);ZWPrivateDirectory(rootPath);
        NSString *activeFile=[rootPath stringByAppendingPathComponent:@"active.json"];
        if(![NSFileManager.defaultManager fileExistsAtPath:activeFile])return 1;
        NSDictionary *active=ZWRead(activeFile);NSString *path=active[@"transaction"];
        if(![path isKindOfClass:NSString.class] || !ValidTransaction(path))ZWFail(@"更新事务索引损坏。请保留更新目录并从官方发布页修复应用。");
        NSDictionary *record=ZWRead([path stringByAppendingPathComponent:@"record.json"]);
        if(!record)ZWFail(@"更新记录缺失。为避免并发替换或使用不兼容的数据，应用尚未打开。");
        NSString *stage=record[@"stage"];
        if(Terminal(stage))return 1;
        if([record[@"decision"] isEqual:@"undecided"] && !ZWAlive([record[@"helper_pid"] intValue],[record[@"helper_birth"] unsignedLongLongValue])) {
            // No durable commit exists: retain the transaction, but never replace.
            return 1;
        }
        NSString *nonce=NSProcessInfo.processInfo.environment[@"ZW_UPDATE_NONCE"];
        NSString *token=NSProcessInfo.processInfo.environment[@"ZW_UPDATE_TRANSACTION"];
        if([token isEqual:path.lastPathComponent] && [nonce isEqual:record[@"nonce"]] && [stage isEqual:@"launching_new"]) {
            for(int i=0;i<50 && [stage isEqual:@"launching_new"];i++){usleep(100000);record=ZWRead([path stringByAppendingPathComponent:@"record.json"]);stage=record[@"stage"];}
        }

        if([token isEqual:path.lastPathComponent] && [nonce isEqual:record[@"nonce"]] && [record[@"target"] isEqual:targetPath] && [record[@"version"] isEqual:Version()] && [stage isEqual:@"new_started"]) {
            ZWWrite([path stringByAppendingPathComponent:@"startup.request"],@{@"nonce":nonce,@"pid":@(getpid()),@"birth":@(ZWBirth(getpid())),@"version":Version()});
            for(int i=0;i<100;i++) {
                record=ZWRead([path stringByAppendingPathComponent:@"record.json"]);
                if([record[@"stage"] isEqual:@"data_access_granted"] && [record[@"new_pid"] intValue]==getpid() && [record[@"new_birth"] unsignedLongLongValue]==ZWBirth(getpid())) { SetTransaction(path);return 1; }
                usleep(100000);
            }
            ZWFail(@"未收到新版数据访问授权；应用尚未读取配置。恢复记录已保留。");
        }
        Alert([NSString stringWithFormat:@"另一安装事务尚未完成（%@）。\n\n恢复目录：%@\n\n请等待安装窗口完成；若安装程序已退出，请重新运行该目录内的 ZeroWorkUpdater 继续恢复。当前启动未读取应用数据。",stage?:@"未知状态",path]);return 0;
    } @catch(NSException *e){Alert(e.reason);return 0;} }
}
void zw_update_healthy(void){
    if(!Transaction())return;
    @try{NSDictionary *r=ZWRead([Transaction() stringByAppendingPathComponent:@"record.json"]);
        if([r[@"stage"] isEqual:@"data_access_granted"] && [r[@"new_pid"] intValue]==getpid())ZWWrite([Transaction() stringByAppendingPathComponent:@"healthy.request"],@{@"nonce":r[@"nonce"],@"pid":@(getpid()),@"birth":@(ZWBirth(getpid())),@"version":Version()});
    }@catch(NSException *e){Publish(10,e.reason);}
}

@interface ZWUpdateFetch : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL package;
@property(nonatomic) int probe; // 0 signed feed/package,1 latest release,2 public repository
@property(nonatomic) NSInteger httpStatus;
@property(nonatomic) NSMutableData *metadata;
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSURLSessionDataTask *task;
@property(nonatomic) NSString *temporary;
@property(nonatomic) int fd;
@property(nonatomic) uint64_t received;
@property(nonatomic) NSDictionary *releaseInfo;
@property(nonatomic) NSData *envelope;
@property(nonatomic) NSString *failure;
@end
static ZWUpdateFetch *fetch;
#if ZW_UPDATE_TESTING
static Class fetchProtocol;
#endif
static void StartFetch(ZWUpdateFetch *f,NSString *url);
static void ProbeRelease(uint64_t generation,int probe){
    ZWUpdateFetch *f=[ZWUpdateFetch new];f.generation=generation;f.fd=-1;f.probe=probe;f.metadata=[NSMutableData data];
    StartFetch(f,probe==1?@"https://api.github.com/repos/iskylite/ZeroWork/releases/latest":@"https://api.github.com/repos/iskylite/ZeroWork");
}
static BOOL ValidFetchURL(ZWUpdateFetch *f,NSURL *url){
    if(!f.probe)return ZWValidHTTPS(url,YES);
    NSString *expected=f.probe==1?@"https://api.github.com/repos/iskylite/ZeroWork/releases/latest":@"https://api.github.com/repos/iskylite/ZeroWork";
    return [url.absoluteString isEqual:expected];
}
static NSString *NetworkFailure(NSError *error){
    NSString *detail=@"网络连接失败，请检查系统代理或稍后重试";
    if([error.domain isEqual:NSURLErrorDomain]){
        switch(error.code){
            case NSURLErrorTimedOut:detail=@"连接 GitHub 超时，请检查系统代理或稍后重试";break;
            case NSURLErrorCannotFindHost:case NSURLErrorDNSLookupFailed:detail=@"无法解析 GitHub 地址，请检查网络与 DNS";break;
            case NSURLErrorCannotConnectToHost:detail=@"无法连接 GitHub 或系统代理，请检查网络设置";break;
            case NSURLErrorNotConnectedToInternet:detail=@"网络未连接，请连接网络后重试";break;
            case NSURLErrorSecureConnectionFailed:case NSURLErrorServerCertificateUntrusted:case NSURLErrorServerCertificateHasBadDate:detail=@"GitHub 的安全连接或证书验证失败，请检查系统时间与代理";break;
        }
    }
    return [NSString stringWithFormat:@"%@（%@ %ld）",detail,error.domain,(long)error.code];
}
@implementation ZWUpdateFetch
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    BOOL allow=!self.probe && ZWValidHTTPS(request.URL,YES) && task.countOfBytesReceived==0;
    if(!allow)self.failure=@"更新请求重定向到未授权地址";
    completionHandler(allow?request:nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    uint64_t cap=self.package?[self.releaseInfo[@"bytes"] unsignedLongLongValue]:(self.probe?262144:65536);
    if(!Current(self.generation)){completionHandler(NSURLSessionResponseCancel);return;}
    if(![response isKindOfClass:NSHTTPURLResponse.class])self.failure=@"更新服务未返回有效的 HTTP 响应";
    else if(!ValidFetchURL(self,response.URL))self.failure=@"更新响应来自未授权地址";
    else {
        self.httpStatus=[(NSHTTPURLResponse *)response statusCode];
        if(self.httpStatus!=200 && !(self.httpStatus==404 && !self.package)){
            NSString *prefix=self.probe?@"更新源返回 HTTP 404，发布状态查询失败":(self.package?@"更新包下载失败":@"更新服务请求失败");
            self.failure=[NSString stringWithFormat:@"%@（HTTP %ld）",prefix,(long)self.httpStatus];
        }else if(response.expectedContentLength>(int64_t)cap)self.failure=self.package?@"更新包超过签名描述的大小限制":@"更新服务响应超过大小限制";
    }
    if(self.failure){completionHandler(NSURLSessionResponseCancel);return;}
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(!Current(self.generation)){[task cancel];return;}
    self.received+=data.length;uint64_t cap=self.package?[self.releaseInfo[@"bytes"] unsignedLongLongValue]:(self.probe?262144:65536);
    if(self.received>cap){self.failure=self.package?@"更新包超过签名描述的大小限制":@"更新服务响应超过大小限制";[task cancel];return;}
    if(self.package){size_t left=data.length;const char *p=data.bytes;while(left){ssize_t n=write(self.fd,p,left);if(n<=0){self.failure=@"更新包写入失败";[task cancel];return;}p+=n;left-=n;}}
    else [self.metadata appendData:data];
    pthread_mutex_lock(&statusLock);if(status.generation==self.generation){status.received=self.received;status.expected=cap;}pthread_mutex_unlock(&statusLock);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(self.fd>=0){if(fsync(self.fd))self.failure=@"下载文件保存失败";close(self.fd);self.fd=-1;}
    @try{
        if(!Current(self.generation))return;
        if(error || self.failure)ZWFail(self.failure?:(self.probe?[@"更新源返回 HTTP 404，无法确认发布状态：" stringByAppendingString:NetworkFailure(error)]:NetworkFailure(error)));
        if(self.httpStatus==404 && !self.package){
            if(self.probe==2)ZWFail(@"更新源仓库不可访问（HTTP 404）");
            ProbeRelease(self.generation,self.probe==1?2:1);return;
        }
        if(self.probe){
            id object=[NSJSONSerialization JSONObjectWithData:self.metadata options:0 error:nil];
            if(![object isKindOfClass:NSDictionary.class])ZWFail(@"更新源返回 HTTP 404，发布状态响应格式无效");
            if(self.probe==2){
                if(![object[@"full_name"] isEqual:@"iskylite/ZeroWork"] || ![object[@"private"] isEqual:@NO])ZWFail(@"无法确认公开更新源的发布状态");
                PublishGeneration(self.generation,12,@"正式版通道尚未发布可用版本，当前未开始下载或安装。");
            }else{
                if(![object[@"tag_name"] isKindOfClass:NSString.class] || ![object[@"draft"] isEqual:@NO] || ![object[@"prerelease"] isEqual:@NO] || ![object[@"assets"] isKindOfClass:NSArray.class])ZWFail(@"更新源返回 HTTP 404，正式版发布状态无效");
                BOOL hasFeed=NO;for(id asset in object[@"assets"])if([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:@"update.json"])hasFeed=YES;
                ZWFail(hasFeed?@"正式版更新清单暂不可用（HTTP 404），请稍后重试或查看官方发布页":@"正式版缺少自动更新清单 update.json，请从官方发布页手动下载");
            }
            return;
        }
        if(!self.package){
            NSDictionary *release=ZWManifest(self.metadata);
            dispatch_sync(dispatch_get_main_queue(),^{if(Current(self.generation)){manifest=release;manifestEnvelope=self.metadata;}});
            pthread_mutex_lock(&statusLock);if(status.generation==self.generation){strlcpy(status.version,[release[@"version"] UTF8String],sizeof(status.version));strlcpy(status.notes,[release[@"notes"] UTF8String],sizeof(status.notes));}pthread_mutex_unlock(&statusLock);
            PublishGeneration(self.generation,zw_update_newer([release[@"version"] UTF8String],Version().UTF8String)?2:0,zw_update_newer([release[@"version"] UTF8String],Version().UTF8String)?@"发现新版本":@"当前已是最新版本");
        }else{
            if(self.received != [self.releaseInfo[@"bytes"] unsignedLongLongValue])ZWFail(@"下载大小与签名描述不一致");
            PublishGeneration(self.generation,4,@"正在校验签名、文件与应用身份…");
            if(![ZWSHA256(self.temporary) isEqual:self.releaseInfo[@"sha256"]])ZWFail(@"更新包 SHA256 校验失败");
            NSString *stage=[rootPath stringByAppendingFormat:@"/verify-%llu",self.generation];
            [NSFileManager.defaultManager removeItemAtPath:stage error:nil];ZWExtract(self.temporary,stage,[self.releaseInfo[@"expanded_bytes"] unsignedLongLongValue]);
            ZWVerifyApp([stage stringByAppendingPathComponent:@"ZeroWork.app"],self.releaseInfo[@"version"]);
            [NSFileManager.defaultManager removeItemAtPath:stage error:nil];
            if(!Current(self.generation))return;
            if(rename(self.temporary.fileSystemRepresentation,ArchivePath().fileSystemRepresentation))ZWFail(@"已校验更新包无法保存");
            id envelope=[NSJSONSerialization JSONObjectWithData:self.envelope options:0 error:nil];ZWWrite(EnvelopePath(),envelope);
            PublishGeneration(self.generation,5,@"更新包已验证，可以准备安装");
        }
    }@catch(NSException *e){if(Current(self.generation))PublishGeneration(self.generation,10,e.reason);}
    @finally{if(self.temporary)unlink(self.temporary.fileSystemRepresentation);[session finishTasksAndInvalidate];}
}
@end
static void StartFetch(ZWUpdateFetch *f,NSString *url){
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=f.package?1800:60;
    config.HTTPCookieStorage=nil;config.URLCredentialStorage=nil;config.URLCache=nil;
    // Leave proxy configuration unset so NSURLSession uses macOS system settings.
#if ZW_UPDATE_TESTING
    if(fetchProtocol)config.protocolClasses=@[fetchProtocol];
#endif
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
    f.session=[NSURLSession sessionWithConfiguration:config delegate:f delegateQueue:queue];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"ZeroWork-Updater" forHTTPHeaderField:@"User-Agent"];
    f.task=[f.session dataTaskWithRequest:request];
    if(NSThread.isMainThread){fetch=f;}else dispatch_sync(dispatch_get_main_queue(),^{if(Current(f.generation))fetch=f;});
    if(Current(f.generation))[f.task resume];else [f.session invalidateAndCancel];
}
static void Fetch(BOOL package){
    @try{
        if(!rootPath)ZWFail(@"更新服务尚未就绪");
        [fetch.task cancel];pthread_mutex_lock(&statusLock);status.generation++;status.received=0;status.expected=0;pthread_mutex_unlock(&statusLock);
        ZWUpdateFetch *f=[ZWUpdateFetch new];f.generation=Generation();f.package=package;f.fd=-1;f.metadata=[NSMutableData data];f.releaseInfo=manifest;f.envelope=manifestEnvelope;
        if(package){if(!manifest)ZWFail(@"请先检查新版本");f.temporary=[rootPath stringByAppendingFormat:@"/download-%llu.part",f.generation];f.fd=open(f.temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(f.fd<0)ZWFail(@"无法创建下载文件");}
        if(!package){manifest=nil;manifestEnvelope=nil;pthread_mutex_lock(&statusLock);status.version[0]=0;status.notes[0]=0;pthread_mutex_unlock(&statusLock);}
        Publish(package?3:1,package?@"正在下载已签名的更新包…":@"正在检查 GitHub Release…");
        StartFetch(f,package?f.releaseInfo[@"url"]:ZWFeed);
        if(!package){lastCheck=NSDate.date.timeIntervalSince1970;ZWWrite([rootPath stringByAppendingPathComponent:@"check.json"],@{@"time":@(lastCheck)});}
    }@catch(NSException *e){Publish(10,e.reason);}
}
void zw_update_start(int autoCheck){automatic=autoCheck!=0;lastCheck=[ZWRead([rootPath stringByAppendingPathComponent:@"check.json"])[@"time"] doubleValue];}
void zw_update_status(ZWUpdateStatus *out){pthread_mutex_lock(&statusLock);*out=status;pthread_mutex_unlock(&statusLock);}
int zw_update_take_present(void){BOOL value=presented;presented=NO;return value;}
void zw_update_open(void){presented=YES;if(status.state==0 || status.state==10 || status.state==12)Fetch(NO);}
void zw_update_set_automatic(int enabled){automatic=enabled!=0;}
void zw_update_command(int command){
    @try{
        if(command==1){presented=YES;if(status.state>=6 && status.state<=8)return;Fetch(NO);}
        if(command==2)Fetch(YES);
        if(command==3){[fetch.task cancel];pthread_mutex_lock(&statusLock);status.generation++;pthread_mutex_unlock(&statusLock);Publish(manifest?2:0,@"已取消下载或校验");}
        if(command==4 || command==5){
            decisionSent=YES;
            dispatch_async(InstallationQueue(),^{@try{
                NSString *path=Transaction();
                if(!path){if(command==5){Publish(9,@"安装程序已确认取消，不会在应用退出后安装");return;}ZWFail(@"尚未生成安装事务");}
                NSDictionary *r=ZWRead([path stringByAppendingPathComponent:@"record.json"]);
                ZWWrite([path stringByAppendingPathComponent:command==4?@"commit.request":@"cancel.request"],@{@"nonce":r[@"nonce"]?:@""});
            }@catch(NSException *e){Publish(6,@"无法确认安装决定，正在查询原事务；应用暂不退出");}});
        }
        if(command==6)[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:ZWReleases]];
        if(command==7 && Transaction())[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:Transaction()]];
    }@catch(NSException *e){Publish(10,e.reason);}
}
void zw_update_tick(void){
    if(Transaction() && status.state>=6){
        NSDictionary *r=ZWRead([Transaction() stringByAppendingPathComponent:@"record.json"]);NSString *stage=r[@"stage"],*decision=r[@"decision"];
        if([stage isEqual:@"aborted_before_replace"])Publish(11,@"应用退出超时，尚未替换应用；旧的退出授权已撤销");
        else if([decision isEqual:@"cancelled"])Publish(9,@"安装程序已确认取消；不会在应用退出后安装");
        else if([decision isEqual:@"committed"])Publish(8,@"已确认开始安装，正在退出应用…");
        else if([stage isEqual:@"prepared"])Publish(7,@"安装程序已准备完成，等待提交");
        else if([stage isEqual:@"prepare_failed"])Publish(10,r[@"error"]?:@"安装准备失败");
        else if(!ZWAlive([r[@"helper_pid"] intValue],[r[@"helper_birth"] unsignedLongLongValue]) && !decisionSent && NSDate.date.timeIntervalSince1970-prepareStarted>15)Publish(10,@"安装辅助程序已退出，尚未提交安装");
        // If a decision request was sent and ACK is lost, retain the gate and
        // query this transaction. Never assume cancellation or create a second one.
    }
    pthread_mutex_lock(&statusLock);BOOL checkable=status.state==0 || status.state==12 || (status.state==10 && status.failure_stage==1);pthread_mutex_unlock(&statusLock);
    if(automatic && checkable && NSDate.date.timeIntervalSince1970-lastCheck>=86400)Fetch(NO);
}
int zw_update_can_install(char *reason,size_t length){
    NSString *failure=nil;
    if(![targetPath.pathExtension isEqual:@"app"] || ![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.zerowork.app"])failure=@"开发运行不替换应用，请使用正式签名的 .app";
    else if([targetPath containsString:@"/AppTranslocation/"] || [targetPath hasPrefix:@"/Volumes/"])failure=@"请先将应用移到“应用程序”目录，再安装更新";
    else if(access(targetPath.stringByDeletingLastPathComponent.fileSystemRepresentation,W_OK))failure=@"应用目录不可写，请使用官方安装包手动更新";
    if(failure){strlcpy(reason,failure.UTF8String,length);return 0;}return 1;
}
static void Prepare(NSString *snapshotString,NSArray *themeSnapshot){
    @try{
#if ZW_UPDATE_TESTING
        // Deterministic fixture barrier: exercise cancellation while copying and
        // helper preparation are still queued, without delaying the UI thread.
        const char *holdPath=getenv("ZW_UPDATE_TEST_PREPARE_HOLD");
        if(holdPath){NSString *hold=[NSString stringWithUTF8String:holdPath];ZWWrite([hold stringByAppendingString:@".entered"],@{});double end=NSDate.date.timeIntervalSince1970+10;while(access(hold.fileSystemRepresentation,F_OK)){if(NSDate.date.timeIntervalSince1970>end)ZWFail(@"测试准备屏障超时");usleep(10000);}}
#endif
        char reason[512];if(!zw_update_can_install(reason,sizeof(reason)))ZWFail([NSString stringWithUTF8String:reason]);
        NSDictionary *active=ZWRead([rootPath stringByAppendingPathComponent:@"active.json"]);
        if(active){NSDictionary *old=ZWRead([active[@"transaction"] stringByAppendingPathComponent:@"record.json"]);if(!old || !Terminal(old[@"stage"]))ZWFail(@"上一安装事务尚未解决，请先完成恢复");}
        if(!manifest || ![NSFileManager.defaultManager fileExistsAtPath:ArchivePath()])ZWFail(@"已校验的更新包不存在");
        NSString *path=[rootPath stringByAppendingFormat:@"/txn-%@",NSUUID.UUID.UUIDString];ZWPrivateDirectory(path);
        NSString *source=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/ZeroWorkUpdater"];
        NSString *helper=[path stringByAppendingPathComponent:@"ZeroWorkUpdater"];
        NSError *error=nil;if(![NSFileManager.defaultManager copyItemAtPath:source toPath:helper error:&error])ZWFail(@"无法复制独立安装程序");chmod(helper.fileSystemRepresentation,0700);
        if(![NSFileManager.defaultManager copyItemAtPath:ArchivePath() toPath:[path stringByAppendingPathComponent:@"update.zip"] error:&error])ZWFail(@"无法保存安装包");
        ZWWrite([path stringByAppendingPathComponent:@"envelope.json"],[NSJSONSerialization JSONObjectWithData:manifestEnvelope options:0 error:nil]);
        id snapshot=[NSJSONSerialization JSONObjectWithData:[snapshotString dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];if(!snapshot)ZWFail(@"工作区快照无效");ZWWrite([path stringByAppendingPathComponent:@"workspace.json"],snapshot);
        NSArray *theme=themeSnapshot;
        NSDictionary *record=@{@"stage":@"preparing",@"decision":@"undecided",@"target":targetPath,@"data":dataPath,@"version":manifest[@"version"],@"old_version":Version(),@"parent_pid":@(getpid()),@"parent_birth":@(ZWBirth(getpid())),@"nonce":NSUUID.UUID.UUIDString,@"helper_pid":@0,@"helper_birth":@0,@"theme":theme,@"data_state":@"unchanged"};
        ZWWrite([path stringByAppendingPathComponent:@"record.json"],record);ZWWrite([rootPath stringByAppendingPathComponent:@"active.json"],@{@"transaction":path});
        NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:helper];task.arguments=@[path];
        if(![task launchAndReturnError:&error]){NSMutableDictionary *r=[record mutableCopy];r[@"decision"]=@"cancelled";r[@"stage"]=@"cancelled";ZWWrite([path stringByAppendingPathComponent:@"record.json"],r);ZWFail(@"独立安装程序启动失败，应用尚未退出");}
        SetTransaction(path);prepareStarted=NSDate.date.timeIntervalSince1970;Publish(6,@"正在准备独立安装程序…");
    }@catch(NSException *e){Publish(10,e.reason);}
}
void zw_update_prepare(const char *snapshotJSON,const float *colors){
    NSString *snapshot=[NSString stringWithUTF8String:snapshotJSON];NSMutableArray *theme=[NSMutableArray array];for(int i=0;i<16;i++)[theme addObject:@(colors[i])];
    SetTransaction(nil);decisionSent=NO;prepareStarted=NSDate.date.timeIntervalSince1970;Publish(6,@"正在准备独立安装程序…");
    dispatch_async(InstallationQueue(),^{Prepare(snapshot,theme);});
}
// Persist BEFORE any owner close. A later cleanup receipt never overwrites this.
int zw_update_save_snapshot(const char *json){
    @try{id value=[NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];if(!value)ZWFail(@"工作区快照无效");ZWWrite([rootPath stringByAppendingPathComponent:@"pre-close-workspace.json"],value);return 1;}
    @catch(NSException *e){Publish(10,e.reason);return 0;}
}
#if ZW_UPDATE_TESTING
// Only the disposable signed runtime fixture calls this. It uses the real
// trust, archive and app verifiers; it never fabricates an installed version.
int zw_update_test_seed_verified(const char *envelopeFile,const char *archiveFile){
    @try{
        NSData *envelope=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:envelopeFile]];NSDictionary *release=ZWManifest(envelope);
        NSString *archive=[NSString stringWithUTF8String:archiveFile];struct stat st;
        if(lstat(archive.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || st.st_size!=[release[@"bytes"] unsignedLongLongValue] || ![ZWSHA256(archive) isEqual:release[@"sha256"]])ZWFail(@"测试更新包未通过真实校验");
        NSString *stage=[rootPath stringByAppendingPathComponent:@"fixture-verify"];ZWExtract(archive,stage,[release[@"expanded_bytes"] unsignedLongLongValue]);ZWVerifyApp([stage stringByAppendingPathComponent:@"ZeroWork.app"],release[@"version"]);[NSFileManager.defaultManager removeItemAtPath:stage error:nil];
        NSError *error=nil;if(![NSFileManager.defaultManager copyItemAtPath:archive toPath:ArchivePath() error:&error])ZWFail(@"测试更新包无法保存");
        manifest=release;manifestEnvelope=envelope;ZWWrite(EnvelopePath(),[NSJSONSerialization JSONObjectWithData:envelope options:0 error:nil]);Publish(5,@"签名测试更新包已通过真实校验");return 1;
    }@catch(NSException *e){Publish(10,e.reason);return 0;}
}
// Main-app host E2E only: inject a verified-state presentation without enabling
// an installer or accepting an unsigned package. Production erases this symbol.
void zw_update_test_downloading(uint64_t received,uint64_t expected){
    Publish(3,@"正在下载更新");
    pthread_mutex_lock(&statusLock);status.received=received;status.expected=expected;pthread_mutex_unlock(&statusLock);presented=YES;
}
void zw_update_test_ready(void){Publish(5,@"更新包已验证，可以准备安装");presented=YES;}
#endif
const char *zw_update_current_version(void){return Version().UTF8String;}
const char *zw_update_summary(void){static char text[2048];pthread_mutex_lock(&statusLock);strlcpy(text,status.message,sizeof(text));pthread_mutex_unlock(&statusLock);return text[0]?text:"从官方 GitHub Release 检查新版本";}
const char *zw_update_last_check(void){if(lastCheck<=0)return "尚未检查";NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=@"yyyy-MM-dd HH:mm";return [[@"上次检查：" stringByAppendingString:[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:lastCheck]]] UTF8String];}

#if ZW_UPDATE_TESTING
#import "native_fetch_tests.m"
#endif
