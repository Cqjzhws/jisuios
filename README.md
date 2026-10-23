# 极速IOS（原 SIOriginal）v2.4.3

iOS 动画加速 + 手感 + 真后台保活。面向 iOS 14–17，适配 TrollStore / TrollFools，无需 CydiaSubstrate。

- 配置 App 桌面名：**极速IOS**
- dylib 文件名与 install_name 保持 `SIOriginal.dylib`（TrollFools 注入兼容，勿手动改名）
- bundle id `com.local.sioriginal`、配置路径 `/var/Managed Preferences/mobile/com.apple.UIKit.plist`、热重载通知名均保持不变 —— 覆盖安装不会丢配置

## v2.4.3 变更：保活与崩溃的平衡点

v2.4.2 把微信整段排除出场景伪装，**实测不可接受**：微信收不到 `didEnterBackground` 就不会
主动断长连接（这是它能「切回秒开」的唯一原因）；一旦恢复真实生命周期，微信按自己的省电
逻辑把长连接降级成推送通道，每次切回都要重连。

本版改回「吞 diff」，但把崩溃点定点掐掉：

```c
// 假前台期间，只有后台工作队列能拿到真实答案
if (gUseScene && _fbg_isBackgroundWorkerThread()) return UIApplicationStateBackground;
```

判定依据是当前队列 label（`dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)`），
命中 `.fts.` / `mainIndex` / `.index.` / `IndexQueue` 即为后台工作线程，结果按线程用
`__thread` 缓存，热路径没有额外 dladdr、没有分配。

效果：主线程与网络线程仍拿 `Active`（保活/秒回不变），微信 FTS 索引线程拿 `Background`，
走它自己的后台索引分支，不再按前台路径去取已被回收的上下文。

**边界**：这是对已知崩溃线程的定点规避，不是「假前台绝对安全」的证明。再出现同类崩溃时，
把新线程的队列 label 关键词加进 `_fbg_isBackgroundWorkerThread` 即可，不必改动其他逻辑。

## v2.4.2 变更（历史）

### 1. 改名

| 位置 | 改动 |
| --- | --- |
| `App/Info.plist` → `CFBundleDisplayName` / `CFBundleName` | `SI Original` / `SIOriginal` → `极速IOS` |
| App 内首页副标题 | `SIOriginal · 动画加速超强版` → `极速IOS · 动画加速超强版` |
| 配置导出报告 / 提示文案 | 品牌名统一为 极速IOS |
| 构建产物 | `极速IOS.ipa`（dylib 仍为 `SIOriginal.dylib`） |

内部标识（bundle id / dylib 名 / 偏好键名 / Darwin 通知名）一律未动，属于「只改名不改接口」。

### 2. 修复微信闪退（FTS 全文索引线程空指针）

`.ips`（WeChat 8.0.58 / iOS 16.2 / iPhone 14 Pro）关键事实：

```
exception        EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0000000000000018
faultingThread   queue = com.tencent.xin.fts.mainIndex
主线程           libsystem_kernel mach_msg（进程真实处于后台）
栈帧             全部为 WeChat 自身二进制，无注入库帧
vmRegionInfo     0x18 is not in any region（纯 nil 解引用，nil + 0x18）
```

微信全文索引线程按 `UIApplication.applicationState` 决定走前台还是后台路径。
v2.4.1 及之前，FUBG 场景伪装会：

1. 在 `FBSWorkspaceScenesClient -sceneID:updateWithSettingsDiff:...` 里吞掉 backgrounding diff；
2. 在 `UIApplication -applicationState` 上把返回值硬编码成 `UIApplicationStateActive`。

索引线程因此按**前台路径**去取只在前台有效的上下文，拿到 nil 后读 `+0x18` 崩溃。
同一落点也是此前记录的「微信聊天视频切走出现两个画面」的诱因。

**修法**：新增场景伪装硬排除名单 `_fbg_sceneHardExcluded()`，名单内 App（当前为
`com.tencent.xin`）只保留音频断言保活，不再参与 scene diff 吞并与 appState 伪装。
音频断言不伪造任何系统状态，不会让目标 App 的业务逻辑错乱。

```
gUseScene = gActive && gSceneFake && !_fbg_sceneHardExcluded();   // 微信恒为 NO
gUseAudio = gActive && gAudioKeep;                                 // 微信照常
```

排障：启动日志 `[FUBG] v2.4.2 ... scene=0 audio=1` 即代表补丁生效。

## 目录

```
Tweak/SIOriginal.m        # dylib 主体（动画加速 + 手感 + HUD + FUBG 保活）
Tweak/FUBGNoiseData.h     # 保活用静音白噪 base64
App/main.m                # 配置 App（纯代码 UI）
App/Info.plist            # 显示名：极速IOS
entitlements.plist
tools/config_contract.py  # 构建前配置契约门禁
.github/workflows/build.yml
```

## 界面改版：iOS 26 玻璃质感（仅配置 App）

> 只动 `App/main.m` 的呈现层，**没有改任何配置键、默认值、写入路径或 dylib**。
> `config_contract.py` 门禁仍然通过（键集合双向一致 + 四处默认值一致）。

设计语言四层，改的都是公共构件，四个页面自动跟着变：

| 层 | 实现 |
| --- | --- |
| 底 | `SIOAmbientView`：三团 `kCAGradientLayerRadial` 光斑（祖母绿 / 天蓝 / 青柠），浅深各一套 |
| 玻璃 | `SIOGlassView`：`UIVisualEffectView` + 半透明白 tint（浅 66% / 深 10%） |
| 高光 | 顶部 55% 的白色 sheen + 1px 描边（`SIOBorder()`，浅色发白、深色发灰） |
| 阴影 | 外层双层投影（近 2 / 远 18），卡片 `elevated = YES` 才开 |

