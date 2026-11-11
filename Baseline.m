#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

@interface AxsCacheKeeperSweep ()
@property(nonatomic, readwrite) BOOL complete;
@property(nonatomic, readwrite) BOOL cancelled;
@property(nonatomic, readwrite) NSUInteger removed;
@property(nonatomic, readwrite) NSUInteger failed;
@property(nonatomic, readwrite) NSUInteger protectedCount;
@property(nonatomic, readwrite) NSUInteger recentCount;
@property(nonatomic, readwrite) unsigned long long bytes;
@property(nonatomic, readwrite, copy) NSString *error;
@property(nonatomic, readwrite, copy) NSString *root;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic, strong) NSDirectoryEnumerator *entries;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, readwrite) BOOL checking;
@property(nonatomic, readwrite) NSUInteger inspected;
@property(nonatomic, readwrite) NSUInteger changedCount;
@property(nonatomic,strong) NSMutableSet<NSString *> *dataDirectories;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSArray *> *directorySnapshots;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *fileSnapshots;
@property(nonatomic,strong) NSMutableSet<NSString *> *checkedDirectories;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *recordedFailures;
@property(nonatomic,copy) int (^unlinkFile)(int, const char *);
@end

@implementation AxsCacheKeeperSweep
- (instancetype)initWithRoot:(NSString *)root {
    return [self initWithRoot:root clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; }];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock {
    return [self initWithRoot:root clock:clock unlinkFile:^int(int fd,const char *name) { return unlinkat(fd,name,0); }];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock unlinkFile:(int (^)(int,const char *))unlinkFile {
    if (!(self = [super init])) return nil;
    _root = [root copy];
    _clock = [clock copy];
    _unlinkFile=[unlinkFile copy];_recordedFailures=[NSMutableArray new];
    struct stat info;
    if (![root isEqual:[NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path] ||
        lstat(root.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)) {
        _failed = 1; _complete = YES; _error = @"缓存目录不可访问或包含符号链接";
        return self;
    }
    _device = info.st_dev; _inode = info.st_ino;
    _checking = YES;
    _dataDirectories = [NSMutableSet new];
    _directorySnapshots = [NSMutableDictionary new];
    _fileSnapshots = [NSMutableDictionary new];
    _directorySnapshots[root]=[self axs_cachekeeper_snapshot:info];
    [self axs_cachekeeper_open_enumerator];
    return self;
}
- (NSArray *)axs_cachekeeper_snapshot:(struct stat)info {
    return @[@(info.st_ino),@(info.st_dev),@(info.st_mtimespec.tv_sec),@(info.st_mtimespec.tv_nsec),
        @(info.st_ctimespec.tv_sec),@(info.st_ctimespec.tv_nsec)];
}
- (void)axs_cachekeeper_open_enumerator {
    __weak typeof(self) weak = self;
    _entries = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:self.root isDirectory:YES]
        includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) {
            typeof(self) strong = weak;
            strong.failed++;
            [strong.dataDirectories addObject:strong.root];
            strong.error = [NSString stringWithFormat:@"无法遍历 %@：%@", url.lastPathComponent, error.localizedDescription];
            return YES;
        }];
    if (!_entries) { _failed = 1; _complete = YES; _error = @"无法打开缓存目录"; }
}
- (BOOL)axs_cachekeeper_is_data_directory:(NSString *)path {
    for (NSString *directory in self.dataDirectories)
        if ([path isEqual:directory] || [path hasPrefix:[directory stringByAppendingString:@"/"]]) return YES;
    return NO;
}
- (void)axs_cachekeeper_inspect:(NSURL *)entry info:(struct stat)info {
    if (S_ISDIR(info.st_mode)) {
        self.directorySnapshots[entry.path]=[self axs_cachekeeper_snapshot:info];
        if (axs_cachekeeper_data_marker(entry.lastPathComponent)) {
            [self.dataDirectories addObject:entry.path];[self.entries skipDescendants];
        }
        return;
    }
    if (!S_ISREG(info.st_mode)) return;
    NSString *parent=entry.URLByDeletingLastPathComponent.path;
    if (!self.fileSnapshots[parent]) self.fileSnapshots[parent]=[NSMutableDictionary new];
    self.fileSnapshots[parent][entry.lastPathComponent]=[self axs_cachekeeper_snapshot:info];
    if (axs_cachekeeper_data_marker(entry.lastPathComponent)) { [self.dataDirectories addObject:parent]; return; }
    int directory=axs_cachekeeper_open_directory(parent);
    int file=directory>=0 ? openat(directory,entry.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) : -1;
    struct stat opened;
    unsigned char signature[16]={0};
    ssize_t count=-1;
    if (file>=0 && !fstat(file,&opened) && S_ISREG(opened.st_mode) && opened.st_ino==info.st_ino && opened.st_dev==info.st_dev)
        count=pread(file,signature,sizeof(signature),0);
    if (count<0) { [self.dataDirectories addObject:parent];self.failed++;self.error=@"文件预检未完成，该目录不清理"; }
    else if ((count>=15 && !memcmp(signature,"SQLite format 3",15)) || (count>=6 && !memcmp(signature,"bplist",6)))
        [self.dataDirectories addObject:parent];
    if (file>=0) close(file);
    if (directory>=0) close(directory);
}
- (BOOL)axs_cachekeeper_check_files:(NSString *)directory fd:(int)fd {
    if ([self.checkedDirectories containsObject:directory]) return YES;
    NSDictionary *records=self.fileSnapshots[directory];
    for (NSString *name in records) {
        struct stat info;
        if (fstatat(fd,name.fileSystemRepresentation,&info,AT_SYMLINK_NOFOLLOW) ||
            !S_ISREG(info.st_mode) || ![[self axs_cachekeeper_snapshot:info] isEqual:records[name]]) {
            if (![self.dataDirectories containsObject:directory]) self.changedCount++;
            [self.dataDirectories addObject:directory];self.error=@"预检后文件发生变化，该数据目录已跳过";return NO;
        }
    }
    [self.checkedDirectories addObject:directory];return YES;
}
- (BOOL)axs_cachekeeper_remove:(NSURL *)entry expected:(struct stat)expected {
    NSString *parent = entry.URLByDeletingLastPathComponent.path;
    if (![parent isEqual:self.root] && ![parent hasPrefix:[self.root stringByAppendingString:@"/"]]) {
        [self axs_cachekeeper_failure:@"枚举路径边界" code:EINVAL path:entry.path detail:[NSString stringWithFormat:@"root=%@; parent=%@",self.root,parent]];return NO;
    }
    // 从已核对身份的缓存根逐级打开，不能靠 realpath 后再打开绝对路径防竞态。
    int fd = axs_cachekeeper_open_directory(self.root);
    if (fd < 0) { int code=errno;[self axs_cachekeeper_failure:@"open-root" code:code path:entry.path detail:self.root];return NO; }
    struct stat openedRoot;
    if (fstat(fd,&openedRoot)) {
        int code=errno;close(fd);[self axs_cachekeeper_failure:@"fstat-root" code:code path:entry.path detail:self.root];return NO;
    }
    if (openedRoot.st_dev != self.device || openedRoot.st_ino != self.inode) {
        close(fd);[self axs_cachekeeper_failure:@"根目录身份核对" code:ESTALE path:entry.path detail:@""];return NO;
    }
    NSString *relativeParent = [parent substringFromIndex:self.root.length];
    NSString *openedPath=self.root;
    for (NSString *part in [relativeParent componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        struct stat ancestor;
        if (fstat(fd,&ancestor) || ![[self axs_cachekeeper_snapshot:ancestor] isEqual:self.directorySnapshots[openedPath]] ||
            ![self axs_cachekeeper_check_files:openedPath fd:fd]) {
            if (![self.dataDirectories containsObject:openedPath]) self.changedCount++;
            [self.dataDirectories addObject:openedPath];close(fd);errno=EBUSY;return NO;
        }
        int child = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int savedError = errno;
        close(fd);
        if (child < 0) { [self axs_cachekeeper_failure:@"openat-parent" code:savedError path:entry.path detail:openedPath];return NO; }
        fd = child;
        openedPath=[openedPath stringByAppendingPathComponent:part];
    }
    struct stat current;
    struct stat parentInfo;
    if (fstat(fd,&parentInfo) || ![[self axs_cachekeeper_snapshot:parentInfo] isEqual:self.directorySnapshots[parent]] ||
        ![self axs_cachekeeper_check_files:parent fd:fd]) {
        if (![self.dataDirectories containsObject:parent]) self.changedCount++;
        [self.dataDirectories addObject:parent];self.error=@"预检后目录发生变化，已跳过";
        close(fd);errno=EBUSY;return NO;
    }
    NSString *fileName=entry.lastPathComponent;
    const char *name = fileName.fileSystemRepresentation;
    BOOL removed = NO;
    int file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (file<0) { int code=errno;close(fd);[self axs_cachekeeper_failure:@"openat-file" code:code path:entry.path detail:@""];return NO; }
    if (fstat(file,&current)) { int code=errno;close(file);close(fd);[self axs_cachekeeper_failure:@"fstat-file" code:code path:entry.path detail:@""];return NO; }
    if (S_ISREG(current.st_mode) && current.st_nlink == 1 &&
        current.st_ino == expected.st_ino && current.st_dev == expected.st_dev &&
        axs_cachekeeper_old_enough(current, self.clock())) {
        unsigned char signature[32] = {0};
        ssize_t readCount = pread(file, signature, sizeof(signature), 0);
        BOOL database = readCount >= 15 && !memcmp(signature, "SQLite format 3", 15);
        BOOL propertyList = readCount >= 6 && !memcmp(signature, "bplist", 6);
        if (readCount < 0) { int code=errno;[self axs_cachekeeper_failure:@"pread" code:code path:entry.path detail:@""]; }
        else if (database || propertyList || !axs_cachekeeper_media_signature(signature, (size_t)readCount)) {
            if (database || propertyList) [self.dataDirectories addObject:parent];
            self.protectedCount++; errno = EBUSY;
        }
        else {
            struct stat final;
            if (fstatat(fd,name,&final,AT_SYMLINK_NOFOLLOW)) {
                int code=errno;[self axs_cachekeeper_failure:@"fstatat-final" code:code path:entry.path detail:@""];
            } else if (final.st_ino == current.st_ino && final.st_dev == current.st_dev && axs_cachekeeper_old_enough(final, self.clock())) {
                int result=self.unlinkFile(fd,name);int code=result ? errno : 0;
                removed=result==0;
                if (!removed) [self axs_cachekeeper_failure:@"unlinkat" code:code path:entry.path detail:@"flags=0"];
            } else [self axs_cachekeeper_failure:@"删除前身份/时间核对" code:ESTALE path:entry.path detail:@""];
        }
    } else [self axs_cachekeeper_failure:@"打开文件身份/时间核对" code:ESTALE path:entry.path detail:@""];
    int savedError = errno;
    if (removed && !fstat(fd,&parentInfo)) self.directorySnapshots[parent]=[self axs_cachekeeper_snapshot:parentInfo];
    if (removed) [self.fileSnapshots[parent] removeObjectForKey:entry.lastPathComponent];
    if (file >= 0) close(file);
    close(fd); errno = savedError;
    return removed;
}
- (NSArray<NSDictionary *> *)failureDetails { return [self.recordedFailures copy]; }
- (void)axs_cachekeeper_failure:(NSString *)stage code:(int)code path:(NSString *)path detail:(NSString *)detail {
    self.error=[NSString stringWithFormat:@"%@ 失败（errno %d：%s）",stage,code,strerror(code)];
    if (self.recordedFailures.count<8) [self.recordedFailures addObject:@{@"stage":stage,@"code":@(code),@"path":path ?: @"",@"detail":detail ?: @""}];
    errno=code;
}
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue {
    if (self.complete || self.cancelled) return;
    self.checkedDirectories=[NSMutableSet new];
    // 枚举器跨批次保留位置，避免每次超时都从头扫描。
    for (NSUInteger index = 0; index < limit; index++) {
        if (!shouldContinue()) { self.cancelled = YES; self.entries = nil; return; }
        struct stat rootInfo;
        if (lstat(self.root.fileSystemRepresentation, &rootInfo) || !S_ISDIR(rootInfo.st_mode) ||
            rootInfo.st_ino != self.inode || rootInfo.st_dev != self.device ||
            ![self.root isEqual:[NSURL fileURLWithPath:self.root].URLByResolvingSymlinksInPath.path]) {
            self.failed++; self.error = @"扫描期间缓存目录已改变"; self.complete = YES; self.entries = nil; return;
        }
        NSURL *entry = self.entries.nextObject;
        if (!entry) {
            if (self.checking && ![self axs_cachekeeper_is_data_directory:self.root]) {
                self.checking=NO;[self axs_cachekeeper_open_enumerator];continue;
            }
            if (self.checking) self.protectedCount++;
            self.complete=YES;self.entries=nil;return;
        }
        struct stat info;
        if (lstat(entry.fileSystemRepresentation, &info)) {
            if (errno != ENOENT) { self.failed++; self.error = @"无法读取缓存文件属性";[self.dataDirectories addObject:entry.URLByDeletingLastPathComponent.path]; }
            continue;
        }
        // URL 枚举器不递归符号链接；对非目录调用 skipDescendants 会影响后续遍历。
        if (S_ISLNK(info.st_mode)) continue;
        if (self.checking) { self.inspected++;[self axs_cachekeeper_inspect:entry info:info]; continue; }
        if ([self axs_cachekeeper_is_data_directory:entry.path]) {
            self.protectedCount++;if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];continue;
        }
        NSString *relative = [entry.path substringFromIndex:self.root.length + 1];
        if (axs_cachekeeper_protected_path(relative)) {
            self.protectedCount++;
            if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];
            continue;
        }
        if (S_ISDIR(info.st_mode)) continue;
        if (!S_ISREG(info.st_mode)) continue;
        if (!axs_cachekeeper_ordinary_cache_file(relative) || info.st_nlink != 1) { self.protectedCount++; continue; }
        if (!axs_cachekeeper_old_enough(info, self.clock())) { self.recentCount++; continue; }
        if ([self axs_cachekeeper_remove:entry expected:info]) { self.removed++; self.bytes += info.st_size; }
        else if (errno != ENOENT && errno != EBUSY) self.failed++;
    }
}
@end
