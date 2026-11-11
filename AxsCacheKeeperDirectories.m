#import "AxsCacheKeeperDirectories.h"
#import "AxsCacheKeeperPolicy.h"
#include <errno.h>

NSArray<NSString *> *axs_cachekeeper_scan_directories(NSURL *home, NSError **error) {
    if (error) *error=nil;
    if (![home isKindOfClass:NSURL.class] || !home.isFileURL) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return @[];
    }
    NSMutableArray *paths=[NSMutableArray new];
    NSFileManager *fm=NSFileManager.defaultManager;
    // Library 自身过宽，展示它的一级用途分类；其他父目录均不再展开。
    for (NSString *base in @[@"",@"Library"]) {
        NSURL *root=base.length ? [home URLByAppendingPathComponent:base] : home;
        if (![root.path isEqual:root.URLByResolvingSymlinksInPath.path]) {
            if (error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:ELOOP userInfo:nil];
            continue;
        }
        struct stat rootInfo;
        if (lstat(root.fileSystemRepresentation,&rootInfo)) {
            if (errno!=ENOENT && error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            continue;
        }
        NSError *readError=nil;
        NSArray *entries=[fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:&readError];
        if (readError && error && !*error) *error=readError;
        for (NSURL *entry in entries) {
            if (!base.length && [entry.lastPathComponent isEqual:@"Library"]) continue;
            struct stat info;
            if (lstat(entry.fileSystemRepresentation,&info)) {
                if (errno!=ENOENT && error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                continue;
            }
            if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)) continue;
            [paths addObject:base.length ? [base stringByAppendingPathComponent:entry.lastPathComponent] : entry.lastPathComponent];
        }
    }
    return axs_cachekeeper_parent_paths(paths);
}
