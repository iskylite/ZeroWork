#import "native.h"
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *directory,*recordFile;
static NSMutableDictionary *record;
static NSTextField *headline;
static NSTextView *detail;
static NSWindow *window;
static BOOL terminal=NO;
static BOOL repairRequested=NO;
static BOOL Exists(NSString *path){return [NSFileManager.defaultManager fileExistsAtPath:path];}
static void Surface(NSString *title, NSString *message){
    if([record[@"stage"] isEqual:@"prepared"] || [record[@"stage"] isEqual:@"waiting_parent"])return;
    if([record[@"stage"] isEqual:@"cancelled"] && !record[@"error"])return;

    dispatch_async(dispatch_get_main_queue(),^{headline.stringValue=title;NSDictionary *snapshot=directory?ZWRead([directory stringByAppendingPathComponent:@"record.json"]):nil;
        NSString *backup=snapshot[@"backup"];
        detail.string=[NSString stringWithFormat:@"%@%@\n\n恢复记录：%@",message,backup?[NSString stringWithFormat:@"\n\n应用备份：%@",backup]:@"",directory?:@""];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];});
}
static void Stage(NSString *stage){record[@"stage"]=stage;ZWWrite(recordFile,record);
#if ZW_UPDATE_TESTING
    const char *crash=getenv("ZW_UPDATE_CRASH_AT_STAGE");if(crash && [stage isEqual:[NSString stringWithUTF8String:crash]])_exit(95);
#endif
}
static BOOL ValidApp(NSString *path,NSString *version){@try{ZWVerifyApp(path,version);return YES;}@catch(NSException *e){return NO;}}
static BOOL Request(NSString *name){NSDictionary *r=ZWRead([directory stringByAppendingPathComponent:name]);return [r[@"nonce"] isEqual:record[@"nonce"]];}
static void Move(NSString *from,NSString *to){if(rename(from.fileSystemRepresentation,to.fileSystemRepresentation))ZWFail(@"应用目录移动失败");ZWSyncDirectory(from.stringByDeletingLastPathComponent);}
static void Restore(NSString *failure){
    NSString *target=record[@"target"],*backup=record[@"backup"];
    if(ZWAlive([record[@"new_pid"] intValue],[record[@"new_birth"] unsignedLongLongValue])){Stage(@"launch_failed_live");Surface(@"新版尚未退出",@"未恢复旧版，也未结束新版进程。请关闭新版后重新运行此安装程序，继续检查恢复条件。");return;}
    // A durable pre-grant marker is authoritative; missing/unknown marker never
    // proves unchanged if the new process had already been granted data access.
    if(![record[@"data_state"] isEqual:@"unchanged"] || Exists([directory stringByAppendingPathComponent:@"data-may-change.json"])){
        Stage(@"incompatible_data");Surface(@"需要安装兼容版本",@"新版可能已写入配置或迁移数据。旧应用备份已保留，禁止自动启动旧版。请从官方发布页安装兼容版本；不会自动回滚数据或重放任务。");return;
    }
    if(!backup || !ValidApp(backup,record[@"old_version"])){
        if(ValidApp(target,record[@"old_version"])){Stage(@"old_restored_verified");Surface(@"原版本仍可使用",failure);return;}
        Stage(@"restore_failed");Surface(@"旧版本恢复失败",@"未发现可验证的旧应用。请保留此目录及应用旁的备份，从官方发布页修复安装。关闭此窗口只隐藏提示，不会删除恢复信息。");return;
    }
    @try{
        if(Exists(target)){NSString *failed=[target.stringByDeletingLastPathComponent stringByAppendingFormat:@"/.ZeroWork.failed-%@.app",directory.lastPathComponent];if(Exists(failed))ZWFail(@"失败应用保留路径已存在");Move(target,failed);record[@"failed_app"]=failed;ZWWrite(recordFile,record);}
        Move(backup,target);ZWVerifyApp(target,record[@"old_version"]);Stage(@"old_restored_verified");
        Surface(@"已恢复并验证原版本",[failure stringByAppendingString:@"\n\n会话与远端任务不会自动重放。可重新打开 ZeroWork；工作区快照已保留。"]);
    }@catch(NSException *e){record[@"error"]=e.reason;Stage(@"restore_failed");Surface(@"旧版本恢复失败",e.reason);}
}
static void ObserveNew(void){
    pid_t pid=[record[@"new_pid"] intValue];uint64_t birth=[record[@"new_birth"] unsignedLongLongValue];double deadline=NSDate.date.timeIntervalSince1970+45;
    while(NSDate.date.timeIntervalSince1970<deadline){
        NSDictionary *startup=ZWRead([directory stringByAppendingPathComponent:@"startup.request"]);
        if([record[@"stage"] isEqual:@"new_started"] && [startup[@"nonce"] isEqual:record[@"nonce"]] && [startup[@"pid"] intValue]==pid && [startup[@"birth"] unsignedLongLongValue]==birth && [startup[@"version"] isEqual:record[@"version"]] && ZWAlive(pid,birth)){
            // Persist BEFORE main process is permitted to read/migrate its data.
            ZWWrite([directory stringByAppendingPathComponent:@"data-may-change.json"],@{@"pid":@(pid),@"birth":@(birth),@"nonce":record[@"nonce"]});
            record[@"data_state"]=@"potentially_changed";Stage(@"data_access_granted");
        }
        NSDictionary *healthy=ZWRead([directory stringByAppendingPathComponent:@"healthy.request"]);
        if([record[@"stage"] isEqual:@"data_access_granted"] && [healthy[@"nonce"] isEqual:record[@"nonce"]] && [healthy[@"version"] isEqual:record[@"version"]] && [healthy[@"pid"] intValue]==pid && [healthy[@"birth"] unsignedLongLongValue]==birth && ZWAlive(pid,birth)){
            ZWVerifyApp(record[@"target"],record[@"version"]);Stage(@"healthy");Surface(@"更新完成",@"新版已完成本地启动与工作区初始化。安装备份和诊断记录已保留。");return;
        }
        if(!ZWAlive(pid,birth)){Restore(@"新版未完成健康启动。");return;}
        usleep(100000);
    }
    Stage(@"readiness_unknown");Surface(@"新版启动状态尚未确认",@"新版仍在运行，未强制结束进程或覆盖应用。关闭新版后重新运行本安装程序，可继续检查恢复条件；若已访问数据，将只允许安装兼容版本。");
}
static void LaunchNew(void){
    ZWVerifyApp(record[@"target"],record[@"version"]);
    // Start the exact signed executable, with a one-time startup capability.
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:[record[@"target"] stringByAppendingPathComponent:@"Contents/MacOS/ZeroWork"]];
    NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];environment[@"ZW_UPDATE_TRANSACTION"]=directory.lastPathComponent;environment[@"ZW_UPDATE_NONCE"]=record[@"nonce"];task.environment=environment;
    record[@"new_pid"]=@0;record[@"new_birth"]=@0;Stage(@"launching_new");NSError *error=nil;
    if(![task launchAndReturnError:&error]){Restore(@"新版应用启动失败。");return;}
    pid_t pid=task.processIdentifier;uint64_t birth=0;for(int i=0;i<20&&!birth;i++){birth=ZWBirth(pid);if(!birth)usleep(10000);}
    if(!birth){[task waitUntilExit];Restore(@"新版在启动握手前已退出。");return;}
    record[@"new_pid"]=@(pid);record[@"new_birth"]=@(birth);Stage(@"new_started");ObserveNew();
}
static void Install(void){
    NSString *target=record[@"target"],*version=record[@"version"],*oldVersion=record[@"old_version"];
    NSString *staging=record[@"staging"],*backup=record[@"backup"];
    NSString *newApp=[staging stringByAppendingPathComponent:@"ZeroWork.app"];
    NSString *stage=record[@"stage"];
    if([@[@"new_started",@"data_access_granted",@"readiness_unknown",@"launch_failed_live"] containsObject:stage]){
        if(ZWAlive([record[@"new_pid"] intValue],[record[@"new_birth"] unsignedLongLongValue]))ObserveNew();else Restore(@"安装中断后，新版已退出。");return;
    }
    if([stage isEqual:@"launching_new"]){
        // Crash between spawn and durable PID publication leaves unknown process
        // identity. Never infer release from a missing PID or launch a duplicate.
        record[@"data_state"]=@"unknown";Stage(@"recovery_unknown_process");Surface(@"需要人工确认启动状态",@"安装程序在新版启动握手中断。进程身份尚未确认，禁止自动恢复旧版或重复启动新版。请保留记录并安装兼容版本。");return;
    }
    if([@[@"incompatible_data",@"recovery_unknown_process"] containsObject:stage]){Surface(@"需要安装兼容版本",@"数据或进程状态无法证明适合旧版。应用备份与记录已保留，请从官方发布页修复。");return;}
    if([stage isEqual:@"restore_failed"]){Restore(@"重新检查恢复条件。");return;}
    // Reconcile actual disk contents after a crash, including rename-before-record.
    if(ValidApp(target,version) && ValidApp(backup,oldVersion)){Stage(@"new_placed");LaunchNew();return;}
    if(!ValidApp(newApp,version)){Restore(@"新版暂存包缺失或验证失败。");return;}
    if(!Exists(backup)){
        ZWVerifyApp(target,oldVersion);Move(target,backup);
    }
    ZWVerifyApp(backup,oldVersion);Stage(@"backup_verified");
    if(Exists(target))ZWFail(@"目标位置已有其他应用，未覆盖任何目录");
    Move(newApp,target);ZWVerifyApp(target,version);Stage(@"new_placed");LaunchNew();
}
static void Run(void){
    int lock=-1;
    @try{
        NSArray *args=NSProcessInfo.processInfo.arguments;
        if(args.count==1){NSString *executable=ZWCanonical(args[0]);NSString *candidate=executable.stringByDeletingLastPathComponent;if(Exists([candidate stringByAppendingPathComponent:@"record.json"]))args=@[executable,candidate];}
        if(args.count!=2)ZWFail(@"请从 ZeroWork 更新入口启动安装，或打开保留的事务目录内的安装程序");directory=ZWCanonical(args[1]);
        ZWVerifyCode(ZWCanonical(args[0]),@"com.zerowork.updater");
        recordFile=[directory stringByAppendingPathComponent:@"record.json"];record=[ZWRead(recordFile) mutableCopy];if(!record)ZWFail(@"事务记录无效");
        NSString *root=ZWRoot(record[@"target"],record[@"data"]);ZWPrivateDirectory(root);ZWPrivateDirectory(directory);
        if(![directory.stringByDeletingLastPathComponent isEqual:root] || ![directory.lastPathComponent hasPrefix:@"txn-"] || ![ZWCanonical(args[0]) isEqual:[directory stringByAppendingPathComponent:@"ZeroWorkUpdater"]])ZWFail([NSString stringWithFormat:@"事务路径验证失败：目录 %@；预期根目录 %@；执行路径 %@",directory,root,args[0]]);
        NSDictionary *active=ZWRead([root stringByAppendingPathComponent:@"active.json"]);if(![active[@"transaction"] isEqual:directory])ZWFail(@"事务不是当前活动安装");
        lock=open([root stringByAppendingPathComponent:@"installer.lock"].fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW,0600);
        if(lock<0 || flock(lock,LOCK_EX|LOCK_NB))ZWFail(@"另一个安装程序正在处理此应用");
        record[@"helper_pid"]=@(getpid());record[@"helper_birth"]=@(ZWBirth(getpid()));ZWWrite(recordFile,record);
        if([@[@"healthy",@"old_restored_verified",@"cancelled",@"aborted_before_replace"] containsObject:record[@"stage"]]){Surface(@"此安装事务已结束",@"历史事务不会重新获得安装授权。可关闭此窗口；重新更新时会创建新的事务。");return;}
        if([record[@"decision"] isEqual:@"committed"] && ![record[@"stage"] isEqual:@"waiting_parent"]){
            if((repairRequested || Request(@"repair.request")) && [@[@"incompatible_data",@"recovery_unknown_process"] containsObject:record[@"stage"]]) {
                if(ZWAlive([record[@"new_pid"] intValue],[record[@"new_birth"] unsignedLongLongValue]))ZWFail(@"新版仍在运行，请先关闭后修复");
                NSString *candidate=[NSDictionary dictionaryWithContentsOfFile:[record[@"target"] stringByAppendingPathComponent:@"Contents/Info.plist"]][@"ZeroWorkReleaseVersion"];
                if(![candidate isEqual:record[@"version"]] && (!candidate || !zw_update_newer(candidate.UTF8String,[record[@"version"] UTF8String])))ZWFail(@"修复包版本过低，未启动旧应用");
                ZWVerifyApp(record[@"target"],candidate);record[@"version"]=candidate;record[@"nonce"]=NSUUID.UUID.UUIDString;Stage(@"new_placed");LaunchNew();return;
            }
            Install();return;
        }
        if([record[@"decision"] isEqual:@"undecided"]){
            NSString *target=record[@"target"];pid_t parent=[record[@"parent_pid"] intValue];uint64_t birth=[record[@"parent_birth"] unsignedLongLongValue];
            char processPath[PROC_PIDPATHINFO_MAXSIZE]={0};proc_pidpath(parent,processPath,sizeof(processPath));
            if(!ZWAlive(parent,birth) || ![ZWCanonical([NSString stringWithUTF8String:processPath]) isEqual:[target stringByAppendingPathComponent:@"Contents/MacOS/ZeroWork"]])ZWFail(@"原应用进程身份不匹配，未授权安装");
            ZWVerifyApp(target,record[@"old_version"]);
            NSData *envelope=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"envelope.json"]];NSDictionary *m=ZWManifest(envelope);
            if(![m[@"version"] isEqual:record[@"version"]] || !zw_update_newer([m[@"version"] UTF8String],[record[@"old_version"] UTF8String]))ZWFail(@"安装版本未通过独立校验");
            NSString *zip=[directory stringByAppendingPathComponent:@"update.zip"];struct stat st;
            if(lstat(zip.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || st.st_size!=[m[@"bytes"] unsignedLongLongValue] || ![ZWSHA256(zip) isEqual:m[@"sha256"]])ZWFail(@"独立安装程序的包校验失败");
            NSString *staging=[target.stringByDeletingLastPathComponent stringByAppendingFormat:@"/.ZeroWork.staging-%@",directory.lastPathComponent];
            NSString *backup=[target.stringByDeletingLastPathComponent stringByAppendingFormat:@"/.ZeroWork.backup-%@.app",directory.lastPathComponent];
            if(Exists(staging) || Exists(backup))ZWFail(@"暂存或备份路径已存在，未覆盖");
            record[@"staging"]=staging;record[@"backup"]=backup;ZWWrite(recordFile,record);
            ZWExtract(zip,staging,[m[@"expanded_bytes"] unsignedLongLongValue]);ZWVerifyApp([staging stringByAppendingPathComponent:@"ZeroWork.app"],m[@"version"]);Stage(@"prepared");
            Surface(@"更新已准备",@"正在等待主应用提交安装或取消。本阶段尚未获得替换应用的权限。");
            double deadline=NSDate.date.timeIntervalSince1970+120;
            while([record[@"decision"] isEqual:@"undecided"]){
                // This single owner serializes durable decisions. ACK is the
                // atomic record; a late cancel can never rewrite committed.
                if(Request(@"cancel.request") || !ZWAlive(parent,birth) || NSDate.date.timeIntervalSince1970>deadline){record[@"decision"]=@"cancelled";Stage(@"cancelled");Surface(@"安装已取消",@"应用未被替换。已验证包和工作区快照已保留。");return;}
                if(Request(@"commit.request")){record[@"decision"]=@"committed";Stage(@"waiting_parent");break;}usleep(50000);
            }
        }
        if(![record[@"decision"] isEqual:@"committed"])ZWFail(@"未获得安装提交授权");
        Surface(@"正在等待应用正常退出",@"不会强制结束主应用。若退出超时，将撤销本次替换阶段。");
        double deadline=NSDate.date.timeIntervalSince1970+30;
        while(ZWAlive([record[@"parent_pid"] intValue],[record[@"parent_birth"] unsignedLongLongValue])){
            if(NSDate.date.timeIntervalSince1970>deadline){Stage(@"aborted_before_replace");Surface(@"应用退出超时",@"应用尚未替换，本次退出授权已撤销。稍后退出应用也不会触发此事务安装。请返回应用重试。");return;}usleep(50000);
        }
        Stage(@"parent_released");Install();
    }@catch(NSException *e){
        @try{record[@"error"]=e.reason?:@"安装失败";
            if([record[@"decision"] isEqual:@"committed"] && record[@"backup"])Restore(e.reason);
            else{if(record){record[@"decision"]=@"cancelled";Stage(@"cancelled");}Surface(@"安装准备失败，应用未替换",e.reason);}
        }@catch(NSException *writeError){Surface(@"更新恢复信息需要保留",[NSString stringWithFormat:@"%@\n%@",e.reason,writeError.reason]);}
    }@finally{if(lock>=0){flock(lock,LOCK_UN);close(lock);}terminal=YES;
#if ZW_UPDATE_TESTING
        if(getenv("ZW_UPDATE_HEADLESS"))return;
#endif
        if([record[@"stage"] isEqual:@"cancelled"] && !record[@"error"])dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});}
}
@interface ZWRecoveryActions:NSObject
@end
@implementation ZWRecoveryActions
- (void)repair:(id)sender{if(!terminal)return;repairRequested=YES;terminal=NO;dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{Run();});}
- (void)releasePage:(id)sender{[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:ZWReleases]];}
- (void)diagnostics:(id)sender{if(directory)[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:directory]];}
- (void)hide:(id)sender{[window orderOut:nil];if(terminal)[NSApp terminate:nil];}
@end
void zw_update_helper_main(void){@autoreleasepool{
#if ZW_UPDATE_TESTING
    if(getenv("ZW_UPDATE_HEADLESS")){Run();return;}
#endif
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,520,378) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];window.title=@"ZeroWork 更新";[window center];window.releasedWhenClosed=NO;
    NSArray *args=NSProcessInfo.processInfo.arguments;if(args.count==2){directory=args[1];NSDictionary *r=ZWRead([directory stringByAppendingPathComponent:@"record.json"]);NSArray *c=r[@"theme"];if(c.count==16){window.backgroundColor=[NSColor colorWithRed:[c[0] doubleValue] green:[c[1] doubleValue] blue:[c[2] doubleValue] alpha:1];window.appearance=[NSAppearance appearanceNamed:([c[0] doubleValue]*.299+[c[1] doubleValue]*.587+[c[2] doubleValue]*.114<.5)?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];}}
    headline=[NSTextField labelWithString:@"正在检查安装事务…"];headline.frame=NSMakeRect(24,316,472,28);headline.font=[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];[window.contentView addSubview:headline];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(24,76,472,224)];scroll.hasVerticalScroller=YES;scroll.drawsBackground=NO;detail=[[NSTextView alloc] initWithFrame:scroll.bounds];detail.editable=NO;detail.drawsBackground=NO;detail.font=[NSFont systemFontOfSize:12];NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.minimumLineHeight=18;paragraph.maximumLineHeight=18;detail.defaultParagraphStyle=paragraph;detail.textContainerInset=NSMakeSize(0,6);detail.autoresizingMask=NSViewWidthSizable;scroll.documentView=detail;[window.contentView addSubview:scroll];
    NSDictionary *initial=directory?ZWRead([directory stringByAppendingPathComponent:@"record.json"]):nil;NSArray *colors=initial[@"theme"];if(colors.count==16){NSColor *ink=[NSColor colorWithRed:[colors[4] doubleValue] green:[colors[5] doubleValue] blue:[colors[6] doubleValue] alpha:1];headline.textColor=ink;detail.textColor=ink;}
    ZWRecoveryActions *actions=[ZWRecoveryActions new];NSArray *titles=@[@"官方发布页",@"恢复记录",@"检查修复",@"关闭"];NSArray *selectors=@[NSStringFromSelector(@selector(releasePage:)),NSStringFromSelector(@selector(diagnostics:)),NSStringFromSelector(@selector(repair:)),NSStringFromSelector(@selector(hide:))];
    for(int i=0;i<4;i++){NSButton *button=[NSButton buttonWithTitle:titles[i] target:actions action:NSSelectorFromString(selectors[i])];button.frame=NSMakeRect(24+i*120,22,112,32);if(colors.count==16){button.contentTintColor=[NSColor colorWithRed:[colors[4] doubleValue] green:[colors[5] doubleValue] blue:[colors[6] doubleValue] alpha:1];if(i==0){button.bezelColor=[NSColor colorWithRed:[colors[12] doubleValue] green:[colors[13] doubleValue] blue:[colors[14] doubleValue] alpha:1];button.contentTintColor=NSColor.whiteColor;}}[window.contentView addSubview:button];}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{Run();});[NSApp run];
}}
