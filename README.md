# YiPlayer — 精简版视频播放器（v2.1.4）

Bundle ID `com.yiplayer.app` · SwiftUI · iOS 17+ · 无外部 Swift Package 依赖。
参考：tvbox-silicon（Yingxia）、MarcoMovie（“marcotv”最可能的所指）、
NOCTRA（noc.zijiu522.cn）、Rex（rexnow.tv）。调研见 `research-tvbox-marcotv.md`
和 `research-noctra-rex-cat.md`。**本仓库不含任何片库，也不内置任何源。**

v2.1.4 相对 v2.1.3 的变化：**修了 2026-11-28 11:37 真机实测的两个问题，
都是直接读 9280 bundle 实时代码确认的**（重新下载并对 .md5：
d8e69da8c37a29afe50fdc8de9dbf268，和 11 月 27 日一致，文件没换过）：
(1) **详情页没有线路、没有选集**——v2.1.3 真机上搜索能用，详情页
《巴黎绽放的星辰》有海报、标题和评分 7.2，但 `/detail` 返回 `{}`，
红字报错“解析失败：猫源 /detail 返回的结果里没有 list：{}”。
读 bundle 证实这不是请求写错了：Fastify 路由是 `t.detail &&
o.post("/detail", t.detail.bind(t))`，直接绑到蜘蛛的方法上，不包
装、不加字段；host.mjs 发的 `{id}` 正是蜘蛛读的 `body?.id`，/init
也早调过了（豆瓣蜘蛛的 init 本来就是空操作）。真正的原因是豆瓣
蜘蛛的 detail/search/play 全是空壳——`async detail(){return{}},
async play(){return{}},async search(){return{}}`，全 bundle 仅有的
两处空壳（另一处是 `gengxin`，名字就是日期戳 "日期:20261127"）；
它的 home/分类是真的（拉 frodo.douban.com 热榜，条目 id 是
`msearch:<豆瓣 id>`），所以海报标题评分都正常，唯独没有线路。
修法：`/detail` 返回空且 id 是 `msearch:` 开头时，按片名去 bundle
里别的站并行搜（最多 8 个），取标题匹配的站再调它的 `/detail` 拿
线路；`/play` 也走那个站的路由；再失败时报错贴出本次请求的
route + body、原始返回前 300 字和试过的站。(2) **一个 bundle 只
显示 1 个源**——Yingxia 同款链接能看到几十个站，YiPlayer 只显示
douban。读 /config 证实：video 组有 93 个站，每条是
`{key:"nodejs_<key>",name:"名字|分组",type:3,searchable,api:"/spider/<key>/<type>"}`，
分组就是名字里 `|` 后面的标签（93 条里 91 条带 `|`，共 33 个分组，
如“玩偶|4K”、“花卷|秒播”）；Yingxia 截图里的分组名（推荐/摸鱼/蝴蝶/牛二）在
bundle 里出现 0 次，是 Yingxia 自己的分组，不照抄。修法：设置
里“展开全部站点”把一个 bundle 订阅展开成每个站一个独立的源
（各带自己的 api 路由，发现页按 `|分组` 展示、搜索并行搜这些站；
豆瓣站不参与搜索——它的 search 也是空壳）；展开后所有站共用
一个 bundle 文件和一个 Node worker（host.mjs 按文件路径起
worker，一站一个文件会起 90 个），同一次并行搜索也只下载一次
bundle。**但 v2.1.4 还没有在 Xcode / 真机上验证过**——见
BUILD_NOTES.md 的未验证清单；修法只在本机对真实 bundle 的代码
和 Node 24 实测验证过。

