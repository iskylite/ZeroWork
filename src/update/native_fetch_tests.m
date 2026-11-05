// Included only in the disposable test runtime; production has no transport injection.
static NSString *fetchScenario;
static _Atomic(int) fetchRequests;
@interface ZWUpdateMockProtocol : NSURLProtocol
@end
@implementation ZWUpdateMockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)startLoading{
    fetchRequests++;
    NSString *path=self.request.URL.path;NSInteger code=404;NSData *data=[NSData data];NSDictionary *headers=@{};
    if([fetchScenario isEqual:@"timeout"]){[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];return;}
    if([path isEqual:@"/repos/iskylite/ZeroWork"]){code=[fetchScenario isEqual:@"missing-repo"]?404:200;data=[@"{\"full_name\":\"iskylite/ZeroWork\",\"private\":false}" dataUsingEncoding:NSUTF8StringEncoding];}
    else if([path hasSuffix:@"/releases/latest"]){
        if([fetchScenario isEqual:@"api-denied"])code=403;
        else if([fetchScenario isEqual:@"invalid-probe"]){code=200;data=[@"[]" dataUsingEncoding:NSUTF8StringEncoding];}
        else if([fetchScenario isEqual:@"missing-feed"] || [fetchScenario isEqual:@"unavailable-feed"]){
            code=200;id assets=[fetchScenario isEqual:@"missing-feed"]?@[]:@[@{@"name":@"update.json"}];
            data=[NSJSONSerialization dataWithJSONObject:@{@"tag_name":@"v0.3.0",@"draft":@NO,@"prerelease":@NO,@"assets":assets} options:0 error:nil];
        }
    }else if([fetchScenario isEqual:@"server"]){code=503;}
    else if([fetchScenario isEqual:@"oversize"]){code=200;headers=@{@"Content-Length":@"65537"};}
    else if([fetchScenario isEqual:@"chunk-oversize"]){code=200;data=[NSMutableData dataWithLength:65537];}
    else if([fetchScenario isEqual:@"verify"]){code=200;data=[@"test" dataUsingEncoding:NSUTF8StringEncoding];}
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if(data.length)[self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading{}
@end
static ZWUpdateStatus FetchTestWait(void){
    double deadline=NSDate.date.timeIntervalSince1970+5;ZWUpdateStatus s;
    do{
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
        zw_update_status(&s);
        if(s.state!=1 && s.state!=3 && s.state!=4)return s;
    }while(NSDate.date.timeIntervalSince1970<deadline);
    ZWFail(@"更新网络测试超时");return s;
}
static void FetchTestAssert(BOOL value,NSString *name){if(!value)ZWFail([@"更新网络测试失败：" stringByAppendingString:name]);}
void zw_update_test_fetch_contracts(void){
    NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"zw-fetch-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *savedRoot=rootPath;rootPath=temporary;ZWPrivateDirectory(rootPath);automatic=NO;fetchProtocol=ZWUpdateMockProtocol.class;
    NSMutableArray *checks=[NSMutableArray array];
    @try{
        for(NSString *scenario in @[@"no-stable",@"missing-feed",@"unavailable-feed",@"api-denied",@"missing-repo",@"invalid-probe",@"server",@"oversize",@"chunk-oversize",@"timeout"]){
            fetchScenario=scenario;fetchRequests=0;Fetch(NO);ZWUpdateStatus s=FetchTestWait();NSString *message=[NSString stringWithUTF8String:s.message];
            FetchTestAssert(s.state==([scenario isEqual:@"no-stable"]?12:10),scenario);
            if(s.state==10)FetchTestAssert(s.failure_stage==1,[@"check stage: " stringByAppendingString:scenario]);
            if([scenario isEqual:@"no-stable"])FetchTestAssert(fetchRequests==3 && !s.version[0],@"no stable requires accessible public repository");
            if([scenario isEqual:@"missing-feed"])FetchTestAssert([message containsString:@"缺少自动更新清单"],scenario);
            if([scenario isEqual:@"unavailable-feed"])FetchTestAssert([message containsString:@"暂不可用"],scenario);
            if([scenario isEqual:@"server"])FetchTestAssert([message containsString:@"503"] && ![message containsString:@"大小"],scenario);
            if([scenario containsString:@"oversize"])FetchTestAssert([message containsString:@"大小限制"],scenario);
            if([scenario isEqual:@"timeout"])FetchTestAssert([message containsString:@"超时"] && [message containsString:@"-1001"],scenario);
            [checks addObject:scenario];
        }
        // A failed check and a confirmed empty stable channel both remain schedulable.
        for(NSString *scenario in @[@"server",@"no-stable"]){
            fetchScenario=scenario;Fetch(NO);ZWUpdateStatus s=FetchTestWait();uint64_t generation=s.generation;
            automatic=YES;zw_update_tick();FetchTestAssert(Generation()==generation,@"24 hour limit");
            lastCheck-=86401;zw_update_tick();FetchTestAssert(Generation()==generation+1,@"scheduled retry after check failure/no stable");FetchTestWait();automatic=NO;
        }
        [checks addObject:@"24-hour-retry-and-throttle"];
        // Package errors keep their own phase and cannot trigger an automatic recheck.
        fetchScenario=@"server";manifest=@{@"bytes":@4,@"url":ZWFeed};Fetch(YES);ZWUpdateStatus s=FetchTestWait();
        FetchTestAssert(s.state==10 && s.failure_stage==3,@"download failure stage");
        uint64_t generation=s.generation;automatic=YES;lastCheck-=86401;zw_update_tick();automatic=NO;
        FetchTestAssert(Generation()==generation,@"download failure does not trigger periodic check");
        [checks addObject:@"download-error-stage-and-scheduling"];
        fetchScenario=@"verify";manifest=@{@"bytes":@4,@"url":ZWFeed,@"sha256":@"incorrect"};Fetch(YES);s=FetchTestWait();
        FetchTestAssert(s.state==10 && s.failure_stage==4,@"verification failure stage");[checks addObject:@"verification-error-stage"];
        // A superseded probe must not overwrite a newer result.
        fetchScenario=@"no-stable";Fetch(NO);Fetch(NO);s=FetchTestWait();FetchTestAssert(s.state==12,@"superseded request");[checks addObject:@"superseded-check"];
        puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"status":@"passed",@"checks":checks} options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding].UTF8String);
    }@finally{
        [fetch.session invalidateAndCancel];fetch=nil;fetchProtocol=Nil;manifest=nil;manifestEnvelope=nil;rootPath=savedRoot;
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    }
}
