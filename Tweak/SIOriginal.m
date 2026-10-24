// SIOriginal（显示名：极速IOS）— 保活专版 v1.0.0（基于 v2.4.3 精简）
//
// ===================== 本版定位 =====================
// 只保留「真后台保活（FUBackground）」一个功能，其余全部删除：
//   · 启用真后台保活（总开关）      —— FUBGEnabled   缺省 YES
//   · 场景伪装引擎                  —— FUBGSceneFake 缺省 YES
//   · 音频断言兜底（静音白噪）      —— FUBGAudioKeep 缺省 YES
// 三个开关缺省全部开启：注入即生效，无需配置 App、无需 IPA。
// 已删除：动画加速 / 手感 / HUD / 列表加速 / 安全启动 / 命中统计浮层 /
//         悬浮球（死代码）/ 全部动画侧子系统。
//
// 微信优先原则：一切取舍以「微信在后台不被系统杀掉、切回不重启」为最高目标。
//   · 场景伪装对微信整段生效（吞 backgrounding diff，长连接保持，切回秒开）；
//   · 假前台期间仅对后台工作队列如实回答 Background（v2.4.3 崩溃定点规避），
//     队名关键词覆盖微信 FTS 索引全家族 + 常见索引/落盘队列命名；
//   · 音频断言使用 MixWithOthers，不与微信语音/通话音频会话打架。
//
// 保留的历史关键修复：
//   [v2.1.10] 前后台感知走进程内 NSNotificationCenter（Darwin 总线收不到，
//             否则音频断言/看门狗/横幅伪装/中断恢复/线路恢复五个子系统静默失效）。
//   [v2.1.10] AVAudioSession 观察者 token 强引用持有，否则回调立即注销。
//   [v2.1.11] 看门狗按需装卸：进后台才装、回前台即卸，前台不再空转唤醒主线程。
//   [v2.1.11] willPresent 原实现按类存储（NSMapTable），多 delegate 不互相覆盖。
//   [v2.1.18] 白噪 base64 只解码一次缓存复用。
//   [v2.1.20] applicationState 高频调用点缓存：同址重复调用退化为两次指针比较。
//   [v2.3.1]  低电量模式看门狗 3s→6s；连续 3 次重建失败退避约 30s。
//   [v2.3.2]  退避按秒换算，低电量下不再错退避 60s。
//   [v2.3.3]  退避结束重置 strike；player 为 nil 时线路变化补重建分支。
//
// 配置（可选，不改也能用）：
//   plist：/var/Managed Preferences/mobile/com.apple.UIKit.plist
//     FUBGEnabled / FUBGSceneFake / FUBGAudioKeep = BOOL
//     Blacklist = NSArray 或逗号分隔字符串（精确匹配，结尾 * 为前缀通配）
//     AppOverrides = { "com.xxx.yyy" = { FUBGEnabled = 0; ... } } 按 App 覆盖
//   热重载：Darwin 通知 com.local.sioriginal.settingschanged
//   内置排除：com.apple.springboard（场景宿主，永不可开）
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "FUBGNoiseData.h"

#define kPrefPath    @"/var/Managed Preferences/mobile/com.apple.UIKit.plist"
#define kNotifyName  @"com.local.sioriginal.settingschanged"

#pragma mark - 基础工具

static NSString *gSelfBundle = nil;
static NSString *FUBG_bundleID(void) {
    if (!gSelfBundle) gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return gSelfBundle;
}

// 物理上是否处于后台（由真实生命周期通知维护）
static BOOL gPhysBg = NO;

// AppOverrides 命中当前进程则返回该字典，否则 nil。优先级：App 覆盖 > 全局。
static NSDictionary *FUBG_appOverride(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return nil;
    id ov = root[@"AppOverrides"];
    if (![ov isKindOfClass:[NSDictionary class]]) return nil;
    NSString *bid = FUBG_bundleID();
    if (!bid.length) return nil;
    id mine = ((NSDictionary *)ov)[bid];
    return [mine isKindOfClass:[NSDictionary class]] ? (NSDictionary *)mine : nil;
}

// 内置保活排除名单 —— 这些进程绝不参与真后台保活。
// SpringBoard 本身就是场景宿主，在它内部吞掉 scene 更新会影响全局所有 App 的
// 后台化行为，而保活（音频断言 + 场景伪装）对桌面进程本身毫无意义。
static BOOL FUBG_builtinExcluded(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[ @"com.apple.springboard" ];
    });
    NSString *bid = FUBG_bundleID();
    return bid.length && [list containsObject:bid];
}

