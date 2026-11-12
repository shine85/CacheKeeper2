#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperPolicy.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// Foundation 的根路径别名仅在指向同一目录时可用；不解析后代链接。
static inline NSArray<NSString *> *axs_cachekeeper_directory_aliases(NSString *root) {
    NSMutableArray *aliases=[NSMutableArray arrayWithObject:root];
    NSString *standard=root.stringByStandardizingPath;
    struct stat original,alternate;
    if (![standard isEqual:root] && !lstat(root.fileSystemRepresentation,&original) &&
        !lstat(standard.fileSystemRepresentation,&alternate) && S_ISDIR(alternate.st_mode) &&
        original.st_ino==alternate.st_ino && original.st_dev==alternate.st_dev) [aliases addObject:standard];
    return aliases;
}
static inline NSString *axs_cachekeeper_enumerated_path(NSString *path, NSString *root, NSArray<NSString *> *aliases) {
    if (![path isKindOfClass:NSString.class]) return nil;
    NSString *trimmed=path;
    while (trimmed.length>1 && [trimmed hasSuffix:@"/"]) trimmed=[trimmed substringToIndex:trimmed.length-1];
    for (NSString *alias in aliases) {
        NSString *prefix=[alias stringByAppendingString:@"/"];
        if (![trimmed hasPrefix:prefix]) continue;
        NSString *relative=[trimmed substringFromIndex:prefix.length];
        if (!axs_cachekeeper_relative_path(relative)) return nil;
        return [root stringByAppendingFormat:@"/%@",relative];
    }
    return nil;
}

// 输入为规范绝对路径；每一级都不跟随链接，避免权限操作逃出目标目录。
static inline int axs_cachekeeper_open_directory(NSString *path) {
    if (![path hasPrefix:@"/"]) { errno = EINVAL; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if ([part isEqual:@"."] || [part isEqual:@".."]) { close(fd); errno = EINVAL; return -1; }
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int error = errno;
        close(fd);
        if (next < 0) { errno = error; return -1; }
        fd = next;
    }
    return fd;
}
