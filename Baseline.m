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
@property(nonatomic, copy) NSString *root;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic, strong) NSDirectoryEnumerator *entries;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@end

@implementation AxsCacheKeeperSweep
- (instancetype)initWithRoot:(NSString *)root {
    return [self initWithRoot:root clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; }];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock {
    if (!(self = [super init])) return nil;
    _root = [root copy];
    _clock = [clock copy];
    struct stat info;
    if (![root isEqual:[NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path] ||
        lstat(root.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)) {
        _failed = 1; _complete = YES; _error = @"缓存目录不可访问或包含符号链接";
        return self;
    }
    _device = info.st_dev; _inode = info.st_ino;
    __weak typeof(self) weak = self;
    _entries = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root isDirectory:YES]
        includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) {
            typeof(self) strong = weak;
            strong.failed++;
            strong.error = [NSString stringWithFormat:@"无法遍历 %@：%@", url.lastPathComponent, error.localizedDescription];
            return YES;
        }];
    if (!_entries) { _failed = 1; _complete = YES; _error = @"无法打开缓存目录"; }
    return self;
}
- (BOOL)axs_cachekeeper_remove:(NSURL *)entry expected:(struct stat)expected {
    NSString *parent = entry.URLByDeletingLastPathComponent.path;
    if (![parent isEqual:self.root] && ![parent hasPrefix:[self.root stringByAppendingString:@"/"]]) { errno = EINVAL; return NO; }
    // 从已核对身份的缓存根逐级打开，不能靠 realpath 后再打开绝对路径防竞态。
    int fd = axs_cachekeeper_open_directory(self.root);
    if (fd < 0) return NO;
    struct stat openedRoot;
    if (fstat(fd, &openedRoot) || openedRoot.st_dev != self.device || openedRoot.st_ino != self.inode) {
        close(fd); errno = ESTALE; return NO;
    }
    NSString *relativeParent = [parent substringFromIndex:self.root.length];
    for (NSString *part in [relativeParent componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        int child = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int savedError = errno;
        close(fd);
        if (child < 0) { errno = savedError; return NO; }
        fd = child;
    }
    struct stat current;
    const char *name = entry.lastPathComponent.fileSystemRepresentation;
    BOOL removed = NO;
    int file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (file >= 0 && !fstat(file, &current) && S_ISREG(current.st_mode) && current.st_nlink == 1 &&
        current.st_ino == expected.st_ino && current.st_dev == expected.st_dev &&
        axs_cachekeeper_old_enough(current, self.clock())) {
        unsigned char signature[32] = {0};
        ssize_t readCount = pread(file, signature, sizeof(signature), 0);
        BOOL database = readCount >= 15 && !memcmp(signature, "SQLite format 3", 15);
        BOOL propertyList = readCount >= 6 && !memcmp(signature, "bplist", 6);
        if (readCount < 0) { self.error = @"无法核对文件内容，保留文件"; }
        else if (database || propertyList || !axs_cachekeeper_media_signature(signature, (size_t)readCount)) { self.protectedCount++; errno = EBUSY; }
        else {
            struct stat final;
            if (!fstatat(fd, name, &final, AT_SYMLINK_NOFOLLOW) && final.st_ino == current.st_ino &&
                final.st_dev == current.st_dev && axs_cachekeeper_old_enough(final, self.clock())) removed = unlinkat(fd, name, 0) == 0;
            else errno = ESTALE;
        }
    } else { errno = ESTALE; }
    int savedError = errno;
    if (file >= 0) close(file);
    close(fd); errno = savedError;
    return removed;
}
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue {
    if (self.complete || self.cancelled) return;
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
        if (!entry) { self.complete = YES; self.entries = nil; return; }
        struct stat info;
        if (lstat(entry.fileSystemRepresentation, &info)) {
            if (errno != ENOENT) { self.failed++; self.error = @"无法读取缓存文件属性"; }
            continue;
        }
        if (S_ISLNK(info.st_mode)) { [self.entries skipDescendants]; continue; }
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
        else if (errno != ENOENT && errno != EBUSY) { self.failed++; self.error = [NSString stringWithFormat:@"删除失败（errno %d）", errno]; }
    }
}
@end
