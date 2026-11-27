# BUILD_NOTES.md — 假设与未验证项（v2）

本文件列出构建 YiPlayer v1 + v2 时做的每一个假设和每一条未验证的说法。
**v2 没有在 Xcode / 真机上构建或测试过** —— 本机是 Linux VM，没有
macOS / Xcode；只做了 YAML 语法、Swift 括号平衡、Python/JS 语法、
以及文件引用完整性等静态检查（见“已验证”）。
v1 的构建是真的（GitHub Actions run #4 成功，265 KB 未签名 IPA，
见“v1 历史”），v2 的构建还没有跑过。

## v2 改了什么（相对 v1）

- **py 源成真了**：`Runtime/PythonHost/`（`ApplePython.c/.h` C 桥、
  `spiders/_yi_bridge.py`、`spiders/base/` 最小 `base.spider`、
  `spiders/pd.py` 522 行拷贝、纯 Python `requirements.txt`）+
  `YiCore/PySource.swift` 重写（`EmbeddedPythonHost`，按 pd.py 真实接口
  调 `homeContent` / `categoryContent` / `detailContent` /
  `searchContent` / `playerContent` / `init`）。Python 框架不在仓库里，
  由 `Scripts/fetch-python.sh` 在 CI 下载（BeeWare 3.13，
  GitHub API 解析资产名，找不到就大声失败）。框架缺失时仍保留
  v1 的 “iOS 暂不支持 Python 运行时” 提示（仅限框架缺失时）。
- **猫源成真了**：`Runtime/NodeHost/`（`NodeHost.swift`、
  `NodeBridge.h/.mm`、`host.mjs` / `worker.mjs` 自写控制协议，
  按 tvbox-silicon 的 NodeHost 协议和 CatPawOpen bundle 格式）+
  `YiCore/CatSource.swift` 改写：`.md5` 校验后，服务端 bundle
  写进 Application Support，用内嵌 Node.js 26 在 127.0.0.1 上起
  Fastify 服务，走 `/spider/<站点>/{init,home,category,detail,play,search}`；
  websiteBundle 仍走 JavaScriptCore。Node 框架由
  `Scripts/fetch-node-mobile.sh` 在 CI 下载（jo32/nodejs-mobile
  26.13.0，SHA-256 校验，事实数据来自 tvbox-silicon 的公开脚本）。
- **首页不再空着**：`SubscriptionStore` 首次启动自动种入懂片帝
  （py）和 9280 猫源；`HomeView.loadHome` 依次试每个源，第一个
  有内容的胜出；`DetailView.play` 真正用选中的线路；
  `DiscoverView` 的分类按源来，py 源有日/周/月/总榜切换；
  `SourceRunner` 加了 `categories()` 和带 filter 的 `category()`
  （必须是协议方法，不能只是 extension 方法——否则 `any SourceRunner`
  调用时永远走默认实现，见 Source.swift 注释）。
- **导入修好了（LiveContainer）**：粘贴导入（文本框 + 剪贴板按钮）；
  文件导入允许 `.json` / `.javascript` / `.pythonScript` /
  `.plainText` + `UTType.data` 兜底，选中的文件先复制进
  Documents 再读，按扩展名分流（`.json` TVBox JSON、`.js` 猫源、
  `.py` py 源、`.txt` 按内容判断），失败显示具体原因。
- **ATS**：`NSAllowsArbitraryLoads = true` + `NSAllowsLocalNetworking = true`，
  Info.plist 和 project.yml 各一份。另见下面的“ATS 之谜”。
- **图标**：`YiPlayer.xcassets` 接进工程，`ASSETCATALOG_COMPILER_APPICON_NAME:
  AppIcon`（v1 删掉这两项只是因为当时没有 xcassets）。
- **工作流**：加了运行时下载（`vendor/` 缓存）、纯 Python 依赖安装
  （`.so` 检查）、根目录 pd.py 同步；触发路径加了 `Scripts/**`、
  `Runtime/**`、`**.py`、`**.mjs`。
- **v1 遗留 bug 修掉**：首页只试第一个源；详情忽略选中线路；
  取消的 `.task` 被当成错误显示红字 "cancelled"（这就是用户在
  LiveContainer 里看到的首页红字——是设计好的诚实提示，不是崩溃，
  但取消不应该显示）；`HomeView` / `DetailView` / `DiscoverView`
  现在都忽略 `CancellationError`。

## 已验证（在本机上，v1 + v2）