改动的公共构件：

- `SIOCard` → 26pt 连续圆角的玻璃卡（原来是不透明 `secondarySystemGroupedBackgroundColor`）
- `SIOPill` / `SIOPresetButton` → `SIOGlassButton`，调用方传的实心色自动换算成 **16% tinted glass**；
  「白底 + 彩字」的那批按钮识别为描边款，发丝描边跟着文字色走
- `SIOFieldTextView` / 高级页 Bundle ID 输入框 → 玻璃输入面
- `SIOGradientHeader` → 渐变玻璃卡 + 发光状态点 + 玻璃版本徽章（渐变三档不变）
- 标签栏 → 自绘悬浮胶囊（`SIORootVC` + `SIOTabItem`），不再用 `UITabBarController`：
  系统标签栏做不出「内容从毛玻璃底下透过去」，也占安全区
- 导航栏 → 顶部完全透明（大标题浮在光斑上），滚动后切超薄磨砂条

深浅色：颜色全部走 `colorWithDynamicProvider`，**没有第二套常量**。
`borderColor` / `shadowColor` / 渐变这些 `CGColor` 快照由各玻璃视图在 `traitCollectionDidChange`
和 `didMoveToWindow` 里自己重刷 —— 老代码那段「递归把所有描边刷成 `separatorColor`」的补丁已删除，
它会把玻璃高光冲掉。

动态反馈：`SIOGlassButton` / `SIOTabItem` 按下缩到 0.975、透明度 0.92（120ms 进 / 180ms 回），
开关与分段仍保留 `.light` 轻触反馈，滑杆拖动不震动。

### v2.5.1 修正（真机第一轮回馈）

真机上「引擎 / 手感 / 高级」三页整体横向溢出、左右各被切掉一段，系统页正常。三个问题：

1. **内容列被撑宽**。`viewDidLoad` 里 `stack.width == scroll.frameLayoutGuide.width - 40`
   的优先级写成了 750，而 `UISegmentedControl` 的横向 compression resistance 默认也是 750。
   两者打平时 Auto Layout 选择撑大 stack，卡片跟着宽出屏幕约 18pt，圆角全被切到视野外。
   → 宽度约束提到 999；同时 `SIOLoosenWidth()` 把内容树的横向阻力统一降到 749
   （遇到 `UIControl` 就不再往下钻，系统控件内部不动）；分段控件额外 `apportionsSegmentWidthsByContent = NO`。
2. **最后一张卡被悬浮标签栏永久压住**。scroll 一直延伸到屏幕底（好让内容从毛玻璃底下透过去），
   但没补 `contentInset`。→ `viewDidLayoutSubviews` 里补 74 + 4 + 12 + 安全区。
3. **深色下玻璃没有可折射的底**。光斑透明度只有 0.20 / 0.15 / 0.10，在近黑底上几乎不可见，
   整屏看起来就是「黑底 + 灰板」。→ 提到 0.34 / 0.26 / 0.19。

### 非 macOS 环境打包（重要）

CI 里是 `codesign --force --sign - --entitlements entitlements.plist "$APP"`。
如果只编译不签名，二进制里没有 code signature 段，`ldid -e` 读不到 entitlements，
安装后 App 会退回默认沙箱 —— 表现就是「保存失败：无法写入 com.apple.UIKit.plist」。

Windows 上没有 codesign / ldid，用 `tools/adhoc_sign.py` 补：

```bash
python tools/adhoc_sign.py Payload/SIOriginal.app/SIOriginal SIOriginal entitlements.plist
```

它构造 `SuperBlob{ CodeDirectory(SHA-256), blobWrapper(Entitlements) }`、插入 `LC_CODE_SIGNATURE`、
把 `__LINKEDIT` 的 filesize 撑到签名末尾。

兼容与性能：

- iOS 26 优先用 `UIGlassEffect`（`NSClassFromString` + `objc_msgSend` 运行时探测，
  旧 SDK 里没有这个符号也能编译；`-miphoneos-version-min=14.0` 不变）
- iOS 14–25 回落 `UIBlurEffectStyleSystemMaterial`
- 只有卡片 / 标签栏 / 头部叠真模糊；胶囊和预设块只用半透明色，不叠 `UIVisualEffectView`
- 响应式：内容最大宽度 720 居中，标签栏封顶 420 居中（iPad 上不会拉成一条长横幅）

调参入口集中在 `main.m` 设计系统段顶部：`SIOSurface()` / `SIOBorder()` / `SIOAccent()` 等函数，
改一处全 App 生效。

## 构建

推 `jisuios-v*` 或 `sioriginal-v*` tag，或手动 `workflow_dispatch` 触发 `build.yml`（macos-14 / Xcode）。

产物：`SIOriginal.dylib`（TrollFools 注入）+ `极速IOS.ipa`（TrollStore 安装）。

本地复现：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -arch arm64 -dynamiclib -O2 -install_name @rpath/SIOriginal.dylib \
  -isysroot "$SDK" -miphoneos-version-min=14.0 -undefined dynamic_lookup -fobjc-arc \
  -framework Foundation -framework UIKit -framework QuartzCore -framework AVFoundation -framework UserNotifications \
  -o SIOriginal.dylib Tweak/SIOriginal.m
```

## 运行时配置

- 配置文件：`/var/Managed Preferences/mobile/com.apple.UIKit.plist`
- 热重载通知：`com.local.sioriginal.settingschanged`；统计请求：`com.local.sioriginal.requeststats`
- App 级覆盖：`AppOverrides = { "<bundle id>" = { ...键... }; }`
- 微信 `com.tencent.xin` 在手感保护名单与 HUD 保护名单内；v2.4.2 起额外在场景伪装硬排除名单内
