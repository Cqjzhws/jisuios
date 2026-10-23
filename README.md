# 极速IOS（原 SIOriginal）v2.4.2

iOS 动画加速 + 手感 + 真后台保活。面向 iOS 14–17，适配 TrollStore / TrollFools，无需 CydiaSubstrate。

- 配置 App 桌面名：**极速IOS**
- dylib 文件名与 install_name 保持 `SIOriginal.dylib`（TrollFools 注入兼容，勿手动改名）
- bundle id `com.local.sioriginal`、配置路径 `/var/Managed Preferences/mobile/com.apple.UIKit.plist`、热重载通知名均保持不变 —— 覆盖安装不会丢配置

## v2.4.2 变更

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