- `project.yml` 和 `.github/workflows/build-ios.yml` 的 YAML 语法
  （`python3 -c yaml.safe_load` 通过）。
- 全部 Swift 文件括号 / 花括号平衡（脚本检查通过）。
- `App/Info.plist` 可解析（plistlib），含 `NSAllowsArbitraryLoads: true`
  + `NSAllowsLocalNetworking: true`，版本 2.0.0 / build 2。
- `Runtime/PythonHost/spiders/_yi_bridge.py`、`base/spider.py`、
  捆绑的 `pd.py` 可 `python3 -m py_compile`（如本机有 python3）。
- `Runtime/NodeHost/host.mjs`、`worker.mjs` 可 `node --check`（如本机有 node）。
- `Scripts/fetch-python.sh`、`fetch-node-mobile.sh` 的 `sh -n` 语法检查。
- project.yml / 工作流引用的每个文件都在仓库里（`vendor/` 两个
  xcframework 除外——它们是 CI 生成的，不提交；`xcodegen generate`
  时缺失会直接失败，见上）。
- 2026-11-27 静态审计（v1）修掉的构建硬错：`onLongPressGesture`
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
- 9280 猫源地址可达性与内容标记（2026-11-27 调研）：
  `.md5` 只有一行 `d8e69da8c37a29afe50fdc8de9dbf268`；
  `index.js` 17,087 行，是 Fastify 服务端 bundle，不是 websiteBundle。
- nodejs-mobile 下载事实（2026-11-27 读 tvbox-silicon 的
  `Scripts/fetch-node-mobile.sh` 全文）：VERSION=26.13.0，
  RELEASE=v26.13.0-tvbox.1，资产 `nodejs-mobile-v26.13.0-apple.zip`，
  SHA-256 `a84ac23e389f186dc64a78e2350b747b6e3f6cf56db12c9e1c3561db156b6440`，
  LICENSE SHA-256 `12d632aa78f637d8c899f19d4549538c477b6df3836fe86731cd821f750abac8`。
- NodeHost 控制协议事实（2026-11-27 读 tvbox-silicon 的
  `Runtime/NodeHost/main.mjs` 893 行 + `worker.mjs` 151 行全文）：
  `node main.mjs <controlFile> <relistenFile>`，控制文件写
  `{"port": n, "token": "..."}`，`POST /call` + `x-yingxia-token`，
  body `{bundle, api, profile, cloudAccounts, proxy, params}`，
  worker 提供 `catServerFactory` / `catDartServerPort()`，
  bundle 导出 `start(config)`，20 秒等服务监听，`/config` +
  `POST /spider/<key>/{init,home,category,detail,play,search}`，
  搜索 404 → `{"list":[]}`，消息服务 `POST /msg`。
  YiPlayer 的 host.mjs / worker.mjs 是按这个协议自写的精简实现，
  不是 tvbox-silicon 代码的复制（省掉了云盘账号、HTTP 代理、
  配置中心登录三项，文件头里有说明）。
- BeeWare Python-Apple-support 发布事实（2026-11-27 读 releases 页）：
  最新非预发布是 3.13.18（b18）等；每个支持包是 `.tar.gz`，内含
  `Python.xcframework`（设备 + 模拟器切片），stdlib 在切片内
  `lib/` 下。资产文件名在抓到的页面文本里没出现，所以
  fetch-python.sh 在运行时用 GitHub API 解析，不硬编码文件名。
- pd.py 事实（2026-11-27 读全文，522 行）：只用 `sys/json/time/hmac/
  hashlib/os/requests` + 函数内 `uuid` / `urllib.parse.quote`，
  不用 lxml/bs4/regex/HTML 解析——所以 `base.spider` 兼容包只需
  Spider 基类那几个方法，`requirements.txt` 只需 requests 全家。

## 未验证（必须在 Mac / 真机 / Actions 上验证）

- **整个 v2 Xcode 构建**：`xcodegen generate` + `xcodebuild archive`
  从未跑过。风险点按顺序：① `vendor/` 两个 xcframework 是否
  下载成功并被 XcodeGen 认出来；② `NodeBridge.mm` 的
  `<node/node.h>` 头文件布局（project.yml 里写了两个切片的
  Headers 路径，未验证）；③ `ApplePython.c` 的 `<Python/Python.h>`
  是否随嵌入的 xcframework 自动找到；④ `.mm` / `.c` 文件是否
  被 XcodeGen 正确编进 target；⑤ `spiders/` 文件夹引用是否
  把 `base/` 层级原样打进包里；⑥ `host.mjs` / `worker.mjs`
  是否进了 bundle 的 Resources。