v2.1.3 相对 v2.1.2 的变化：**修了 9280 猫源“有分类没内容”的两个根因，
都是 2026-11-28 早上直接读 9280 bundle 实时代码确认的**（.md5 仍是
d8e69da8c37a29afe50fdc8de9dbf268，和 11 月 27 日一致，文件没换过）：
(1) 9280 的包是 CatVodSpiderios **独立服务器**，不是可嵌入的 CatPawOpen
bundle——它根本没有 `exports.start`（唯一的 module.exports 是死代码），
只在以 `node index.js` 独立运行、且没有 catServerFactory 时才自启；
而 v2.1.2 的 worker 定义了 catServerFactory，等于亲手把它的自启堵死了，
然后报 "The script is not a CatPawOpen bundle"。修法：worker.mjs 增加
standalone 模式——没有 exports.start 时不定义 catServerFactory、把
argv[1] 指向 bundle 文件本身（设备上本来就叫 index.js），等它的
/health 通了再把端口（9988 起，占用自动+1，按包自己的规则）报给
host.mjs；host.mjs 的 /call 路由不用改。启动失败时报错写明是 standalone
模式、等了多久、最后一次 /health 的结果。(2) 它的 /config 是**分组形状**
`{video:{sites:[...]},read:{sites:[]},comic:{...},...}`，v2.1.2 的解析
只认顶层 sites，认不到就把 video/read/comic 当成站，默认调不存在的
/spider/video。修法：解析 video.sites（以及 read/comic/music/pan），
直接用每条目的 `api` 字段（"/spider/douban/3" 这类）当调用路由——因为
/config 里的 key 是 `nodejs_<key>`，不能直接拼 /spider/ 后面；旧的顶层
sites 形状仍然能解析；/config 有返回但解析不到任何站点时直接报错并
贴出原始响应的前 300 字。**但 v2.1.3 还没有在 Xcode / 真机上验证过**
——见 BUILD_NOTES.md 的未验证清单；9280 的包本地也没有跑起来过，
修法只在合成测试包上验证过（见 BUILD_NOTES.md 的 v2.1.3 一节）。

v2.1.2 相对 v2.1.1 的变化：**修了 v2.1.1 在 LiveContainer 里实测仍卡住的
Python 导入失败**——初始化已经过了（"failed to read thread state"
消失），但 `_yi_bridge` 导入失败（错误码 5）。根因不是文件缺失：
`PyConfig.module_search_paths` 里手填的路径在初始化中途被 CPython
的 getpath 重算丢弃了，`sys.path` 里从来没有 spiders 目录（本机用
真实 CPython 3.12、同样的配置形状做了 5 组对照实验复现并验证了修法，
见 BUILD_NOTES.md 的 v2.1.2 一节）。修法：初始化成功后在 C 里显式
把 5 个目录插进 `sys.path` 再导入 `_yi_bridge`；导入前先校验
`_yi_bridge.py` 文件确实存在；导入再失败时把 Python 异常的真实内容
（类型、消息、traceback）加当时的 `sys.path` 一起记进错误，不再猜。
**同时修了猫源“有分类没内容、搜索没结果、界面一声不吭”**：
`/category`、`/search`、`/detail` 收到没有 `list` 的返回时不再静默
返回空列表，而是把原始响应（截取前 300 字）报出来——真正空的
分类/搜索（返回里有空 `list`）仍静默显示空状态。**但 v2.1.2 还没有
在 Xcode / 真机上验证过** —— 见 BUILD_NOTES.md 的未验证清单。

v2.1.1 相对 v2.1 的变化：**修了 v2.1.0 在 LiveContainer 里实测仍报的
Python 初始化失败**——报错是 "failed to read thread state"，根因是
初始化被从不同线程重复调用（CPython 3.13 里第二次调用走重配置分支，
当前线程没有 thread state 就失败；见 BUILD_NOTES.md 的 v2.1.1 一节）。
修法：初始化一生只跑一次、在同一个串行队列上跑、失败结果缓存起来
不再重试；同时补了 tvbox-silicon 配置里的 executable / utf8_mode /
信号忽略，Node 启动线程改成 2 MB 栈。

## v2 能做什么

