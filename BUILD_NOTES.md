# BUILD_NOTES.md — 假设与未验证项（v1）

本文件列出构建 YiPlayer v1 时做的每一个假设和每一条未验证的说法。
**IPA 没有在 iOS 上构建或测试过** —— 本机是 Linux VM，没有 macOS /
Xcode；只验证了 YAML 语法、Swift 文件的括号平衡与 API 名称、
以及离线 mock 之外的静态检查（见“已验证”）。

## 已验证（在本机上）

- `project.yml` 和 `.github/workflows/build-ios.yml` 的 YAML 语法
  （`python3 -c yaml.safe_load` 通过）。
- 全部 Swift 文件括号 / 花括号平衡（脚本检查通过）。
- 2026-11-27 静态审计（见下）修掉的构建硬错：`onLongPressGesture`
  的 `onPressingChanged:` 标签、`NWListener(..., on: .loopback)` 类型、
  `xcodeVersion: "16.0"` 校验、空 `CODE_SIGN_ENTITLEMENTS`、
  不存在的 AppIcon / AccentColor 引用。审计还修了播放链：
  `CatJSRuntime.callSpider` 现在解析 `playerContent` 返回的
  `url` 成一条 PlayLine；`JsonSource.videoItem` 现在按 `$$$` 解析
  `vod_play_from` / `vod_play_url` 生成选集，`playLines` 按
  `playGroups` 解析出每条线路；`loadBundle` 只在 `.md5` 地址时
  才做 MD5 校验；`JsonSource.get` 按 `ac=list/detail/vid` 传参；
  HLS 代理端口只在 listener `.ready` 后读取；文件导入加了
  security-scoped 访问；Info.plist 的 `armv7` 改 `arm64`、
  加了 `UILaunchScreen` 和 iPad 方向。
- 所用 API 均为真实 API：SwiftUI（`TabView`、`NavigationStack`、
  `AsyncImage`、`VideoPlayer`）、AVKit（`AVPlayer`、`AVPlayerItem`、
  `eligibleForHDRPlayback`）、AVFoundation、JavaScriptCore
  （`JSContext`）、Network（`NWListener`、`NWConnection`）、
  CryptoKit（`Insecure.MD5`、`SHA256`）、Foundation（`URLSession`、
  `UserDefaults`、`JSONSerialization`）。
- 9280 猫源地址可达性与内容标记（2026-11-27 调研）：
  `.md5` 只有一行 `d8e69da8c37a29afe50fdc8de9dbf268`；
  `index.js` 17,087 行，是 Fastify 服务端 bundle，不是 websiteBundle。

## 未验证（必须在 Mac / 真机上验证）

- **整个 Xcode 构建**：`xcodegen generate` + `xcodebuild archive`
  从未跑过。`project.yml` 的 `info.path`、`INFOPLIST_FILE`、
  `CODE_SIGN_ENTITLEMENTS: ""` 等字段在真机上可能需要调整。
- **GitHub Actions 工作流**：从未跑过。`macos-15` 镜像的 Xcode
  版本、`brew install xcodegen`、archive 路径
  `build/YiPlayer.xcarchive/Products/Applications/YiPlayer.app`
  都是按 Yingxia / MarcoMovie 的公开工作流推断的。
- **JS 运行时**：`CatJSRuntime` 的 `JSContext.setObject` 传入
  `@convention(block)` 闭包、`JSValue.toDictionary()` 的类型、
  `net.req` 里的同步信号量等待，在真机上可能需要改成
  JSExport / 异步回调。v1 的 Spider 调用只解析了
  `{"list": [...]}` 这一层形状，完整 CatVod 结果解析未实现。
- **HLS loopback 代理**：`NWListener` 在 iOS 后台 / 锁屏时的行为、
  并发连接处理、HTTP 分块传输未验证；v1 是最小实现（一次一连接）。
- **播放**：HDR / DV 不偏色、0.5x–4x、双击/长按手势、音轨字幕
  选择、断点续播，全部未在真机上验证。手势组合
  （双击 + 长按 + 拖动）在同一 `VideoPlayer` 上可能冲突，
  真机上要调。
- **猫源回退**：`SOURCE_ORDER: douban,360,renren,hanjutv` 的回退
  目前只在 `CatSource.loadBundle()` 的错误信息里说明，
  没有实现“回退成四个可播源”的代码 —— 因为那四个源本身
  也是 JS 站点，需要运行时支持。README 里写的是“回退到
  SOURCE_ORDER 并说明限制”，不是“回退后能播”。
- **TVBox JSON**：`JsonSource` 的 `ac=list/detail/vid` 参数是 MacCMS
  惯例，未对真实源验证；`detail()` 现在解析 `vod_play_url`
  （`Name$playid#...`，按 `$$$` 分线路）生成选集和 `playGroups`，
  `playLines` 按线路解析直链 URL，但 playid 是 token（需蜘蛛二次
  解析）时会被跳过，那种源在 v1 播不了。`isHDR` 在建
  `AVPlayerItem` 后立即读，资源未加载时通常是 false，徽标可能
  不准；`PlayerViewModel.deinit` 访问 MainActor 隔离属性在
  Swift 5.10 下是警告。
- **NOCTRA / Rex 界面**：两家官网文本抓取看不到布局/截图
  （见 research-noctra-rex-cat.md），UI 是按“深色、接着看、
  海报墙、详情多来源聚合、液态玻璃 HUD”这些文字描述做的，
  不是像素级复刻。

## 假设

- 用户说的 “marcotv” 指 Pilipala9919/MarcoMovie（播放器），
  不是 MarcoTV（Android TV 启动器）。见 research-tvbox-marcotv.md。
- `pd.py` 是 CatVod py 蜘蛛（懂片帝，dongpian17.com），已在仓库
  根目录，522 行，2026-11-27 已读。接口与 555.py 不同：/v1/*
  REST + HMAC-SHA256 签名，分类 全部/电影/剧集/短剧/动漫/综艺 ×
  日/周/月/总榜，播放 id 是 `<token>` 或 `<token>@@<line_id>`，
  经 resolve + resolve-line 二次解析，官方线路优先、4K 排前，
  匿名游客会话自动登录；`localProxy` 是空实现。PySource.swift
  已按这个真实接口写注释，v1 仍是桩（iOS 无 Python 运行时）。
  v2 还要提供 pd.py 依赖的 `base.spider` 包（`sys.path.append('..')`）。
- `catvodsub.txt` 里只有 9280 那个猫源地址（用户消息里只给了这一个）。
- 用户的 GitHub 仓库是 dongxipaopao/YiPlayer（main 分支），
  2026-11-27 已连接 Muse（账号 dongxipaopao），仓库里已有
  根目录的 pd.py 和 catvodsub.txt；骨架推送时不覆盖这两个文件。
- iPhone + iPad 通用（`TARGETED_DEVICE_FAMILY: 1,2`，用户 2026-11-27
  决定：先做手机+iPad 通用 IPA，测试没问题后再做 tvOS）。tvOS 是下一步。
- 免费 GitHub Actions macos-15 runner 可用；未签名 IPA 的
  14 天 artifact 保留期足够用户下载。

## 已知缺口（v1 明确不做）

- py 源（桩）、MKV/AV1 重封装（无 FFmpeg）、下载/离线、
  直播、弹幕、Trakt/iCloud 同步、浅色主题、tvOS、
  多端同步、云盘/音乐/漫画/小说、JVM/DEX。