#pragma mark - 全局状态

static BOOL    gFUBGEnabled = YES;   // 启用真后台保活（总开关）——缺省开
static BOOL    gSceneFake   = YES;   // 场景伪装引擎——缺省开
static BOOL    gAudioKeep   = YES;   // 音频断言兜底——缺省开
static NSArray *gExclude    = nil;

static BOOL    gActive   = NO;   // 本 App 最终是否参与保活（总开关 ∧ 排除名单）
static BOOL    gUseScene = NO;   // 本 App 是否启用场景伪装
static BOOL    gUseAudio = NO;   // 本 App 是否启用音频断言
static BOOL    gHasAudioMode = NO;
static BOOL    gHasAppOverride = NO;

static AVAudioPlayer *gPlayer = nil;
static UIBackgroundTaskIdentifier gTask = 0;   // 0 = 无桥接任务
static NSTimer *gWatchdog = nil;
// addObserverForName: 返回的 token 一旦被释放观察随即注销，必须强引用持有
static NSMutableArray *gObs = nil;

#pragma mark - 配置

static BOOL FUBG_isExcluded(void) {
    if (FUBG_builtinExcluded()) return YES;
    NSString *bid = FUBG_bundleID();
    for (NSString *b in gExclude) {
        if (![b isKindOfClass:[NSString class]] || !b.length) continue;
        // 默认精确匹配；条目结尾显式 * 才按前缀匹配（如 com.tencent.* 排除整个家族）
        if ([b hasSuffix:@"*"]) {
            if (b.length > 1 && [bid hasPrefix:[b substringToIndex:b.length - 1]]) return YES;
        } else if ([bid isEqualToString:b]) {
            return YES;
        }
    }
    return NO;
}

// 后台工作线程识别（微信崩溃定点规避，微信优先原则的核心）：
// 假前台期间 applicationState 对主线程/网络线程返回 Active（保活秒回不受影响），
// 只对后台工作队列（索引/落盘类）如实回答 Background —— 它们按前台路径访问
// 已被系统回收的上下文会崩（微信 com.tencent.xin.fts.mainIndex 读 nil+0x18）。
// 判定按线程 __thread 缓存，热路径零 dladdr、零分配。
static BOOL FUBG_isBackgroundWorkerThread(void) {
    static __thread int cached = -1;   // -1 未判定 / 0 否 / 1 是
    if (cached >= 0) return cached == 1;
    BOOL hit = NO;
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (label) {
        // 微信：com.tencent.xin.fts.mainIndex / *.fts.* ；其他 App 的索引/落盘队列命名同理
        if (strstr(label, ".fts.") || strstr(label, "mainIndex") ||
            strstr(label, ".index.") || strstr(label, "IndexQueue") ||
            strstr(label, "FTS") || strstr(label, "searchIndex") ||
            strstr(label, ".db.") || strstr(label, "DBQueue")) {
            hit = YES;
        }
    }
    cached = hit ? 1 : 0;
    return hit;
}

static void FUBG_recalc(void) {
    gActive   = gFUBGEnabled && !FUBG_isExcluded();
    gUseScene = gActive && gSceneFake;
    gUseAudio = gActive && gAudioKeep;
}

static void FUBG_resetDefaults(void) {
    gFUBGEnabled = YES;
    gSceneFake   = YES;
    gAudioKeep   = YES;
    gExclude     = @[];
}

