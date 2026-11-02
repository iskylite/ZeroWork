#import "native.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <libproc.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import "archive_abi.h"

NSString *const ZWFeed = @"https://github.com/iskylite/ZeroWork/releases/latest/download/update.json";
NSString *const ZWReleases = @"https://github.com/iskylite/ZeroWork/releases";
void ZWFail(NSString *message) { @throw [NSException exceptionWithName:@"ZeroWorkUpdate" reason:message userInfo:nil]; }
static NSData *JSON(id object) {
    NSError *error = nil; NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    if (!data) ZWFail(@"更新记录无法编码"); return data;
}
NSDictionary *ZWRead(NSString *path) {
    struct stat st; if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_size > 1024*1024) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingUncached error:nil];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
void ZWSyncDirectory(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if (fd < 0) ZWFail(@"无法打开更新目录");
    int result = fsync(fd); close(fd); if (result) ZWFail(@"更新目录持久化失败");
}
void ZWWrite(NSString *path, id json) {
    NSData *data = JSON(json);
    NSString *temp = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int fd = open(temp.fileSystemRepresentation, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600);
    if (fd < 0) ZWFail(@"更新记录无法创建");
    const uint8_t *bytes = data.bytes; size_t left = data.length;
    while (left) { ssize_t n = write(fd, bytes, left); if (n <= 0) { close(fd); unlink(temp.fileSystemRepresentation); ZWFail(@"更新记录写入失败"); } bytes += n; left -= n; }
    int result = fsync(fd); close(fd);
    if (result || rename(temp.fileSystemRepresentation, path.fileSystemRepresentation)) { unlink(temp.fileSystemRepresentation); ZWFail(@"更新记录无法持久化"); }
    ZWSyncDirectory(path.stringByDeletingLastPathComponent);
}
void ZWPrivateDirectory(NSString *path) {
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) ZWFail(@"无法创建私有更新目录");
    struct stat st; if (lstat(path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0077)) ZWFail(@"更新目录权限不安全");
}
NSString *ZWCanonical(NSString *path) {
    if(!path.length || !path.isAbsolutePath)ZWFail(@"更新路径必须是绝对路径");
    char *value=realpath(path.fileSystemRepresentation,NULL);
    if(value){NSString *result=[NSString stringWithUTF8String:value];free(value);return result;}
    NSString *parent=path.stringByDeletingLastPathComponent;
    if([parent isEqual:path])ZWFail(@"更新路径无法解析");
    return [ZWCanonical(parent) stringByAppendingPathComponent:path.lastPathComponent];
}
NSString *ZWRoot(NSString *target, NSString *data) {
    NSData *identity = [[NSString stringWithFormat:@"%@\n%@", ZWCanonical(target), ZWCanonical(data)] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(identity.bytes, (CC_LONG)identity.length, hash);
    NSMutableString *hex = [NSMutableString string]; for (int i=0;i<16;i++) [hex appendFormat:@"%02x",hash[i]];
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/com.zerowork.updater"] stringByAppendingPathComponent:hex];
}
uint64_t ZWBirth(pid_t pid) {
    struct proc_bsdinfo info = {0}; if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}
BOOL ZWAlive(pid_t pid, uint64_t birth) { return birth != 0 && ZWBirth(pid) == birth; }
static NSString *Text(id value, NSUInteger max) {
    if (![value isKindOfClass:NSString.class] || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > max || [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,1)]].location != NSNotFound) ZWFail(@"更新描述字段无效"); return value;
}
static uint64_t Number(id value, uint64_t max) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() || [value doubleValue] < 1 || [value doubleValue] > max || [value doubleValue] != [value unsignedLongLongValue]) ZWFail(@"更新描述大小无效"); return [value unsignedLongLongValue];
}
BOOL ZWValidHTTPS(NSURL *url, BOOL redirects) {
    if (![url.scheme isEqual:@"https"] || url.user || url.password || url.fragment || (url.port && url.port.intValue != 443)) return NO;
    NSString *host = url.host.lowercaseString;
    if ([host isEqual:@"github.com"]) return [url.path hasPrefix:@"/iskylite/ZeroWork/releases/"] && !url.query;
    return redirects && ([host isEqual:@"release-assets.githubusercontent.com"] || [host isEqual:@"objects.githubusercontent.com"]);
}
NSDictionary *ZWManifest(NSData *envelope) {
    if (envelope.length > 65536) ZWFail(@"更新描述超过大小限制");
    id object = [NSJSONSerialization JSONObjectWithData:envelope options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class] || [object count] != 3) ZWFail(@"更新描述格式无效");
    NSDictionary *trust = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:zw_update_trust_json()] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![Text(object[@"key_id"],64) isEqual:trust[@"key_id"]]) ZWFail(@"更新签名密钥不受信任");
    NSData *payload = [[NSData alloc] initWithBase64EncodedString:Text(object[@"payload_base64"],60000) options:0];
    NSData *signature = [[NSData alloc] initWithBase64EncodedString:Text(object[@"signature_base64"],128) options:0];
    NSData *key = [[NSData alloc] initWithBase64EncodedString:trust[@"public_key"] options:0];
    if (!payload || signature.length != 64 || key.length != 32 || !zw_update_verify_signature(key.bytes,signature.bytes,payload.bytes,payload.length)) ZWFail(@"更新签名验证失败");
    id m = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![m isKindOfClass:NSDictionary.class] || [m count] != 10 || Number(m[@"schema"],1) != 1) ZWFail(@"不支持此更新描述版本");
    NSString *version = Text(m[@"version"],80);
    if (!zw_update_newer(version.UTF8String,"0.0.0")) ZWFail(@"自动更新只支持稳定版本");
    if (![Text(m[@"arch"],16) isEqual:@"arm64"]) ZWFail(@"更新包架构不匹配");
    NSString *minimum = Text(m[@"minimum_os"],32);
    if (![minimum length] || [minimum rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]].location != NSNotFound) ZWFail(@"最低系统版本无效");
    if ([[NSProcessInfo processInfo].operatingSystemVersionString length] && [minimum compare:[NSString stringWithFormat:@"%ld.%ld.%ld", NSProcessInfo.processInfo.operatingSystemVersion.majorVersion,NSProcessInfo.processInfo.operatingSystemVersion.minorVersion,NSProcessInfo.processInfo.operatingSystemVersion.patchVersion] options:NSNumericSearch] == NSOrderedDescending) ZWFail(@"新版要求更高的 macOS 版本");
    NSString *url = [NSString stringWithFormat:@"https://github.com/iskylite/ZeroWork/releases/download/v%@/ZeroWork-%@-arm64.zip",version,version];
    if (![Text(m[@"url"],1024) isEqual:url] || !ZWValidHTTPS([NSURL URLWithString:url],NO)) ZWFail(@"更新包地址与版本不匹配");
    if (![Text(m[@"release_url"],1024) isEqual:[NSString stringWithFormat:@"%@/tag/v%@",ZWReleases,version]]) ZWFail(@"发布说明地址无效");
    Number(m[@"bytes"],1024ULL*1024*1024); Number(m[@"expanded_bytes"],2ULL*1024*1024*1024);
    NSString *hash = Text(m[@"sha256"],64);
    if (hash.length != 64 || [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) ZWFail(@"SHA256 无效");
    Text(m[@"notes"],16384); return m;
}
NSString *ZWSHA256(NSString *path) {
    int fd = open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW); if(fd<0) ZWFail(@"无法读取更新包");
    CC_SHA256_CTX context; CC_SHA256_Init(&context); unsigned char buffer[65536],hash[32]; ssize_t n;
    while ((n=read(fd,buffer,sizeof(buffer)))>0) CC_SHA256_Update(&context,buffer,(CC_LONG)n);
    close(fd); if(n<0) ZWFail(@"更新包读取失败"); CC_SHA256_Final(hash,&context);
    NSMutableString *hex=[NSMutableString string]; for(int i=0;i<32;i++) [hex appendFormat:@"%02x",hash[i]]; return hex;
}
void ZWVerifyApp(NSString *path, NSString *version) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    if (![info[@"CFBundleIdentifier"] isEqual:@"com.zerowork.app"] || ![info[@"ZeroWorkReleaseVersion"] isEqual:version] || ![info[@"CFBundleExecutable"] isEqual:@"ZeroWork"]) ZWFail(@"应用标识或版本不匹配");
    NSData *header = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/MacOS/ZeroWork"] options:NSDataReadingMappedIfSafe error:nil];
    if (header.length < 8 || ((const uint32_t *)header.bytes)[0] != 0xfeedfacf || ((const uint32_t *)header.bytes)[1] != 0x0100000c) ZWFail(@"应用不是 arm64 Mach-O");
    ZWVerifyCode(path,@"com.zerowork.app");
}
void ZWVerifyCode(NSString *path, NSString *identifier) {
    NSDictionary *trust=[NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:zw_update_trust_json()] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSString *requirement=[NSString stringWithFormat:@"identifier \"%@\" and certificate leaf = H\"%@\"",identifier,trust[@"certificate_sha1"]];
    SecRequirementRef req=NULL; SecStaticCodeRef code=NULL;
    OSStatus result=SecRequirementCreateWithString((__bridge CFStringRef)requirement,kSecCSDefaultFlags,&req);
    if(result==errSecSuccess) result=SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path],kSecCSDefaultFlags,&code);
    if(result==errSecSuccess) result=SecStaticCodeCheckValidity(code,kSecCSStrictValidate|kSecCSCheckAllArchitectures|kSecCSCheckNestedCode,req);
    if(code) CFRelease(code); if(req) CFRelease(req); if(result!=errSecSuccess) ZWFail(@"代码签名或固定签名者验证失败");
}
static BOOL SafeRelative(NSString *name) {
    if (!name.length || [name hasPrefix:@"/"] || [name containsString:@"\\"] || [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,1)]].location != NSNotFound) return NO;
    for(NSString *part in name.pathComponents) if([part isEqual:@".."] || [part isEqual:@"."]) return NO;
    return [name isEqual:@"ZeroWork.app"] || [name hasPrefix:@"ZeroWork.app/"];
}
static int ParentFD(int root, NSString *name, NSString **leaf) {
    NSArray *parts=name.pathComponents; int fd=dup(root); if(fd<0) ZWFail(@"无法读取暂存目录");
    for(NSUInteger i=0;i+1<parts.count;i++) {
        const char *part=[parts[i] fileSystemRepresentation];
        if(mkdirat(fd,part,0700) && errno!=EEXIST) { close(fd); ZWFail(@"无法创建包目录"); }
        int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);close(fd);if(next<0) ZWFail(@"包目录包含链接或无效路径");fd=next;
    }
    *leaf=parts.lastObject;return fd;
}
void ZWExtract(NSString *zip, NSString *destination, uint64_t limit) {
    ZWPrivateDirectory(destination); int root=open(destination.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);if(root<0) ZWFail(@"暂存目录不可用");
    struct archive *a=archive_read_new(); archive_read_support_format_zip(a);archive_read_support_filter_none(a);
    NSMutableArray *links=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];uint64_t total=0;NSUInteger count=0;
    @try {
        if(archive_read_open_filename(a,zip.fileSystemRepresentation,65536)!=ARCHIVE_OK) ZWFail(@"ZIP 无法打开");
        struct archive_entry *entry;int result;
        while((result=archive_read_next_header(a,&entry))==ARCHIVE_OK) {
            const char *raw=archive_entry_pathname_utf8(entry);NSString *name=raw?[NSString stringWithUTF8String:raw]:nil;
            if(!SafeRelative(name) || ++count>50000 || archive_entry_hardlink(entry) || archive_entry_is_encrypted(entry)) ZWFail(@"ZIP 包含不安全路径、链接或加密内容");
            name=[name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
            if([seen containsObject:name]) ZWFail(@"ZIP 包含重复路径");[seen addObject:name];
            NSString *leaf;int parent=ParentFD(root,name,&leaf);mode_t type=archive_entry_filetype(entry);mode_t mode=archive_entry_perm(entry)&0777;
            if(type==AE_IFDIR) { if(mkdirat(parent,leaf.fileSystemRepresentation,0700) && errno!=EEXIST){close(parent);ZWFail(@"包目录创建失败");} }
            else if(type==AE_IFLNK) {
                const char *target=archive_entry_symlink_utf8(entry);NSString *link=target?[NSString stringWithUTF8String:target]:nil;
                NSString *resolved=[[name.stringByDeletingLastPathComponent stringByAppendingPathComponent:link?:@""] stringByStandardizingPath];
                if(!link.length || [link isAbsolutePath] || !SafeRelative(resolved)) {close(parent);ZWFail(@"ZIP 链接越界");}
                [links addObject:@[name,link]];
            } else if(type==AE_IFREG) {
                int fd=openat(parent,leaf.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode&0111?0700:0600);
                if(fd<0){close(parent);ZWFail(@"包文件创建失败");}char buffer[65536];la_ssize_t n;BOOL failed=NO;
                while((n=archive_read_data(a,buffer,sizeof(buffer)))>0){total+=(uint64_t)n;if(total>limit+65536 || total>2ULL*1024*1024*1024){failed=YES;break;}size_t left=n;const char *p=buffer;while(left){ssize_t written=write(fd,p,left);if(written<=0){failed=YES;break;}left-=written;p+=written;}if(failed)break;}
                if(n<0 || fsync(fd))failed=YES;close(fd);if(failed){close(parent);ZWFail(@"ZIP 解压失败或超过体积限制");}
            } else {close(parent);ZWFail(@"ZIP 包含不支持的文件类型");}
            close(parent);
        }
        if(result!=ARCHIVE_EOF || !count) ZWFail(@"ZIP 结构损坏");
        for(NSArray *link in links){NSString *leaf;int parent=ParentFD(root,link[0],&leaf);int r=symlinkat([link[1] fileSystemRepresentation],parent,leaf.fileSystemRepresentation);close(parent);if(r)ZWFail(@"包链接创建失败");}
        for(NSArray *link in links){NSString *full=[destination stringByAppendingPathComponent:link[0]];NSString *resolved=full.stringByResolvingSymlinksInPath;if(![resolved hasPrefix:[[destination stringByAppendingPathComponent:@"ZeroWork.app"] stringByAppendingString:@"/"]]) ZWFail(@"包链接解析越界");}
        ZWSyncDirectory(destination);
    } @finally { archive_read_free(a);close(root); }
}