- **py 源（内嵌 CPython 3.13）**：`Runtime/PythonHost/`（C 桥 `ApplePython.c` +
  Swift `EmbeddedPythonHost`）在应用内跑真正的 CPython，加载 pd.py
  （懂片帝，dongpian17.com，`/v1/*` REST + HMAC-SHA256 签名）：
  分类 全部/电影/剧集/短剧/动漫/综艺 × 日/周/月/总榜（发现页有榜单切换），
  详情取 `/v1/catalog/<vid>`，播放是 `<token>` 或 `<token>@@<线路ID>`，
  经 `/v1/playback/resolve` + `resolve-line` 二次解析，官方线路优先、
  4K 排前，匿名游客会话自动登录。pd.py 依赖的 `base.spider` 包已按
  pd.py 实际用到的接口写了一个最小兼容版（`Runtime/PythonHost/spiders/base/`），
  `requests` 用纯 Python wheel（site-packages 里不许出现 `.so`，
  工作流会检查）。Python 框架由 CI 下载，不提交进仓库。
  **代价**：包体预计 +60–70 MB，首次调用 py 源会慢（解释器冷启动，
  参考 Yingxia 的实测约 10–18 秒），之后正常。
- **猫源（两条路）**：`Runtime/NodeHost/`（Swift `NodeHost` + `.mm` 桥 +
  自写的 `host.mjs` / `worker.mjs`，按 Yingxia 的控制协议）内嵌
  Node.js 26 LTS（无 JIT）跑 Fastify **服务端 bundle**——9280 那个
  `index.js` 就是这种：先校验 `.md5`，再写到 Application Support，
  在 `127.0.0.1` 上起它自己的 Fastify 服务，`CatSource` 走
  `/spider/<站点>/{init,home,category,detail,play,search}` 调它；
  站点列表从 bundle 的 `/config` 拿：设置里“展开全部站点”可以把
  一个 bundle 展开成每个站一个独立的源（v2.1.4，默认仍是单个源，
  9280 的 SOURCE_ORDER 从 douban 开始），也可以只切换单个站点。
  真正的 **websiteBundle**
  包仍走 v1 的 JavaScriptCore 有界宿主（只暴露 `Spider` /
  `net.req` / `net.json` / `proxyUrl` / `page` / `md5` / `sha256`，
  请求体上限 6 MiB）。
- **首次打开不再是空的**：已预置懂片帝（py）和 9280 猫源，首页
  会依次试每个源的 home，第一个有内容的胜出；某个源挂了不影响别的源。
- **订阅导入（五条路）**：
  1. 粘贴 URL（TVBox JSON / 猫源 `.js` / `.js.md5` / py `.py`），
     地址框下方有全宽显眼的“导入订阅”按钮；
  2. **应用内文件浏览（主路径，v2.1 新增）**：设置里直接列出应用
     Documents / imports / spiders 里的 `.json` / `.js` / `.py` /
     `.txt` 文件，点一下就导入，不走系统文件选择器——LiveContainer
     下选择器选不中文件时走这条；文件用系统“文件”App 放进 YiPlayer
     的 Documents 文件夹即可；
  3. **粘贴订阅文本**（设置里多行文本框 + 导入按钮）或**从剪贴板粘贴**
     —— 文件选择器在 LiveContainer 里用不了时走这条；
  4. 本地文件（系统选择器，次要按钮，`.json` / `.js` / `.py` / `.txt`）：
     选中的文件先**复制进 App 自己的 Documents 目录再读**
     （LiveContainer 沙盒下直接读安全域 URL 不可靠），按扩展名分流
     （`.json` → TVBox JSON、`.js` → 猫源、`.py` → py 源、`.txt` 按内容判断），
     任何一步失败都在界面上写具体原因，不再只回 "cancelled"；
  5. 多订阅合并；刷新失败保留上次可用配置；相对 URL 按订阅的最终地址解析。
  - 默认测试猫源：`https://9280.kstore.vip/cat/index.js.md5`
- **首页 / 发现 / 详情 / 搜索**：接着看（断点续播）、海报墙、
  分类按源来（py 用 pd.py 的分类、猫源用 bundle 的分类）、详情
  （海报、演员、简介、线路胶囊、选集按 50 集分组）、跨源搜索合并。
  详情页选的线路真的生效（v1 忽略了选中的线路）；每集单独解析线路。
- **播放**：AVPlayer 原样透传。HEVC / HDR10 / HLG / DV5 / DV8 不转码、
  不调色，所以不会偏色；设备播不了 HDR 时 AVPlayer 会拒播
  （CoreMedia -17223），界面会如实提示，而不是偷偷降成 SDR。
  0.5x–4x 倍速、双击 ±10 秒、左半屏亮度、长按 2 倍速、跳过片头/片尾、
  音轨/字幕选择、选集、线路切换。
