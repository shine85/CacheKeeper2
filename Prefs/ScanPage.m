#import <UIKit/UIKit.h>
#include <roothide.h>
#include <sys/stat.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperSelection.h"

@interface CKScanPage : UITableViewController
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *appName;
@property(nonatomic,strong) NSArray *rows;
@property(nonatomic,strong) NSDictionary *previous;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *token;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic,strong) NSTimer *statusTimer;
@property(nonatomic,copy) NSString *scanError;
@property(nonatomic,strong) NSMutableDictionary *displayCache;
@property(nonatomic,strong) UIBarButtonItem *scanButton;
@property(nonatomic,strong) UIBarButtonItem *enableAllButton;
@property(nonatomic,strong) NSArray *cacheRows;
@property(nonatomic,strong) NSArray *otherRows;
@property(nonatomic) BOOL showOtherData;
@property(nonatomic,copy) NSString *actionStatus;
@end
@implementation CKScanPage
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (NSString *)file:(NSString *)name {return [jbroot(@"/var/mobile/Library/CacheKeeper") stringByAppendingPathComponent:name];}
- (NSDictionary *)axs_cachekeeper_display:(NSString *)name {
    if (!self.displayCache) self.displayCache=[NSMutableDictionary new];
    if (!self.displayCache[name]) self.displayCache[name]=[NSDictionary dictionaryWithContentsOfFile:[self file:name]] ?: @{};
    return self.displayCache[name];
}
- (void)axs_cachekeeper_reload {
    self.displayCache=nil;
    NSMutableArray *rows=[self.rows mutableCopy] ?: [NSMutableArray new];
    NSDictionary *report=[self axs_cachekeeper_display:[@"Status/" stringByAppendingFormat:@"%@.auto.plist",self.bundle]];
    NSMutableSet *known=[NSMutableSet new];
    for (NSDictionary *row in rows) if (row[@"path"]) [known addObject:row[@"path"]];
    for (NSString *path in axs_cachekeeper_cache_paths(report[@"effectivePaths"])) {
        if (![known containsObject:path]) [rows addObject:@{@"path":path,@"manageable":@YES,@"automatic":@YES}];
    }
    self.cacheRows=axs_cachekeeper_manageable_rows(rows);
    self.otherRows=axs_cachekeeper_readonly_rows(rows);
    self.enableAllButton.enabled=!self.timer && self.cacheRows.count>0;
    [self.tableView reloadData];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.appName;
    NSDictionary *history=[NSDictionary dictionaryWithContentsOfFile:[self file:@"snapshots.plist"]];
    self.rows=axs_cachekeeper_parent_rows(history[self.bundle][@"rows"]);
    self.previous=@{@"rows":history[self.bundle][@"previousRows"]?:@[]};
    self.scanError=history[self.bundle][@"error"];
    self.scanButton=[[UIBarButtonItem alloc] initWithTitle:@"检测目录" style:UIBarButtonItemStylePlain target:self action:@selector(scan)];
    self.enableAllButton=[[UIBarButtonItem alloc] initWithTitle:@"一键开启" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_enable_all)];
    self.enableAllButton.accessibilityLabel=@"开启自动模式、网络磁盘缓存限制与新增缓存自动发现";
    self.navigationItem.rightBarButtonItems=@[self.enableAllButton,self.scanButton];
    [self axs_cachekeeper_reload];
}
- (void)scan {
    if (self.timer) return;
    self.actionStatus=nil;
    self.token=NSUUID.UUID.UUIDString;
    if (![@{@"bundle":self.bundle,@"token":self.token} writeToFile:[self file:@"request.plist"] atomically:YES]) { [self message:@"无法提交检测，请重新安装插件。"];return; }
    self.started=NSProcessInfo.processInfo.systemUptime;
    self.scanButton.enabled=NO;
    self.enableAllButton.enabled=NO;
    self.title=@"正在检测…";
    __weak typeof(self) weak=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:.5 repeats:YES block:^(NSTimer *timer){[weak check];}];
    [self axs_cachekeeper_reload];
}
- (void)check {
    NSDictionary *result=[NSDictionary dictionaryWithContentsOfFile:[self file:@"scan.plist"]];
    if ([result[@"token"] isEqual:self.token]) {
        [self.timer invalidate];self.timer=nil;self.scanButton.enabled=YES;self.title=self.appName;
        self.rows=axs_cachekeeper_parent_rows(result[@"rows"]);
        self.previous=@{@"rows":result[@"previousRows"]?:@[]};
        self.scanError=result[@"error"];
        [self axs_cachekeeper_reload];
        if (self.scanError.length) { [self message:self.scanError];return; }
        if (!self.rows.count) [self message:@"没有检测到候选目录。请先打开该应用再返回检测，或检查插件是否已加载。"];return;
    }
    if (NSProcessInfo.processInfo.systemUptime-self.started>25) {
        [self.timer invalidate];self.timer=nil;self.title=self.appName;self.scanButton.enabled=YES;
        [self axs_cachekeeper_reload];
        [self message:@"检测超时，请注销桌面后重试。"];
    }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self axs_cachekeeper_reload];
    __weak typeof(self) weak=self;
    if (!self.statusTimer) self.statusTimer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){[weak axs_cachekeeper_reload];}];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self.statusTimer invalidate]; self.statusTimer=nil; }