static void FUBG_loadPref(void) {
    gHasAppOverride = NO;
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
        if (!d) {
            FUBG_resetDefaults();
            NSLog(@"[FUBG] prefs file missing/unreadable — factory defaults (all ON)");
        } else {
            if (d[@"FUBGEnabled"])   gFUBGEnabled = [d[@"FUBGEnabled"] boolValue];
            if (d[@"FUBGSceneFake"]) gSceneFake   = [d[@"FUBGSceneFake"] boolValue];
            if (d[@"FUBGAudioKeep"]) gAudioKeep   = [d[@"FUBGAudioKeep"] boolValue];
            // 黑名单：兼容 NSArray 与逗号分隔字符串
            NSMutableArray *ex = [NSMutableArray array];
            id bl = d[@"Blacklist"];
            if ([bl isKindOfClass:[NSArray class]]) {
                [ex addObjectsFromArray:bl];
            } else if ([bl isKindOfClass:[NSString class]] && [(NSString *)bl length]) {
                [ex addObjectsFromArray:[(NSString *)bl componentsSeparatedByString:@","]];
            }
            // 清洗：只保留非空字符串（plist 混入 NSNumber/NSNull 会 unrecognized selector 崩溃）
            NSMutableArray *clean = [NSMutableArray array];
            for (id it in ex) {
                if (![it isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
                if (s.length) [clean addObject:s];
            }
            gExclude = clean;
            // App 级覆盖
            NSDictionary *ovr = FUBG_appOverride(d);
            gHasAppOverride = (ovr != nil);
            if (ovr) {
                if (ovr[@"FUBGEnabled"])   gFUBGEnabled = [ovr[@"FUBGEnabled"] boolValue];
                if (ovr[@"FUBGSceneFake"]) gSceneFake   = [ovr[@"FUBGSceneFake"] boolValue];
                if (ovr[@"FUBGAudioKeep"]) gAudioKeep   = [ovr[@"FUBGAudioKeep"] boolValue];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];

    NSArray *modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gHasAudioMode = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];

    FUBG_recalc();
}

#pragma mark - 引擎一：场景伪装
// 移植/修改自 ImmortalizerJailed main.m（GPLv3, Serge Alagon），致谢 @khanhduytran0

static void (*gOrigSceneUpdate)(id, SEL, id, id, id, id);

// 由后台化 diff 的描述特征判断这是否是一条"让 App 退到后台"的场景更新
static BOOL FUBG_isBackgroundingDiff(NSString *desc) {
    if (!desc) return NO;
    if ([desc containsString:@"foreground = NotSet"] ||
        [desc containsString:@"foreground = No"] ||
        [desc containsString:@"foreground = BSSettingFlagNo"] ||
        [desc containsString:@"foreground = NO"]) {
        return YES;
    }
    // 后台切换器快照相关更新同样吞掉，避免快照暴露/状态推进
    if ([desc containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [desc containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }
    return NO;
}

static void FUBG_sceneUpdate(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (gUseScene) {
        @try {
            if (FUBG_isBackgroundingDiff([arg2 description])) {
                NSLog(@"[FUBG] swallowed backgrounding scene diff");
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    gOrigSceneUpdate(self, _cmd, arg1, arg2, arg3, arg4);
}

// ---- applicationState 伪装 ----
static UIApplicationState (*gOrigAppState)(id, SEL);

// 调用点缓存：applicationState 是极高频属性，后台伪装期间每次读取都要 dladdr
// （取 dyld 锁）+ 两次 strstr。实测调用大多来自少数固定调用点——记住
// 「上一个返回地址 → 上次判定」，同址重复调用退化为两次指针比较。
static void  *gAsLastRet = NULL;
static BOOL   gAsLastBg  = NO;

static UIApplicationState FUBG_appState(id self, SEL _cmd) {
    // 假前台期间，后台工作线程是唯一能拿到真实答案的调用方（崩溃定点规避）
    if (gUseScene && FUBG_isBackgroundWorkerThread()) return UIApplicationStateBackground;
    if (gUseScene && gPhysBg) {
        // 推送/通知框架需要真实答案：前台态时它们不会建立后台接收通道
        void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
        BOOL bg;
        if (ret != NULL && ret == gAsLastRet) {
            bg = gAsLastBg;
        } else {
            bg = NO;
            Dl_info info;
            if (dladdr(ret, &info) && info.dli_fname) {
                if (strstr(info.dli_fname, "UserNotifications") ||
                    strstr(info.dli_fname, "PushKit")) {
                    bg = YES;
                }
            }
            gAsLastRet = ret;
            gAsLastBg  = bg;
        }
        return bg ? UIApplicationStateBackground : UIApplicationStateActive;
    }
    return gOrigAppState ? gOrigAppState(self, _cmd) : UIApplicationStateActive;
}

// ---- 通知横幅伪装（后台时通知仍以横幅+声音+角标呈现）----
// 原实现按类存储：若 App 先后设置两个不同类的 delegate，全局单例 orig 会被
// 第二个类覆盖，第一个 delegate 的通知被转发到错误的实现导致崩溃。
typedef void (*FUBG_WillPresentIMP)(id, SEL, UNUserNotificationCenter *, UNNotification *,
                                    void (^)(UNNotificationPresentationOptions));

static NSMapTable *gOrigWillPresentMap = nil;   // Class -> NSValue(IMP)

static void FUBG_setOrigWillPresent(Class c, IMP imp) {
    if (!c || !imp) return;
    if (!gOrigWillPresentMap)
        gOrigWillPresentMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                                   valueOptions:NSMapTableStrongMemory];
    [gOrigWillPresentMap setObject:[NSValue valueWithPointer:(void *)imp] forKey:(id)c];
}

// 沿 superclass 链向上找：B 继承 A 且未重写时 hook 的是 A 的实现，
// self 是 B 的实例，[self class] 取不到 A 存的 orig，必须向上回溯。
static FUBG_WillPresentIMP FUBG_origWillPresentFor(Class c) {
    if (!gOrigWillPresentMap) return NULL;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        NSValue *v = [gOrigWillPresentMap objectForKey:(id)k];
        if (v) return (FUBG_WillPresentIMP)[v pointerValue];
    }
    return NULL;
}

static void FUBG_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center,
                             UNNotification *note,
                             void (^handler)(UNNotificationPresentationOptions)) {
    if (gUseScene && gPhysBg) {
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
        return;
    }
    FUBG_WillPresentIMP orig = FUBG_origWillPresentFor([self class]);
    if (orig) {
        orig(self, _cmd, center, note, handler);
    } else {
        // 契约要求 completionHandler 必须恰好调用一次，绝不吞掉 handler
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
    }
}

static void (*gOrigUNSetDelegate)(id, SEL, id);

static void FUBG_unSetDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (gOrigUNSetDelegate) gOrigUNSetDelegate(self, _cmd, delegate);
    if (delegate) {
        Class dc = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(dc, sel);
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)FUBG_willPresent) {
                // class_getInstanceMethod 可能返回父类 Method，直接 setImplementation
                // 会改到父类。先 class_addMethod：成功 = 本类新增覆写（orig 即父类 IMP）；
                // 失败 = 本类已有实现，正常替换。两种情况 orig 都记为 cur。
                if (!class_addMethod(dc, sel, (IMP)FUBG_willPresent, method_getTypeEncoding(m))) {
                    method_setImplementation(m, (IMP)FUBG_willPresent);
                }
                FUBG_setOrigWillPresent(dc, cur);
            }
        }
    }
}