- **BeeWare stdlib 路径**：`ApplePython.c` 假设 stdlib 在
  `<Python.framework>/lib/python3.13`。如果 BeeWare 的包换了布局，
  首次 CI 日志会打印它试过的路径，按日志改后缀，不要猜。
- **9280 bundle 的 `/config` 和 `/play` 返回形状**：`CatSource`
  按 CatPawOpen 惯例解析（`/config` 的 sites/list/sources/data，
  `/play` 的 `{url}` / `{playUrl}` / 裸 URL）。如果 v2 装上后
  猫源列表为空或播不了，先看这两个形状是不是猜错了。
- **Node.js 服务端 bundle 实际能不能在 iOS 上跑起来**：worker 的
  20 秒等待、Fastify 在无 JIT 的 Node 26 下的启动时间、bundle
  依赖的 axios 等模块是否都在 bundle 内、bundle 要不要访问
  它自己的 `.config.js`——全部未验证。
- **py 源冷启动与包体**：+60–70 MB 是按 Yingxia 的 python-runtime-plan
  （66–68 MB/平台）估计的；首次调用 10–18 秒是 Yingxia 的实测，
  YiPlayer 自己的数字要等真机。
- **ATS 之谜（未解）**：v1 的 `App/Info.plist` 里**已经有**
  `NSAllowsArbitraryLoads: true`（2026-11-27 在工作区用 plistlib
  验证过），但用户在 v1 里导入 `http://www.y456y.com` 时仍然报
  "The resource could not be loaded because the App Transport Security
  policy requires the use of a secure connection"。最可能的解释是
  用户装的那个 IPA 是在加这个键之前构建的（v1 构建 #4 的 commit
  56ef702f 是 18:33，ATS 键的加入时间需要核对）；也不能排除
  LiveContainer 的启动路径绕过了 Info.plist。v2 在 project.yml
  的 info.properties 里也写了一份（双保险）并加了
  `NSAllowsLocalNetworking`。**如果 v2 仍报 ATS 错误，请把报错
  截图和 IPA 的构建时间发回来，不要只说“还是不行”。**
  另：`SubscriptionImporter.fetch` / `JsonSource.get` /
  `CatSource.fetchText` 都走 `URLSession.shared`，NodeHost 的
  loopback 调用走 ephemeral session——ATS 是 Info.plist 级别
  的系统强制，对所有 NSURLSession 生效，不存在“某个请求绕过
  ATS”的配置；Node 自己的 HTTP 栈本来就不受 ATS 约束。
- **LiveContainer 文件导入**：复制进 Documents 再读的方案是按
  LC 沙盒行为推断的（直接读安全域 URL 不可靠），没有在 LC 里
  验证过；如果仍失败，界面会写具体原因，请把那句话截图发回来。
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
- **TVBox JSON**：`JsonSource` 的 `ac=list/detail/vid` 参数是 MacCMS
  惯例，未对真实源验证；`detail()` 现在解析 `vod_play_url`
  （`Name$playid#...`，按 `$$$` 分线路）生成选集和 `playGroups`，
  `playLines` 按线路解析直链 URL，但 playid 是 token（需蜘蛛二次
  解析）时会被跳过。`isHDR` 在建 `AVPlayerItem` 后立即读，资源
  未加载时通常是 false，徽标可能不准；`PlayerViewModel.deinit`
  访问 MainActor 隔离属性在 Swift 5.10 下是警告。
- **NOCTRA / Rex 界面**：两家官网文本抓取看不到布局/截图
  （见 research-noctra-rex-cat.md），UI 是按“深色、接着看、
  海报墙、详情多来源聚合、液态玻璃 HUD”这些文字描述做的，
  不是像素级复刻。