- **HLS 相对路径**：本机 loopback 代理（`Runtime/HLSLoopbackProxy.swift`，
  `127.0.0.1`，NWListener）重写 `.m3u8` 分片 / KEY 的相对地址，
  和 Yingxia / MarcoMovie 的做法一样。
- **ATS 已放开**：`NSAllowsArbitraryLoads = true`（用户自备的视频源
  大量是 http，播放地址由用户订阅提供）+ `NSAllowsLocalNetworking = true`
  （本机回环的 Node 服务和 HLS 代理），Info.plist 和 project.yml 里
  各写了一份。注意：v1 里这个键明明已在 Info.plist 里，用户导入
  `http://www.y456y.com` 时仍报了 ATS 错误——最可能是用户装的那个
  IPA 是在加这个键之前构建的；v2.1 把原因记在 BUILD_NOTES.md 里，
  装 v2.1 时如果还报 ATS 错误请截图。
- **图标**：白色底 + Y 形光影胶片 + 小羊驼（和 XiPlayer 白色羊驼版
  同系列），`YiPlayer.xcassets` 已接进工程（AppIcon 15 个尺寸 +
  tvOS + TopShelf）。

## v2.1 还不能做 / 已知限制

- **MKV / AV1 等 AVPlayer 打不开的容器**：v2 没有 FFmpeg 重封装
  （Yingxia 的 mkv-playback-plan 路线），这类流会直接报错。
- py 源冷启动慢（见上）、包体大（见上）；Node.js 首次启动猫源
  bundle 也要几秒。
- 9280 bundle 的 `/config` 返回形状和 `/play` 返回形状是按
  CatPawOpen 惯例推断的，**没有对真实 bundle 验证过**——如果
  v2.1.2 装上后猫源列表是空的或播不了，大概率是这里要按真实返回改。
  猫源 `/category`、`/search`、`/detail` 现在会对没有 `list` 的返回
  直接报错并贴出原始响应（v2.1.2），不再静默空白——如果装上后看到
  这条报错，把它截图发回来，那就是下一步要修的证据。
- 下载/离线、直播、弹幕、Trakt/iCloud 同步、浅色主题、tvOS、
  多端同步、云盘/音乐/漫画/小说——都没有。
- **未签名 IPA 装不到手机上就能用。** CI 产物是未签名包，装机要
  自己签名（见下）。

## 导入订阅源

1. 打开 YiPlayer → 设置 → 订阅源。
2. 粘贴订阅地址（默认已填 9280 测试猫源），点“导入订阅”；或在
   “从本地文件导入”里点一个已放进 Documents 的 `.json` / `.js` /
   `.py` / `.txt` 文件；文件选不了时用“粘贴导入”——把订阅全文粘贴
   进文本框（或点“从剪贴板粘贴”）再导入；系统文件选择器是最后的
   备用入口。
3. 回到首页 / 发现，就能看到片库。点一部片子 → 选集 → 选线路 → 播放。
4. 导入失败时旧订阅不会被清掉，错误会显示在订阅下面。

## 在 Mac 上本地构建

需要 macOS + Xcode 16+（Linux 编不出 IPA）。首次构建先拉两个运行时：

```bash
cd YiPlayer
sh Scripts/fetch-python.sh      # BeeWare CPython 3.13 -> vendor/Python.xcframework + vendor/python-stdlib/
sh Scripts/fetch-node-mobile.sh # jo32/nodejs-mobile 26.13.0 -> vendor/NodeMobile.xcframework
python3 -m pip install --target Runtime/PythonHost/spiders/site-packages \
  --only-binary=:all: -r Runtime/PythonHost/requirements.txt
brew install xcodegen
xcodegen generate
open YiPlayer.xcodeproj   # 选 YiPlayer-iOS，真机或模拟器运行
```

`vendor/` 不提交进仓库；`xcodegen generate` 时 `vendor/` 里没有
两个 xcframework 会直接失败（这是故意的，避免悄悄编出一个
没有 py/cat 支持的包）。

## GitHub Actions 免费构建（未签名 IPA）

工作流：`.github/workflows/build-ios.yml`，手动触发（Actions → Run workflow）
或推 main 时自动触发。