static void FUBG_installSceneHooks(void) {
    Class wsClass = objc_getClass("FBSWorkspaceScenesClient");
    Method sceneM = wsClass ? class_getInstanceMethod(
        wsClass, @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:)) : NULL;
    if (sceneM) {
        IMP cur = method_getImplementation(sceneM);
        if (cur != (IMP)FUBG_sceneUpdate) {
            gOrigSceneUpdate = (void (*)(id, SEL, id, id, id, id))cur;
            method_setImplementation(sceneM, (IMP)FUBG_sceneUpdate);
            NSLog(@"[FUBG] scene hook installed");
        } else {
            NSLog(@"[FUBG] scene hook already installed (skip duplicate)");
        }
    } else {
        NSLog(@"[FUBG] FBSWorkspaceScenesClient method not found, scene engine disabled");
    }

    Method stateM = class_getInstanceMethod([UIApplication class], @selector(applicationState));
    if (stateM) {
        IMP cur = method_getImplementation(stateM);
        if (cur != (IMP)FUBG_appState) {
            gOrigAppState = (UIApplicationState (*)(id, SEL))cur;
            method_setImplementation(stateM, (IMP)FUBG_appState);
        }
    }

    Method delM = class_getInstanceMethod([UNUserNotificationCenter class], @selector(setDelegate:));
    if (delM) {
        IMP cur = method_getImplementation(delM);
        if (cur != (IMP)FUBG_unSetDelegate) {
            gOrigUNSetDelegate = (void (*)(id, SEL, id))cur;
            method_setImplementation(delM, (IMP)FUBG_unSetDelegate);
        }
    }
}

#pragma mark - 引擎二：音频断言（静音白噪兜底）

static BOOL FUBG_activateSession(void) {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback
            withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e] || e) {
        NSLog(@"[FUBG] setCategory failed: %@", e); return NO;
    }
    e = nil;
    if (![s setActive:YES error:&e] || e) {
        NSLog(@"[FUBG] setActive failed: %@", e); return NO;
    }
    return YES;
}