- (void)dealloc {[self.timer invalidate];[self.statusTimer invalidate];}
- (void)message:(NSString *)text {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"目录检测" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (NSArray *)orderedRows {
    return self.cacheRows ?: @[];
}
- (NSDictionary *)axs_cachekeeper_row_at:(NSIndexPath *)path {
    if (path.section==1 && path.row<self.cacheRows.count) return self.cacheRows[path.row];
    if (path.section==2 && self.showOtherData && path.row>0 && path.row-1<self.otherRows.count) return self.otherRows[path.row-1];
    return nil;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    NSString *relative=[self axs_cachekeeper_row_at:path][@"path"];
    if (!relative) return nil;
    NSDictionary *history=[self axs_cachekeeper_display:@"snapshots.plist"][self.bundle];
    NSString *home=history[@"home"];
    if ([relative hasPrefix:@"Group/"]) {
        NSArray *parts=[relative componentsSeparatedByString:@"/"];
        if (parts.count<3) return nil;
        home=history[@"groups"][parts[1]];
        relative=[[parts subarrayWithRange:NSMakeRange(2,parts.count-2)] componentsJoinedByString:@"/"];
    }
    if (!axs_cachekeeper_relative_path(relative)) return nil;
    if (!home.length) return nil;
    NSURLComponents *url = [NSURLComponents new];
    url.scheme = @"filza";
    url.host = @"";
    url.path = [home stringByAppendingPathComponent:relative];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *open = [UIAction actionWithTitle:@"在 Filza 中打开目录" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *action) {
            [UIApplication.sharedApplication openURL:url.URL options:@{} completionHandler:^(BOOL success) {
                if (!success) [self message:@"无法打开 Filza，请确认已安装。"];
            }];
        }];
        return [UIMenu menuWithTitle:@"" children:@[open]];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return self.otherRows.count ? 3 : 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section==0) return 4;
    if (section==1) return MAX((NSUInteger)1,self.cacheRows.count);
    return 1+(self.showOtherData ? self.otherRows.count : 0);
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (section==0) return @"缓存控制";
    if (section==1) return [NSString stringWithFormat:@"可管理缓存 · %lu 个父目录",(unsigned long)self.cacheRows.count];
    return @"其他数据占用";
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section==0) return @"一键开启 = 自动模式 + 网络磁盘缓存限制 + 新增缓存自动发现。可能增加流量和重复加载，网络选项可随时关闭。";
    if (section==2) return @"业务数据仅用于解释占用，默认折叠。体积大不代表可删除，数据库、登录态和共享数据不在处理范围内。";
    NSString *message=@"首次使用产生的缓存也处理；仅在 APP 完全退出、文件超过 60 秒并通过预检后删除可识别媒体。已选目录内新增内容自动覆盖；新增标准缓存根按自动发现选项纳入，手动关闭的目录保持排除。";
    return self.scanError.length ? [self.scanError stringByAppendingFormat:@"\n%@",message] : message;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section==0 && path.row==0) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"此 APP 缓存控制";
        NSDictionary *report = [self axs_cachekeeper_display:[@"Status/" stringByAppendingFormat:@"%@.auto.plist",self.bundle]];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.text = axs_cachekeeper_summary(nil,report);
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        NSDictionary *selected=[self axs_cachekeeper_display:@"directories.plist"];
        UISwitch *toggle=[UISwitch new];
        toggle.on=axs_cachekeeper_app_enabled(states[self.bundle]);
        if (!toggle.on) cell.detailTextLabel.text=@"未开启；打开总开关、单项开启或一键开启后才生效";
        else if (!axs_cachekeeper_selected_paths(selected,states,self.bundle).count && !axs_cachekeeper_auto_discover(states[self.bundle])) cell.detailTextLabel.text=@"总开关已开启；未选择文件清理目录，网络缓存按独立选项执行";
        if (self.actionStatus.length) cell.detailTextLabel.text=[self.actionStatus stringByAppendingFormat:@"\n%@",cell.detailTextLabel.text];
        [toggle addTarget:self action:@selector(master:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
        return cell;
    }
    if (path.section==0 && path.row==1) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        UILabel *label=[UILabel new];label.text=@"选择一种模式";label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];label.adjustsFontForContentSizeCategory=YES;
        UISegmentedControl *control=[[UISegmentedControl alloc] initWithItems:@[@"自动",@"只禁止",@"只清理"]];
        NSArray *modes=@[@"auto",@"prevent",@"clean"];
        control.selectedSegmentIndex=[modes indexOfObject:axs_cachekeeper_mode(states[self.bundle])];
        control.accessibilityLabel=@"缓存控制模式，三选一";
        [control addTarget:self action:@selector(axs_cachekeeper_mode_changed:) forControlEvents:UIControlEventValueChanged];
        UILabel *detail=[UILabel new];detail.numberOfLines=0;detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];detail.textColor=UIColor.secondaryLabelColor;detail.adjustsFontForContentSizeCategory=YES;
        detail.text=@"自动：网络限制 + 退出后清理\n只禁止：只限制网络缓存，不删文件\n只清理：允许网络缓存，仅退出后清理";
        UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,control,detail]];
        stack.axis=UILayoutConstraintAxisVertical;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=NO;
        [cell.contentView addSubview:stack];
        UILayoutGuide *margins=cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],[control.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
        cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;
    }
    if (path.section==0 && path.row==2) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"禁止网络磁盘缓存";
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        UISwitch *toggle=[UISwitch new];toggle.on=axs_cachekeeper_url_cache_enabled(states[self.bundle]);
        toggle.enabled=axs_cachekeeper_wants_restriction(states[self.bundle]);
        cell.detailTextLabel.text=toggle.enabled ? @"仅限标准 NSURLCache，可能增加流量；不改变内存缓存" : @"只清理模式不限制网络缓存；选项已保留";
        cell.detailTextLabel.numberOfLines=0;
        [toggle addTarget:self action:@selector(axs_cachekeeper_network_changed:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=toggle;return cell;
    }
    if (path.section==0 && path.row==3) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"自动纳入新增缓存目录";
        cell.detailTextLabel.text=@"退出后定期检查标准缓存根；手动关闭的目录不会重开";cell.detailTextLabel.numberOfLines=0;
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        UISwitch *toggle=[UISwitch new];toggle.on=axs_cachekeeper_auto_discover(states[self.bundle]);
        [toggle addTarget:self action:@selector(axs_cachekeeper_discovery_changed:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=toggle;return cell;
    }
    if (path.section==2 && path.row==0) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=[NSString stringWithFormat:@"%@ %lu 项其他占用",self.showOtherData ? @"收起" : @"查看",(unsigned long)self.otherRows.count];
        cell.detailTextLabel.text=@"不参与一键开启，仅供排查空间去向";cell.detailTextLabel.numberOfLines=0;
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
    }
    NSDictionary *row=[self axs_cachekeeper_row_at:path];
    if (!row) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=self.timer ? @"正在检测缓存目录…" : @"尚无可管理缓存目录";
        cell.detailTextLabel.text=@"先使用一次目标 APP 并退出，再点“检测目录”；其他业务数据不会自动当成缓存";
        cell.detailTextLabel.numberOfLines=0;cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;
    }
    NSString *relative=row[@"path"];
    NSDictionary *config=[self axs_cachekeeper_display:@"directories.plist"];
    BOOL enabled=NO, partial=NO;
    NSDictionary *master=[self axs_cachekeeper_display:@"appEnabled.plist"];
    NSMutableDictionary *viewState=axs_cachekeeper_app_state(master[self.bundle],YES);
    NSArray *available=axs_cachekeeper_enableable_paths(self.cacheRows);
    for (NSString *selected in axs_cachekeeper_effective_paths(config[self.bundle],viewState,available)) {
        if ([selected isEqual:relative]) enabled=YES;
        else if ([selected hasPrefix:[relative stringByAppendingString:@"/"]]) { enabled=YES;partial=YES; }
    }
    long long previous=0;BOOL compared=NO;
    for (NSDictionary *old in self.previous[@"rows"]) if ([old[@"path"] isEqual:relative]) {previous=[old[@"bytes"] longLongValue];compared=YES;break;}
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=[relative isEqual:@"Library/Caches"]?@"Library/Caches · 标准缓存":relative;cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    NSString *growth=compared?[NSString stringWithFormat:@" · 变化 %+.2f MB",([row[@"bytes"] longLongValue]-previous)/1048576.0]:@" · 首次检测";
    BOOL masterOn=axs_cachekeeper_app_enabled(master[self.bundle]);
    BOOL manageable=axs_cachekeeper_row_manageable(row);
    NSString *state=!manageable?@"仅供查看":(enabled?(!masterOn?@"已选中，等待打开 APP 总开关":(axs_cachekeeper_wants_cleanup(master[self.bundle])?@"已纳入；退出后处理通过预检的缓存":@"只禁止模式：不删除目录内文件")):@"未开启／已手动排除");
    if (partial) state=[state stringByAppendingString:@"（保留旧配置中选定的部分子目录）"];
    NSString *size=row[@"bytes"] ? [NSString stringWithFormat:@"%.2f MB%@%@",[row[@"bytes"] doubleValue]/1048576,growth,[row[@"complete"] boolValue]?@"":@" · 大小未统计完"] : @"自动发现，大小待检测";
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@\n%@",size,axs_cachekeeper_directory_description(relative),state];
    if (manageable) {
        UISwitch *toggle=[UISwitch new];toggle.on=enabled;toggle.enabled=!self.timer;toggle.accessibilityIdentifier=relative;
        [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    }
    return cell;
}
- (void)master:(UISwitch *)toggle {
    self.actionStatus=nil;
    NSMutableDictionary *selected=axs_cachekeeper_edit_configuration([self file:@"directories.plist"]);
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration([self file:@"appEnabled.plist"]);
    if (!selected || !states) { [self message:@"原配置存在但不可读，已停止保存。"]; [self axs_cachekeeper_reload]; return; }
    if (toggle.on && !selected[self.bundle]) {
        selected[self.bundle]=axs_cachekeeper_activation_paths(nil);
        if (![selected writeToFile:[self file:@"directories.plist"] atomically:YES]) { toggle.on=NO; [self message:@"目录选择保存失败。"];return; }
    }
    states[self.bundle]=axs_cachekeeper_app_state(states[self.bundle],toggle.on);
    if (![states writeToFile:[self file:@"appEnabled.plist"] atomically:YES]) [self message:@"总开关保存失败。"];
    else axs_cachekeeper_notify_preferences();
    [self axs_cachekeeper_reload];
}
- (void)save:(NSString *)relative enabled:(BOOL)enabled {
    NSString *error=axs_cachekeeper_update_selection(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,@[relative],enabled);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    self.actionStatus=error ?: (enabled ? @"已开启该缓存目录并保存" : @"已关闭该目录，自动发现不会重新开启");
    [self axs_cachekeeper_reload];
}
- (void)toggle:(UISwitch *)toggle {
    if (self.timer) { [self axs_cachekeeper_reload];return; }
    [self save:toggle.accessibilityIdentifier enabled:toggle.on];
}
- (void)axs_cachekeeper_enable_all {
    if (self.timer) return;
    NSString *error=axs_cachekeeper_one_click(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,self.cacheRows);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    self.actionStatus=error ?: [NSString stringWithFormat:@"已保存：%lu 个缓存目录 · 自动模式 · 网络限制开启 · 新缓存自动纳入",(unsigned long)axs_cachekeeper_enableable_paths(self.cacheRows).count];
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_save_mode:(NSString *)mode {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置存在但不可读，已停止保存。"];return; }
    BOOL enabled=axs_cachekeeper_app_enabled(states[self.bundle]);
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],enabled);
    state[@"mode"]=mode;states[self.bundle]=state;
    if (![mode isEqual:@"clean"]) state[@"urlCache"]=@YES;
    if (![states writeToFile:path atomically:YES]) [self message:@"模式保存失败。"];
    else axs_cachekeeper_notify_preferences();
    self.actionStatus=nil;
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_network_changed:(UISwitch *)toggle {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置不可读，停止保存。"];[self axs_cachekeeper_reload];return; }
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],axs_cachekeeper_app_enabled(states[self.bundle]));
    state[@"urlCache"]=@(toggle.on);states[self.bundle]=state;
    if (![states writeToFile:path atomically:YES]) [self message:@"网络选项保存失败。"];
    else axs_cachekeeper_notify_preferences();
    self.actionStatus=nil;
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_mode_changed:(UISegmentedControl *)control {
    NSArray *modes=@[@"auto",@"prevent",@"clean"];
    if (control.selectedSegmentIndex<0 || control.selectedSegmentIndex>=modes.count) return;
    [self axs_cachekeeper_save_mode:modes[control.selectedSegmentIndex]];
}
- (void)axs_cachekeeper_discovery_changed:(UISwitch *)toggle {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置不可读，停止保存。"];[self axs_cachekeeper_reload];return; }
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],axs_cachekeeper_app_enabled(states[self.bundle]));
    state[@"autoDiscover"]=@(toggle.on);states[self.bundle]=state;
    if (![states writeToFile:path atomically:YES]) [self message:@"自动发现设置保存失败。"];
    else axs_cachekeeper_notify_preferences();
    self.actionStatus=nil;[self axs_cachekeeper_reload];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section==2 && path.row==0) {
        self.showOtherData=!self.showOtherData;
        [self axs_cachekeeper_reload];
    }
}
@end