```text
macos-15 → fetch-python + fetch-node-mobile（vendor/ 有缓存）
→ pip 安装纯 Python 依赖（检查无 .so）→ 同步根目录 pd.py
→ brew install xcodegen → xcodegen generate
→ xcodebuild -scheme YiPlayer-iOS -sdk iphoneos -configuration Release
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
→ 打包 YiPlayer-unsigned.ipa → artifact YiPlayer-unsigned-ipa（保留 14 天）
```

不使用任何 Secrets，不签名。

## 安装未签名 IPA

用电脑 + 免费 Apple ID 签名 7 天（cider / Sideloadly 二选一）：

```bash
cider account login
cider sign YiPlayer-unsigned.ipa --apple-id --install --refresh
```

装好后在手机“设置 → 通用 → VPN 与设备管理”信任自己的 Apple ID。
**Apple ID 密码只在 cider / Sideloadly 里自己输，永远不要发在聊天里。**

## 结构

```text
YiPlayer/
  project.yml                 XcodeGen（生成 YiPlayer.xcodeproj，无 SPM 依赖）
  App/                        YiPlayerApp / Home / Discover / Detail / Search
                              / Settings+Subscription / PlayerView / Info.plist
  YiCore/                     Subscription / Source / VideoItem / Episode
                              / PlayLine / CatSource (+JsonSource) / PySource
                              / HistoryStore
  Runtime/                    CatJSRuntime (JavaScriptCore 有界宿主)
                              HLSLoopbackProxy (127.0.0.1 m3u8 重写)
                              PythonHost/ (ApplePython.c/.h C 桥、EmbeddedPythonHost、
                                spiders/base/ 最小 base.spider、spiders/pd.py、
                                requirements.txt、site-packages/ 由 CI 安装)
                              NodeHost/ (NodeHost.swift、NodeBridge.h/.mm、
                                host.mjs / worker.mjs 自写控制协议)
  Player/                     YiPlayerView (AVPlayer + HUD + 手势)
  Scripts/                    fetch-python.sh / fetch-node-mobile.sh
  YiPlayer.xcassets           AppIcon（白底 Y 形胶片 + 小羊驼）/ tvOS / TopShelf
  .github/workflows/build-ios.yml
  BUILD_NOTES.md              所有假设与未验证项（必读）
```

## 还需要用户提供什么

- **什么都不用再提供了。** pd.py 已在仓库根目录（CI 会把它同步
  进 `Runtime/PythonHost/spiders/pd.py`，以根目录的为准）；
  `base.spider` 最小兼容包已写好；`catvodsub.txt` 里只有 9280
  那个猫源地址，以后有别的订阅地址加到这个文件里就行。
  唯一要用户做的：装好 v2.1.4 后 (1) 在设置 → 猫源站点里点
  “展开全部站点”，看 9280 是不是展开成几十个站、发现页分组对
  不对；(2) 打开豆瓣站的一部片（比如《巴黎绽放的星辰》），看
  详情页有没有线路和选集、能不能播；(3) 再试一遍 py 源和猫源
  搜索能不能用，播不了或展开不对把报错截图发回来。

## 许可证注意

tvbox-silicon 和 MarcoMovie 都是 GPL-3.0-only。本仓库目前仍是**从头写的
实现**，没有逐字复制它们的代码：`host.mjs` / `worker.mjs` 是按
CatPawOpen bundle 格式自写的控制协议实现（协议本身由 bundle
格式决定），两个下载脚本只用了 tvbox-silicon 公开脚本里的
版本号 / SHA-256 等事实数据；v2.1.1 按它们的参考实现改了做法
（Python 初始化 once + 缓存失败、配置项、Node 线程栈），但
tvbox-silicon 的 `ApplePython.c` 逐字移植不了（它用 CPython 3.14
的 PEP 741 API，BeeWare 3.13 没有这些符号），代码仍是原创实现。
**但只要之后往里面逐字抄了它们的代码，即使放在私有仓库，对外
分发 IPA 时也要按 GPL 提供对应源码并保留署名和许可证头。**
详见 BUILD_NOTES.md 末尾“移植与许可证（v2.1.1 更新）”。