// 白噪是编译期常量，只解码一次缓存复用
static NSData *FUBG_noiseData(void) {
    static NSData *d; static dispatch_once_t t;
    dispatch_once(&t, ^{
        d = [[NSData alloc] initWithBase64EncodedString:kFBGNoiseB64
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
    });
    return d;
}

static void FUBG_buildAndPlay(void) {
    @try {
        NSData *data = FUBG_noiseData();
        if (!data.length) return;
        AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:data error:nil];
        if (!p) return;
        p.numberOfLoops = -1;
        p.volume = 0.0f;   // 静音
        [p prepareToPlay];
        [p play];
        gPlayer = p;
    } @catch (__unused NSException *e) {}
}

static void FUBG_startAudio(void) {
    if (!gUseAudio) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask == 0) {
            gTask = [app beginBackgroundTaskWithName:@"fubg-bridge" expirationHandler:^{
                NSLog(@"[FUBG] bridge task expired");
                if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
            }];
        }
        if (FUBG_activateSession() && (!gPlayer || !gPlayer.isPlaying)) {
            if (gPlayer) { [gPlayer play]; }
            else { FUBG_buildAndPlay(); }
        }
        NSLog(@"[FUBG] audio keep-alive started (audioMode=%d)", gHasAudioMode);
    } @catch (__unused NSException *e) {}
}

static void FUBG_stopAudio(BOOL releaseSession) {
    @try {
        if (gPlayer.isPlaying) [gPlayer pause];
        // mix 模式下保持 session 激活、不主动 setActive:NO，避免与目标 App
        // 自身音频会话打架造成卡顿；仅彻底关闭时通知他人恢复。
        if (releaseSession) {
            [[AVAudioSession sharedInstance] setActive:NO
                                          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                                error:nil];
        }
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
    } @catch (__unused NSException *e) {}
}

#pragma mark - 看门狗（按需装卸，进后台才装、回前台即卸）

static void FUBG_watchdogStop(void) {
    if (gWatchdog) { [gWatchdog invalidate]; gWatchdog = nil; }
}

static void FUBG_watchdogFire(NSTimer *t);   // 前向声明

static int gWatchdogStrikes = 0;
static int gWatchdogBackoff = 0;
static NSTimeInterval gWatchdogStep = 3.0;

static void FUBG_watchdogStart(void) {
    if (gWatchdog || !gUseAudio || !gPhysBg) return;
    // 低电量模式下自愈周期 3s → 6s（后台保活本身耗电）
    BOOL lowPower = NO;
    @try { lowPower = [NSProcessInfo processInfo].isLowPowerModeEnabled; } @catch (__unused NSException *e) {}
    NSTimeInterval step = lowPower ? 6.0 : 3.0;
    gWatchdogStep = step;
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:step repeats:YES
                                                  block:^(NSTimer *t){ FUBG_watchdogFire(t); }];
    NSLog(@"[FUBG] watchdog started, interval=%.1fs (lowPower=%d)", step, lowPower);
}

// 自愈轮询：仅在停摆时重建；连续 3 次失败退避约 30s，兼顾可靠与耗电
static void FUBG_watchdogFire(__unused NSTimer *t) {
    if (!gUseAudio || !gPhysBg) return;
    if (gWatchdogBackoff > 0) {
        if (--gWatchdogBackoff == 0) {
            gWatchdogStrikes = 0;
            NSLog(@"[FUBG] watchdog: backoff ended, strike counter reset");
        }
        return;
    }
    @try {
        if (!gPlayer || !gPlayer.isPlaying) {
            NSLog(@"[FUBG] watchdog: player stopped, rebuilding (strike %d)", gWatchdogStrikes + 1);
            FUBG_activateSession();
            if (gPlayer) { [gPlayer play]; }
            else { FUBG_buildAndPlay(); }
            if (gPlayer && gPlayer.isPlaying) {
                if (gWatchdogStrikes > 0)
                    NSLog(@"[FUBG] watchdog: recovered after %d failed rebuild(s)", gWatchdogStrikes);
                gWatchdogStrikes = 0;
            } else if (++gWatchdogStrikes >= 3) {
                // 按秒换算退避，低电量（6s 周期）下也真的退避约 30s
                double step = (gWatchdogStep > 0.5) ? gWatchdogStep : 3.0;
                gWatchdogBackoff = (int)MAX(1.0, round(30.0 / step));
                NSLog(@"[FUBG] watchdog: 3 consecutive rebuilds failed, backing off %.0fs (%d ticks @ %.1fs)",
                      30.0, gWatchdogBackoff, step);
            }
        } else {
            gWatchdogStrikes = 0;
        }
    } @catch (__unused NSException *e) {}
}

