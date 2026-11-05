#import "native.h"
#import <AppKit/AppKit.h>
#import <unistd.h>
extern int zw_update_startup_gate(const char *);
extern void zw_update_healthy(void);
#if ZW_UPDATE_TESTING
extern void zw_update_test_fetch_contracts(void);
extern int zw_update_test_seed_verified(const char *,const char *);
extern void zw_update_start(int);
extern void zw_update_prepare(const char *,const float *);
extern void zw_update_command(int);
extern void zw_update_tick(void);
extern void zw_update_status(ZWUpdateStatus *);
static ZWUpdateStatus RuntimeStatus(void){zw_update_tick();ZWUpdateStatus s;zw_update_status(&s);return s;}
static void RuntimeWait(int wanted){double end=NSDate.date.timeIntervalSince1970+25;while(RuntimeStatus().state!=wanted){if(NSDate.date.timeIntervalSince1970>end)ZWFail([NSString stringWithFormat:@"runtime 状态未到达 %d，实际 %d",wanted,RuntimeStatus().state]);[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}}
static void Runtime(NSArray *args){
    if(args.count!=6)ZWFail(@"runtime fixture 参数无效");NSString *scenario=args[2],*data=args[3];
    if(!zw_update_startup_gate(data.UTF8String))ZWFail(@"测试启动门禁拒绝");zw_update_start(0);
    if(!zw_update_test_seed_verified([args[4] UTF8String],[args[5] UTF8String]))ZWFail(@"已签名测试种子校验失败");
    float theme[16]={.1,.1,.1,1,.9,.9,.9,1,.6,.6,.6,1,.2,.5,.8,1};double began=NSDate.date.timeIntervalSince1970;
    zw_update_prepare([scenario isEqual:@"prepare-failed-cancel"]?"invalid-json":"{\"phase\":\"before-close\",\"replay_tasks\":false}",theme);double prepareElapsed=NSDate.date.timeIntervalSince1970-began;
    if(prepareElapsed>.25)ZWFail(@"prepare 阻塞主线程");
    BOOL held=[scenario isEqual:@"prepare-immediate-cancel"];double cancelElapsed=0;
    if(held){
        NSString *hold=NSProcessInfo.processInfo.environment[@"ZW_UPDATE_TEST_PREPARE_HOLD"];double end=NSDate.date.timeIntervalSince1970+5;
        while(access([[hold stringByAppendingString:@".entered"] fileSystemRepresentation],F_OK)){if(NSDate.date.timeIntervalSince1970>end)ZWFail(@"prepare 未进入测试屏障");usleep(1000);}
        began=NSDate.date.timeIntervalSince1970;zw_update_command(5);cancelElapsed=NSDate.date.timeIntervalSince1970-began;
        if(cancelElapsed>.25)ZWFail(@"取消请求阻塞主线程");
        for(int i=0;i<15;i++){if(RuntimeStatus().state!=6)ZWFail(@"durable ACK 前提前宣称取消");[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}
        ZWWrite(hold,@{});
    }else if([scenario isEqual:@"prepare-failed-cancel"]){zw_update_command(5);}
    else{RuntimeWait(7);if([scenario isEqual:@"commit-wins-late-cancel"]){zw_update_command(4);RuntimeWait(8);zw_update_command(5);}else{zw_update_command(5);if([scenario isEqual:@"cancel-wins-late-commit"])zw_update_command(4);}}
    int expected=[scenario isEqual:@"commit-wins-late-cancel"]?8:9;RuntimeWait(expected);
    NSString *root=ZWRoot(ZWCanonical(NSBundle.mainBundle.bundlePath),data);NSString *path=ZWRead([root stringByAppendingPathComponent:@"active.json"])[@"transaction"];NSDictionary *r=path?ZWRead([path stringByAppendingPathComponent:@"record.json"]):nil;
    if(expected==8 || [scenario isEqual:@"cancel-wins-late-commit"]){NSString *request=[path stringByAppendingPathComponent:expected==8?@"cancel.request":@"commit.request"];double end=NSDate.date.timeIntervalSince1970+5;while(access(request.fileSystemRepresentation,F_OK)){if(NSDate.date.timeIntervalSince1970>end)ZWFail(@"晚到请求未写入原事务");[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}if(RuntimeStatus().state!=expected)ZWFail(@"晚到请求改变了终态决定");}
    if(r && ![r[@"decision"] isEqual:expected==8?@"committed":@"cancelled"])ZWFail(@"runtime 状态没有绑定持久决定");
    NSDictionary *report=@{@"scenario":scenario,@"state":@(expected),@"decision":r[@"decision"]?:@"no-transaction",@"transaction":path?:@"",@"prepare_seconds":@(prepareElapsed),@"cancel_seconds":@(cancelElapsed),@"ack_wait_while_prepare_held":@(held)};
    puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
}
#endif
void zw_update_fixture_main(void){@autoreleasepool{
    NSArray *args=NSProcessInfo.processInfo.arguments;
    @try{
#if ZW_UPDATE_TESTING
        if(args.count>1 && [args[1] isEqual:@"--fetch-contracts"]){zw_update_test_fetch_contracts();return;}
        if(args.count>1 && [args[1] isEqual:@"--runtime"]){Runtime(args);return;}
#endif
        if(args.count>2 && [args[1] isEqual:@"--birth"]){printf("%llu\n",ZWBirth([args[2] intValue]));return;}
        if(args.count>2 && [args[1] isEqual:@"--manifest"]){ZWManifest([NSData dataWithContentsOfFile:args[2]]);puts("valid");return;}
        if(args.count>4 && [args[1] isEqual:@"--extract"]){ZWExtract(args[2],args[3],[args[4] longLongValue]);puts("valid");return;}
        if(args.count>3 && [args[1] isEqual:@"--verify-app"]){ZWVerifyApp(args[2],args[3]);puts("valid");return;}
        if(args.count>2 && [args[1] isEqual:@"--parent"]){printf("%d %llu\n",getpid(),ZWBirth(getpid()));fflush(stdout);while(access([args[2] fileSystemRepresentation],F_OK))usleep(20000);return;}
        NSDictionary *env=NSProcessInfo.processInfo.environment;NSString *mode=env[@"ZW_UPDATE_FIXTURE_MODE"]?:@"healthy";
        if([mode isEqual:@"early-crash"])exit(42);
        if([mode isEqual:@"before-gate-wait"]){while(access([env[@"ZW_UPDATE_FIXTURE_NEW_STOP"] fileSystemRepresentation],F_OK))usleep(20000);exit(42);}
        if(!zw_update_startup_gate([env[@"ZW_UPDATE_FIXTURE_DATA"] UTF8String]))exit(43);
        if([mode isEqual:@"changed-crash"])exit(44);
        zw_update_healthy();sleep(2);
    }@catch(NSException *e){fprintf(stderr,"%s\n",e.reason.UTF8String);exit(45);}
}}