- **图标**：`YiPlayer.xcassets` 的 15 个尺寸、tvOS、TopShelf
  都已在仓库里，但 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`
  是否被 XcodeGen 正确应用、图标在真机上是否显示，要等构建。

## v1 历史（已发生，不用再验证）

- 第 1 次 Actions 构建失败（2026-11-27 18:02，exit 65，3 个编译错，
  均已修）：`NWListener(..., on: .loopback)` 不是合法写法，改成
  `on: .any`（OS 分配临时端口，`.ready` 后读取）；`HomeView` 的
  `.background(.accent, ...)` 改成 `Color.accentColor`；
  `AVPlayerItem` 没有 `eligibleForHDRPlayback` 这个成员，v1 不再
  预检 HDR（播放仍原样透传，播不了时靠 CoreMedia -17223 报错，
  HDR 徽标在 v1 不显示）。另把播放器里 MainActor 隔离属性在
  Sendable 闭包里的修改包进 `Task { @MainActor ... }`，免得升
  Swift 6 后变报错。
- 构建 #4 成功（2026-11-27 18:33，run 45983066045，commit 56ef702f，
  56 秒）：artifact `YiPlayer-unsigned-ipa`，265 KB，
  sha256 `32322d7a9385c45de8ff5b486cd48d4d1526544637195366011c27b91afd61fe`，
  2026-12-11 18:34 CST 过期。用户反馈“啥也运行不了，只有 200 多 K”——
  265 KB 本身不是 bug（Swift 运行时在 iOS 里，v1 没有资源文件），
  真正的原因是 v1 首页是空的（没有预置源）且两个真实源都播不了，
  v2 针对这两点修。
- 所用 API 均为真实 API：SwiftUI（`TabView`、`NavigationStack`、
  `AsyncImage`、`VideoPlayer`）、AVKit（`AVPlayer`、`AVPlayerItem`）、
  AVFoundation、JavaScriptCore（`JSContext`）、Network（`NWListener`、
  `NWConnection`）、CryptoKit（`Insecure.MD5`、`SHA256`）、Foundation
  （`URLSession`、`UserDefaults`、`JSONSerialization`）。

## 假设

- 用户说的 “marcotv” 指 Pilipala9919/MarcoMovie（播放器），
  不是 MarcoTV（Android TV 启动器）。见 research-tvbox-marcotv.md。
- `pd.py` 是 CatVod py 蜘蛛（懂片帝，dongpian17.com），已在仓库
  根目录，522 行，2026-11-27 已读。接口与 555.py 不同：/v1/*
  REST + HMAC-SHA256 签名，分类 全部/电影/剧集/短剧/动漫/综艺 ×
  日/周/月/总榜，播放 id 是 `<token>` 或 `<token>@@<line_id>`，
  经 resolve + resolve-line 二次解析，官方线路优先、4K 排前，
  匿名游客会话自动登录；`localProxy` 是空实现。v2 的
  `base.spider` 兼容包只实现 pd.py 实际用到的基类方法
  （`__init__` / `init` / `getName` / `isVideoFormat` /
  `manualVideoCheck` / `destroy` / `localProxy` / `fetch`），
  其它 CatVod py 蜘蛛如果用到更多 base API（正则/HTML 清洗等），
  要再补——不要假设这个包能跑任意 py 蜘蛛。
- `catvodsub.txt` 里只有 9280 那个猫源地址（用户消息里只给了这一个）。
- 用户的 GitHub 仓库是 dongxipaopao/YiPlayer（main 分支），
  2026-11-27 已连接 Muse（账号 dongxipaopao），仓库里已有
  根目录的 pd.py 和 catvodsub.txt；骨架推送时不覆盖这两个文件。
- iPhone + iPad 通用（`TARGETED_DEVICE_FAMILY: 1,2`，用户 2026-11-27
  决定：先做手机+iPad 通用 IPA，测试没问题后再做 tvOS）。tvOS 是下一步。
- 免费 GitHub Actions macos-15 runner 可用；未签名 IPA 的
  14 天 artifact 保留期足够用户下载。

## 已知缺口（v2 明确不做）

- MKV/AV1 重封装（无 FFmpeg）、下载/离线、直播、弹幕、
  Trakt/iCloud 同步、浅色主题、tvOS、多端同步、
  云盘/音乐/漫画/小说、JVM/DEX。
- 任意 py 蜘蛛的通用支持（只保证 pd.py；其它蜘蛛按需补 base API）。
- 任意猫源 bundle 的通用支持（只保证 9280 这种 Fastify 服务端
  bundle 和 websiteBundle 两种结构；`/config` / `/play` 形状
  是按惯例推断的，见“未验证”）。

## 图标怎么进仓库（v2 新增）

`YiPlayer.xcassets` 里的 .png 不能走文本接口推送，所以打成
`icons-b64/part-*`（gzip tarball 的 base64 分片，每片 220 KB）一起
推送，工作流的 "Restore icon assets" 步骤在 `xcodegen generate`
之前解出来。换图标时重新打包分片即可；`.github/workflows/build-ios.yml`
仍需走网页上传（接口对 workflow 文件返回 403，v1 已验证）。