static void FUBG_onInterruption(NSNotification *note) {
    if (!gUseAudio) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
    NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
    if (opt.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gUseAudio && gPhysBg) {
                FUBG_activateSession();
                if (gPlayer) { [gPlayer play]; } else { FUBG_buildAndPlay(); }
            }
        });
    }
}

#pragma mark - 生命周期

static void FUBG_onEnterBackground(__unused NSNotification *note) {
    gPhysBg = YES;
    FUBG_startAudio();
    FUBG_watchdogStart();   // 只在真后台装看门狗，前台不空转
}

static void FUBG_onEnterForeground(__unused NSNotification *note) {
    gPhysBg = NO;
    FUBG_watchdogStop();    // 回前台立即卸载
    // 回前台只暂停播放、保留会话（mix 模式下不与 App 音频冲突）
    if (gPlayer.isPlaying) [gPlayer pause];
    if (gTask != 0) {
        [[UIApplication sharedApplication] endBackgroundTask:gTask];
        gTask = 0;
    }
}

static void FUBG_onPrefReload(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    // 主线程串行 reload：gExclude 换数组时若另线程正在 for-in 旧数组会 EXC_BAD_ACCESS
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            FUBG_loadPref();
            NSLog(@"[FUBG] prefs reloaded: active=%d scene=%d audio=%d override=%d physBg=%d",
                  gActive, gUseScene, gUseAudio, gHasAppOverride, gPhysBg);
            if (!gUseAudio && gPhysBg) { FUBG_stopAudio(NO); FUBG_watchdogStop(); }
            if (gUseAudio && gPhysBg && (!gPlayer || !gPlayer.isPlaying)) { FUBG_startAudio(); FUBG_watchdogStart(); }
        } @catch (__unused NSException *e) {}
    });
}

#pragma mark - 入口

__attribute__((constructor))
static void FUBGEntry(void) {
    @autoreleasepool {
    // 全程 @try 包裹：保活引擎装不上也不能拖垮目标 App
    @try {
        FUBG_loadPref();

        // hook 一次性安装，内部按全局开关决定行为
        dispatch_async(dispatch_get_main_queue(), ^{
            FUBG_installSceneHooks();
        });

        gObs = [NSMutableArray array];

        // 前后台感知：进程内 NSNotificationCenter（Darwin 总线收不到这两个通知）
        id obBg = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *n){ FUBG_onEnterBackground(n); }];
        id obFg = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *n){ FUBG_onEnterForeground(n); }];
        if (obBg) [gObs addObject:obBg];
        if (obFg) [gObs addObject:obFg];

        // 配置热重载是跨进程的（配置端用 Darwin 广播），这一条走 Darwin 中心
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, FUBG_onPrefReload,
            (__bridge CFStringRef)kNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // 来电中断恢复 + 线路变化恢复（token 必须持有）
        id obInt = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n){ FUBG_onInterruption(n); }];
        id obRoute = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(__unused NSNotification *n){
                if (gUseAudio && gPhysBg) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        // player 为 nil 时补重建（否则线路变化后音频保活永久失效）
                        if (gPlayer) {
                            if (!gPlayer.isPlaying) [gPlayer play];
                        } else {
                            FUBG_buildAndPlay();
                        }
                    });
                }
            }];
        if (obInt)   [gObs addObject:obInt];
        if (obRoute) [gObs addObject:obRoute];

        NSLog(@"[FUBG] v1.0.0-keepalive (based on SIOriginal v2.4.3) loaded in %@: active=%d scene=%d audio=%d audioMode=%d%@",
              FUBG_bundleID().length ? FUBG_bundleID() : @"?",
              gActive, gUseScene, gUseAudio, gHasAudioMode,
              (gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)");
    } @catch (NSException *e) {
        NSLog(@"[FUBG] keep-alive install failed (app unaffected): %@", e);
    }
    }
}
