# BUILD_NOTES.md — 假设与未验证项（v2.1.4）

本文件列出构建 YiPlayer v1 + v2 + v2.1 + v2.1.1 + v2.1.2 + v2.1.3 + v2.1.4 时做的每一个假设和每一条未验证的说法。
**v2.1.4 没有在 Xcode / 真机上构建或测试过** —— 本机是 Linux VM，没有
macOS / Xcode；只做了 YAML 语法、Swift 括号平衡、Python/JS 语法、
以及文件引用完整性等静态检查（见“已验证”），外加对真实 9280 bundle
的本机 Node 24 实测（见“v2.1.4 改了什么”——bundle 真的跑起来了，
但那是 Linux 沙盒网络，不是真机）。
v1 的构建是真的（GitHub Actions run #4 成功，265 KB 未签名 IPA，
见“v1 历史”）；v2 的构建也是真的（Actions run #22 成功，23.4 MB
未签名 IPA，见“v2 构建实录”），用户已在 LiveContainer 里装了 v2.0.0，
报了 4 个问题，v2.1 就是针对这 4 个问题修的（见“v2.1 改了什么”）；
v2.1.0 也已构建成功（Actions run #37，31.3 MB IPA，见“v2.1 构建实录”），
用户装后报 Python 仍失败（新报错带上了真实原因），v2.1.1 就是针对
这个修的（见“v2.1.1 改了什么”）；v2.1.1 也已构建成功（Actions
run #48，31.3 MB IPA，v2.1.1 build 4），用户装后报
Python 初始化已过、但 `_yi_bridge` 导入失败（错误码 5），v2.1.2
就是针对这个修的（见“v2.1.2 改了什么”）。

run #48，31.3 MB IPA，v2.1.1 build 4），用户装后报
Python 初始化已过、但 `_yi_bridge` 导入失败（错误码 5），v2.1.2
就是针对这个修的（见“v2.1.2 改了什么”）；v2.1.2 也已构建成功
（Actions run #46037163191，31.3 MB IPA，v2.1.2 build 5），用户
2026-11-28 08:37 直接授权做 v2.1.3，不等 2.1.2 的测试截图——
2026-11-28 早上直接读 9280 bundle 实时代码，已确认“有分类没
内容”的两个根因不在解析，而在启动方式和 /config 形状，修法都
想好了（见“v2.1.3 改了什么”）；v2.1.3 也已构建成功
（Actions run #46089344677，31.3 MB IPA，v2.1.3 build 6），用户
2026-11-28 11:37 在 LiveContainer 里实测：bundle 真的跑起来了
（搜索能用，详情页《巴黎绽放的星辰》有海报、标题和评分 7.2），
但详情页没有线路、没有选集（/detail 返回 {}），且同一个 bundle
在 Yingxia 里是几十个源、在 YiPlayer 里只有 1 个——v2.1.4 就是
针对这两个修的（见“v2.1.4 改了什么”）。

## v2.1.4 改了什么（相对 v2.1.3）

背景：用户 2026-11-28 11:37 真机实测 v2.1.3。两个问题：
(1) 详情页《巴黎绽放的星辰》有海报、标题、评分 7.2，但没有
线路、没有选集，红字报错“解析失败：猫源 /detail 返回的结果里
没有 list：{}”。(2) 同一个 9280 猫源链接，Yingxia 解析出几十个
源（分组 chips + 逐条站点），YiPlayer 只显示 1 个源（douban）。
2026-11-28 当天重新下载 bundle 并对 .md5（仍是
d8e69da8c37a29afe50fdc8de9dbf268，和 2026-11-27 一致，文件没换
过），再用 Node 24 在本机把真实 bundle 跑起来实测（不是合成
假包），两个根因都确认了。

### 根因 A：/detail 返回 {} 是 bundle 自己的答案，不是请求写错了

证据（bundle 代码 + 本机 Node 24 实测）：

- Fastify 路由是直接绑定的：`t.detail&&o.post("/detail",
  t.detail.bind(t))`——不包装、不加字段。蜘蛛读的就是
  `body?.id`（其它蜘蛛：`Array.isArray(n.body?.id)?n.body.id:
  [n.body?.id]`），正是 host.mjs 已发的 `{id}`（host.mjs:252）；
  host.mjs 每次调用前也早调过 /init（host.mjs:245，404 容忍），
  而豆瓣蜘蛛的 init 只处理 extend/ext，本来就是空操作。所以
  **没有任何 body 字段、type 或初始化步骤能修这个 {}**。
- 豆瓣蜘蛛（工厂 `_c0`，meta `{key:"douban",name:"豆瓣|首页",
  type:3}`）的 home/分类是真的（拉 frodo.douban.com 热榜，
  条目 id 由 mc0 写成 `msearch:<豆瓣 id>`，所以海报/标题/评分
  都正常），但 detail/search/play 全是空壳：
  `async detail(){return{}},async play(){return{}},async search(){return{}}`——
  全 bundle 仅有的两处空壳三元组，另一处是工厂 `J70`，meta
  `{key:"gengxin",name:"日期:20261127",type:3}`，就是那个日期戳。
- 本机实测（Node 24，真实 bundle，端口 19098）：
  `POST /spider/douban/3/detail {"id":"msearch:123"}` → `{}`；
  `{"id":""}` → `{}`。和真机报错一字不差。
- 其它蜘蛛的 detail 是真的，例如玩偶 wogg：
  `async detail(l){...for(let g of d.filter(Boolean)){let y=await
  qWt(c.siteUrl,g,e);m.push(y)}return x0(m)}`，观影 guanying
  同款（经 ljt）。线路存在，只是**不在豆瓣名下**。

修法（`YiCore/CatSource.swift`，`detail(vodID:title:)` 聚合兜底）：

- 先照旧调自己的 /detail；只有当 bundle 有返回但没有 `list`
  （严格解析抛“没有 list”），且 id 是 `msearch:` 开头、标题
  非空时，才走兜底——别的失败（网络错、非 JSON）不走兜底，
  直接抛原错。
- 兜底：取 bundle 里除当前站外的前 8 个内容站，并行搜片名
  （TaskGroup；标题归一化：小写、去空白和标点，所以
  “巴黎绽放的星辰”能匹配带年份后缀的标题），按 /config 顺序
  取第一个标题匹配，再调那个站的 /detail 拿线路；`/play` 也走
  那个站的路由（`VideoItem.resolvedSiteAPI`，见下）。
- 每个站的搜索限 12 秒（TaskGroup 里与 sleep 竞速）：本机实测
  里一个 4K 站的上游挂了 45 秒以上才超时，不限时会把整个
  详情页拖到 Node 的 60 秒请求超时。
- 只接受**带线路**的兜底详情（`playGroups` 非空）：本机实测里
  观影的 /detail 对《哪吒》返回了完整元数据（1974 年、演员、
  导演），但 `vod_play_from` / `vod_play_url` 是空的——收下它
  等于还是空白详情页，所以继续试下一个匹配的站。
- 再失败时报错贴出：本次 /detail 的 route + body（`{id: …}`）、
  原始返回前 300 字、试过的站名；匹配到了标题但逐站调 /detail
  都没线路时，另写明最后错误。保持 v2.1.2 的严格报错风格。
- `Source` 协议新增 `detail(vodID:title:)`（带默认实现转调
  旧方法，所以 JsonSource / PySource 不用改），`DetailView`
  调它；`VideoItem` 新增 `resolvedSiteAPI`（哪个站实际给了
  详情，`/play` 就调哪个站）。

兜底的前提验证（本机 Node 24，真实 bundle）与**诚实提醒**：

- 链路本身是通的：观影 `/search {"wd":"哪吒"}` 返回真实条目
  （`vod_id: "gy:eyJ..."`，片名“哪吒”），`/detail` 返回
  `{"list":[...]}`。所以“兄弟站搜索 → 兄弟站详情”这个机制
  在 bundle 层面是成立的。
- **但《巴黎绽放的星辰》在本机沙盒里没找到**：按 /config 顺序
  的前 8 个内容站（我的网盘、玩偶、观影、多多、虎斑、木偶、
  快映、蜡笔）搜它，结果是 404 / 403 / 500 / 超时，只有观影
  正常返回空列表 `{"list":[]}`。玩偶搜《哪吒》也 403。这很可能
  是**沙盒网络的问题**（数据中心 IP 被上游拦，或上游在沙盒里
  不通），不是片子不存在——手机网络（用户在国内）下这些站
  很可能正常。但**在真机上验证之前，不要承诺兜底一定能找到
  这部片的线路**；真机上如果兜底报“搜了一圈也没找到”，报错
  里会列出试过的站，那就是下一步的证据。
- 豆瓣站展开后标记为不可搜索（`isSearchable: false`）：它的
  search 也是空壳，搜它只会稳定报“没有 list”；它在发现页
  仍可浏览（home/分类是真的）。

### 根因 B：一个 bundle 在 YiPlayer 里只有一个源

证据（本机 Node 24 实测，真实 bundle 的 GET /config）：

- video 组 **93 个站**，每条是 `{key:"nodejs_<key>",
  name:"名字|分组",type:3,searchable,api:"/spider/<key>/<type>"}`。
  前 5 条：豆瓣|首页（/spider/douban/3）、日期:20261127
  （gengxin）、配置|中心（baseset，searchable=0）、我的|网盘、
  玩偶|4K。read/comic/music/pan 四组**全是空数组**——只有
  video 有站。
- 分组就是名字里 `|` 后面的标签：93 条里 91 条带 `|`，共 **33
  个不同分组**（4K 16 个、秒播 16 个、音乐 6 个、体育 6 个、
  动漫 5 个、直播 4 个、听书/少儿/课堂各 3 个……）。不带 `|`
  的只有 gengxin（日期戳）和 push（推送）两条——本来就要排除。
- Yingxia 截图里的分组名（推荐/摸鱼/蝴蝶/牛二/搜剧）在 bundle
  全文出现 **0 次**——是 Yingxia 自己的分组，**不照抄**。
  YiPlayer 的分组只用 bundle 自带的 `|标签`（没有标签时用
  video/read/comic/music/pan 组名）。
- 排除依据（只按证据排除，不猜）：type 4 的 `push`（推送，
  是推送接口不是站）；searchable=0 的 `baseset`（配置|中心）；
  名字以“日期:”开头的 `gengxin`（日期戳，detail/search/play
  也是空壳）。93 − 3 = **90 个内容站**。

修法：

- `CatSource.expandedSources()`：/config 每条内容站变成一个
  独立的 `Source`（名字是 `|` 前的部分，分组是 `|` 后的标签，
  `spider` 就是它自己的 api 路由，如 `/spider/guanying/3`，
  `isSearchable` 沿用 /config——豆瓣除外，见上）。原有的单
  siteKey 选择器保留作兼容（未展开的单个源仍能切站），但不
  再是唯一入口。
- 设置 → 猫源站点：未展开的 bundle 订阅多一个“展开全部站点”
  按钮，展开后用 `refreshSucceeded` 把订阅的源换成展开后的
  列表（订阅本身不变），并显示“已展开为 90 个站（4K 16 个、
  秒播 16 个……）”+“重新加载站点列表”；已展开的订阅不再显示
  90 个站点选择器（原来会渲染 90 个）。
- 发现页：分组 chips（只在有分组的源时出现，“全部”+ 各分组），
  源选择器只显示当前分组的源；选中的源被分组过滤掉或被展开
  替换掉时，回落到第一个可见源，不会空白。
- 搜索页：改并行（TaskGroup）——展开后有 ~90 个可搜源，串行
  搜要几分钟；并行后总耗时约等于最慢的单个搜索；结果仍按
  /config 顺序合并，单个源报错只记该源、不当成“没结果”。
- **展开后所有站共用一个 bundle 文件和一个 Node worker**：
  host.mjs 按 bundle 文件路径起 worker（`bundles` Map 以文件
  路径为键），一站一个文件会起 ~90 个 Fastify 服务器——所以
  `startServerBundle` 的写盘目录改成按 bundle 来源 URL 的 MD5
  （`YiPlayer/cat/bundle-<md5(api)>`），所有同 bundle 的源共用
  一个文件、一个 worker、一个 profile 目录；文件内容没变时
  不重写（90 个实例不再重复写 6 MB）。同理，bundle 下载也改
  成按 URL 共享在途任务（`sharedBundleText`）：展开后第一次
  并行搜索不再把同一个 6 MB 文件下载 90 次；任务结束（成功
  或失败）就从缓存里清掉，之后再加载会重新下载——服务端
  更新的 bundle 不会被旧缓存顶掉。
- 顺带修了一个播放链上的潜 bug（读代码发现，真机还没走到播
  放所以没报出来）：`runner(for:)` 原来每次都 new 一个
  CatSource/JsonSource/PySource，而 `playLines(for:)` 依赖实例
  里的 `lastDetail`——DetailView 先在 loadDetail 的 runner 上
  拿详情，再在 play 的**新** runner 上解析线路，`lastDetail`
  永远是 nil，token 类 playid 会直接报“没有找到相关资源”。
  现在 `runner(for:)` 按 source id 缓存一个 runner（NSLock
  保护），loadDetail → play 共用一个实例。JsonSource/PySource
  同样受益（它们也是 lastDetail 模式）。

### 仍未验证（v2.1.4）

- **最关键的两项**：真机上展开后 9280 是不是 90 个站、发现页
  分组对不对；豆瓣站《巴黎绽放的星辰》的详情页兜底能不能找到
  线路并播出来（本机沙盒里前 8 站对这部片全灭，见上——手机
  网络可能不同，真机结果为准）。
- 展开后 90 个源的 Discover/Home/Search 性能与内存：设计上
  只有一个 Node worker、一次 bundle 下载，但**没有在真机上
  测过**——如果发现页卡或内存暴涨，先看是不是 90 个源同时在
  load（HomeView 依次试每个源的 home，第一个有内容的胜出；
  懂片帝排第一，通常到不了猫源）。
- 豆瓣站展开后在发现页的 home/分类是否仍正常（它的 home/分
  类是真的，但展开后它只是 90 个源之一）；`http://www.y456y.com`
  的 ATS；LiveContainer 内置文件浏览器；图标显示；冷启动时间。
- 版本：2.1.4 / build 7（三处一致：project.yml settings.base、
  target info.properties、App/Info.plist）。

## v2.1.3 改了什么（相对 v2.1.2）

背景：用户 2026-11-28 08:37 说“直接做 v2.1.3”。2026-11-28 早上
07:00–07:15 直接读了 9280 bundle 的实时代码（.md5 仍是
d8e69da8c37a29afe50fdc8de9dbf268，和 2026-11-27 记录一致，文件没
换过），确认“9280 有分类没内容”不是解析问题——v2.1.2 加的严格
解析只能把报错露出来，修不了根因。两个根因都在下面。

### 根因 A（决定性的）：9280 的包是独立服务器，不是可嵌入的 bundle

证据（静态读代码，行号是 bundle 全文的行号）：

- 入口在文件末尾约 16979–16981 行：`BTr()&&Dtt().catch(...)`；
  `BTr()` 只有以 `node index.js` 独立运行、且没有 catServerFactory
  时才自启（`process.env.CATVOD_DISABLE_AUTOSTART==="1"` 或
  `typeof globalThis.catServerFactory==="function"` 时返回 false；
  否则要求 `/(?:^|[\/])index\.js$/i.test(process.argv[1]||"")`）。
- 全文件唯一的 module.exports 是死代码
  `0&&(module.exports={start,stop});`，根本不存在 start 函数。
  v2.1.2 的 worker.mjs `require(bundle)` 后检查
  `typeof exports.start !== 'function'` 就抛
  "The script is not a CatPawOpen bundle"，host.mjs 的 start()
  随之失败——所有 Node 调用都会报错。
- Dtt 本身接受 catServerFactory，但只在 BTr() 为真时才被调用，
  而 BTr() 为真恰恰要求 catServerFactory 不存在——嵌入路径是
  bundle 自己堵死的。正确跑法是独立进程：`node index.js`，监听
  9988 端口（或 PORT/DEV_HTTP_PORT 环境变量，端口占用自动+1）。

修法（`Runtime/NodeHost/worker.mjs`，standalone 模式）：

- exports.start 不存在时，不定义 catServerFactory。实现细节：
  worker 先按老样子 require 一次（用来看 exports 里有没有
  start；此时 factory 是定义着的，BTr() 为 false，Dtt() 没跑，
  第一次加载只跑了定义）；确认没有 start 后，删 require.cache
  里的 bundle 条目、删掉 catServerFactory、清掉
  CATVOD_DISABLE_AUTOSTART、把 `process.argv[1]` 指向 bundle
  文件本身，再 require 第二次——这时 BTr() 为真，顶层的
  `BTr()&&Dtt()` 启动服务器。bundle 文件在设备上本来就叫
  index.js（`CatSource.startServerBundle` 写盘时就是这个名），
  所以 argv[1] 的正则能匹配上，不用改写盘逻辑。
- 然后等 bundle 的 GET /health 通了再把端口报给 host.mjs：
  从 `PORT || DEV_HTTP_PORT || 9988` 起、往上试 10 个端口，
  20 秒超时；任何 HTTP 应答（哪怕 404）都算“有服务器在听”，
  只有 2xx 之外的状态会在日志里留一句。启动失败时报错写明是
  standalone 模式、等了多少秒、最后一次 /health 的结果。
- standalone 模式下 worker 没有 bundle 服务器的句柄，relisten
  消息直接回一个说明性的 error，不再对 undefined 的 server
  调用 close()（原来会直接抛错）。host.mjs 的 /call 路由不用改。
- CatPawOpen 路径（exports.start 存在）一字未动：factory 仍在
  require 之前定义，start(config) 后等 server.listening。

验证（合成测试包，不是真的 9280 bundle——**真的 9280 bundle
本地没有跑起来过**，见下“仍未验证”）：

- 用 Node 24 在本机搭了一个仿 9280 契约的假包
  （`/tmp/yi213/standalone/index.js`：无 exports.start、只有死
  代码 module.exports、顶层 `BTr()&&Dtt()`、9988 端口上
  /health + 分组 /config + /spider/douban/3/* 路由），worker.mjs
  对它报 `{ready:true, port:19088}`（PORT 环境变量指定），随后
  GET /config 200，返回分组形状——standalone 模式全程走通。
- 对照实验（同个假包）：factory 定义着 require → 19089 端口
  ECONNREFUSED（自启被堵死，和 v2.1.2 的行为一致）；删掉
  factory、argv[1] 指向 index.js 再 require → /health 200。
  这证明修法改的正是堵住自启的那个点。
- 回归：仿 CatPawOpen 的假包（exports.start + catServerFactory）
  仍走老路径，`{ready:true, port:44647}`（临时端口），GET
  /config 200。`node --check worker.mjs` 通过。

### 根因 B：/config 是分组形状，v2.1.2 的解析认不出

证据：bundle 的 /config 返回
`{video:{sites:[...],danmuSearchUrl},read:{sites:[]},
comic:{sites:[]},music:{sites:[]},pan:{sites:[]},color:[...]}`。
v2.1.2 的 `CatSource.parseSites` 只认顶层 sites/list/sources/data，
认不到就走“字典 key 当站点”的兜底，把 video/read/comic/music/pan
当成站，siteKey 默认取第一个 "video"，调 /spider/video 会 404。

修法（`YiCore/CatSource.swift`）：

- parseSites 按顺序试三种形状：(1) 顶层 sites/list/sources/data
  数组（旧形状，照旧）；(2) 分组形状——取每个分组的 `sites`
  数组，按 video、read、comic、music、pan 的固定优先顺序
  （JSONSerialization 不保字典序，所以不能依赖返回顺序）；
  (3) 字典 key 当站点（兜底）。关键：**一旦认出是分组形状
  （任一分组是带 "sites" 的字典），哪怕所有分组都是空数组，
  也不走 (3)**——否则空分组又会变回 video/read 这种假站点；
  这种情况下 startServerBundle 直接抛错，贴出 /config 原始
  响应的前 300 字（沿用 v2.1.2 的严格解析做法）。
- 每条目的 key：优先用它的 `api` 字段（形如 "/spider/douban/3"）
  当完整路由——因为 /config 里的 key 是 `nodejs_<key>`
  （如 nodejs_douban），不能直接拼 /spider/ 后面；api 没斜杠
  开头的按 "spider/..." 或裸路径分别补齐；没有 api 时用
  key/id，并去掉 "nodejs_" 前缀；key 按首次出现去重。
- `catPawOpen` 改为：siteKey 以 "/" 开头就原样用，否则拼成
  "/spider/<siteKey>"——旧的纯 key（如 "douban"）和新的完整
  api 路径都能走通；host.mjs 的 `/^\/spider\/[^?#]+$/` 校验
  本来就允许 "/spider/douban/3" 这种带两段的路径，不用改。
- siteKey 的 getter 加了迁移保护：已存的值不在当前站点列表
  里时（比如 v2.1.2 存下的 bogus "video"），回落到第一个
  站点，而不是继续调不存在的路由。
- /config 有返回但解析不到任何可用站点时，startServerBundle
  现在抛错（贴原始响应前 300 字）；/config 根本没拿到
  （node.config 抛错）时仍保留 douban 兜底。

验证：把 parseSites 的算法原样抄成 JS，在本机跑了 7 组输入——
分组 9280 形状 → /spider/douban/3、/spider/360/1；旧顶层
sites、字典 key 形状照旧；空分组 → []（不再出假站点）；
api 没斜杠、key 带 nodejs_ 前缀、重复 key 都按预期处理。
**这验证的是算法，不是 Swift 代码本身**——Swift 只能静态
检查（括号平衡、类型一致），真机上以 /config 的实际返回为准。

### 仍未验证（v2.1.3）

- **最关键的两项**：真的 9280 bundle 在真机上能不能跑起来
  （standalone 模式 + /health）、/config 解析后能不能拿到
  douban 等站、分类/搜索/详情/播放能不能通。本地只验证了
  合成测试包，真的 bundle 没有跑起来过（浏览器没能把
  index.js 存成文件；站点首页还返回 502；只存下一个 5.0 MB
  的页面 PDF，里面的 JS 文本是换行打断的，无法还原成可运行
  文件、MD5 也对不上）。
- douban 等上游站在用户手机网络下通不通；`http://www.y456y.com`
  的 ATS；LiveContainer 内置文件浏览器；图标显示；冷启动时间。
- 一个诚实提醒：v2.1.1 测试里看到的分类“电影/连续剧/综艺纪录/
  动漫/短剧”和 CatSource.swift 里写死的 v1 兜底列表一字不差，
  很可能根本不是 bundle 的 /home 返回的——不要把那次的分类
  当成 bundle 真实输出的证据。v2.1.3 的测试可以一锤定音：
  如果 Discover 出现 "The script is not a CatPawOpen bundle"
  之类的 Node 错误，说明 standalone 模式没生效；如果出现
  /config 或 /spider/... 的 404，把报错原文发回。

## v2.1.2 改了什么（相对 v2.1.1）

用户在 LiveContainer 里装了 v2.1.1 后报（2026-11-28 00:10–00:12）：

- 发现页 懂片帝：“解析失败：Python 运行时初始化失败（错误码 5）：
  cannot import _yi_bridge (is spidersDir .../Documents/Applications/
  com.yiplayer.app.app/spiders on sys.path?)”——"failed to read thread
  state" **消失了**（v2.1.1 的 once 守卫 + 串行化起了作用，
  `Py_InitializeFromConfig` 已成功）；失败点移到下一步的
  `PyImport_ImportModule("_yi_bridge")`。
- 发现页 9280 猫源：分类能出来（电影/连续剧/综艺纪录/动漫/短剧），
  但没有任何内容条目；底部挂着同一条 Python 错误 5（切换 tab 时
  旧的 errorMessage 要等新一轮 load 完成才清掉，截图时可能还在，
  不是猫源调用走了 Python——见下“只读代码核查”）。
- 搜索“奥德赛”：空，无报错。首页：转圈后空。设置页新 UI 正常，
  三个订阅都在。

### 根因：`PyConfig.module_search_paths` 在初始化中途被重算丢弃了

证据是本机用真实 CPython 3.12、与 `ApplePython.c` 相同的配置形状
做的对照实验（`/tmp/pyexp/pyconfig_test*.c`，2026-11-28，`gcc …
$(python3-config --includes --ldflags --embed)` 编译运行；文件只
import `importlib.util` / `json` / `os` / `sys` / `threading` 的
`_yi_bridge.py` 复制件放在 `/tmp/pyexp/spiders/`）：

| 变体 | 配置 | 初始化后 sys.path | spiders 在吗 | import _yi_bridge |
|---|---|---|---|---|
| A | 假 home + `Py_PreInitialize` | 仅 home 派生的默认项 | 否 | 失败 |
| B | 假 home，不预初始化 | 同上 | 否 | 失败 |
| C | 真 home（/usr），不预初始化 | 3 项：`python312.zip`、`lib/python3.12`、`lib-dynload` | 否 | 失败（`ModuleNotFoundError: No module named '_yi_bridge'`——与真机错误 5 同款） |
| E | **不设 home** | 同 C 的 3 项 | 否 | 失败 |
| **D** | 同 C，**初始化成功后**显式把 5 个目录插进 sys.path | 7 项，顺序为 dynload、docspiders、spiders、site-packages、3 项默认 | **是** | **成功，`call_spider` 存在** |

五个变体里 `add_path`（`PyWideStringList_Append`）的返回值都检查过、
没有失败——`module_search_paths` 确实填进去了，但初始化后
`sys.path` 里一个都不剩。机制（读 CPython 3.12 源码）：
`Py_InitializeFromConfig` → `pyinit_core` → `_PyConfig_Read(&config, 0)`
（此时不算路径配置，注释原话 "don't compute the path configuration
(it is computed in the main init)"）→ `pyinit_main` →
`init_interp_main` → `_PyConfig_InitImportConfig` →
`config_init_import(config, 1)` → `_PyConfig_InitPathConfig(config, 1)`
跑冻结的 `getpath.py`，按 home/prefix/stdlib_dir 重算
`module_search_paths`，手填的条目被丢弃。变体 E 证明**去掉
`config.home` 也救不了**（重算与 home 无关）；只有变体 D 的
“初始化成功后显式插入”管用。注意：getpath.py 本体这次没能读到
（raw.githubusercontent.com 上 `Lib/getpath.py` 与
`Python/getpath.py` 都返回 404），所以上面只写到
`_PyConfig_InitPathConfig` 这一层，不编造 getpath.py 内部某一行
的说法——行为本身已被 5 组实验钉死，修法不依赖那一行。

改动（`Runtime/PythonHost/ApplePython.c/.h`）：
- 初始化成功后、导入 `_yi_bridge` 之前，在 GIL 内把 5 个目录显式插
  进 `sys.path`（新函数 `ensureSysPathEntry`：`PySys_GetObject("path")`
  + `PyList_Insert` 到位置 0，已在的条目跳过不重复插；按反优先级
  顺序插入，最终顺序与配置意图一致：stdlib、dynload、用户 spiders、
  打包 spiders、site-packages）。插入失败是新错误码 **6**
  （`cannot put <dir> on sys.path after init`）。配置里
  `module_search_paths` 的 append 保留，只作为意图说明，不再被依赖。
- 导入前加 `_yi_bridge.py` 存在性检查（与已有的 `os.py` 检查并排，
  同一个“初始化前 fail-fast、报错写明精确路径”的做法；缺失时错误码 1，
  报错写明完整路径，不再走到导入那步才猜）。
- 导入再失败时不再只 `PyErr_Print()` 到 stderr（真机上看不见）加一句
  猜测：新函数 `capturePythonError` 用 `PyErr_Fetch` +
  `PyErr_NormalizeException` 取出异常，再用 `traceback` 模块的
  `format_exception(exc)`（单参数形式，3.10+ 现行 API）拼出完整
  traceback，并把导入那一刻的 `sys.path` 逐项写进错误（上限 24 项）；
  文本进 `YiPythonLastError()`（缓冲区从 2048 扩到 8192 字节），
  界面下次报的就是真正的原因。`traceback` 模块本身出问题时仍有
  “类型 + 消息”兜底，不会丢了主错误。
- Swift 侧（`YiCore/PySource.swift`）不用改：它已经原样透传
  `YiPythonLastError()` 的文本，错误码 5/6 都会带上真实原因。

### 顺带：猫源“有分类没内容、搜索没结果、界面一声不吭”

只读代码核查（`YiCore/CatSource.swift`、`App/DiscoverView.swift`、
`App/SearchView.swift`、`App/HomeView.swift`、
`Runtime/NodeHost/host.mjs`、`Runtime/NodeHost/worker.mjs`）：

- 路由本身是对的：`host.mjs` 按参数分发——有 `play` → `/play`，
  `ids` → `/detail`，`wd` → `/search`，`t` → `/category`（body
  `{id, page, filter: true, filters: {}}`），无参数 → `/home`；
  `CatSource` 的 category / search / detail / home 传参分别对上这
  四条。分类能出来证明 `/home` 通了且返回了 `class`。
- 真正的问题在 `CatSource.items(from:)`：任何没有 `list` 的返回
  （JSON 形状不对、错误对象、HTML、空串）都静默返回 `[]`，
  `category()` 再以“成功、0 条”交回去，`DiscoverView` 只显示
  “这个分类没有内容”，`errorMessage` 被置空；搜索同理（`host.mjs`
  还会把空搜索正文与 404 都归一成 `{"list":[]}`）。Node 的真实
  响应从来没到过界面——这就是“有分类没内容、搜不到、也不报错”
  的全部解释，不用再猜是哪个接口调错了。
- 改动（只改读代码能确认的这一处）：`CatSource` 新增严格解析
  `items(from:route:)`，供 `/category`、`/search`、`/detail` 用——
  返回里**有** `list`（哪怕是空数组）仍是正常空结果，不报错；
  返回里**没有** `list`、或根本不是 JSON，就抛
  `SourceError.parse`，把路由名和原始响应前 300 字写进错误。
  `home()` 故意保留宽容解析：`/home` 合法时可以只有 `class`
  没有 `list`，且 `HomeView` 本来就会依次试下一个源，空首页
  的提示本身是诚实的。
- 需要真机数据才能确认的（不要猜修法）：9280 bundle 的
  `/category` 与 `/search` 实际返回什么（字段名、是否要求别的
  body 字段、是否对 douban 站点根本没实现搜索）。本机这次没能
  重新读到 bundle 全文（`https://9280.kstore.vip/cat/index.js`
  抓取超时），所以没有改请求字段；v2.1.2 的严格报错就是为了
  下次测试时把原始响应带回来，再按真实形状修。

### 只读代码核查的其它结论

- `App/HomeView.swift` 的 `loadHome()` 确实会 try 每一个源、失败就
  `continue` 试下一个——首页空是因为两个源都真的失败/无内容，
  不是第一个源失败就停了（v2.1.0 时已核查过一次，结论不变）。
- 发现页切 tab 后旧报错短暂残留：`DiscoverView.load()` 是异步的，
  新一轮 load 完成前旧的 `errorMessage` 还在界面上——截图里 9280
  tab 下挂着 Python 错误 5 就是这么来的，不是猫源走了 Python。
  这只是显示时序问题，这次没改（改动面控制在诊断与修法上）。

### 版本与仍未验证

- 版本：2.1.2 / build 5（project.yml 三处与 Info.plist 同步：
  settings.base 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION、
  target info.properties 的 CFBundleShortVersionString /
  CFBundleVersion、App/Info.plist——v2.1.1 run #47 的教训）。
- **仍未验证（等 Actions 构建 + 真机测试）**：
  ① `_yi_bridge` 在真机上是否真的导入成功（错误 5 是否消失）、
  pd.py 是否返回内容/能播——这是本次最关键的验证项；
  ② 9280 的 `/category` 与 `/search` 实际返回形状（等 v2.1.2
  的严格报错把原始响应带回来）；
  ③ `sys.path` 插入在 BeeWare 3.13（本机实验是系统 Python 3.12）
  上是否同样生效——配置形状与初始化路径相同，但 3.13 的 getpath
  未在本机复核，如果真机仍报导入失败，`YiPythonLastError` 里的
  sys.path dump 会直接说明插入是否生效；
  ④ 其余 v2.1 / v2.1.1 的未验证项（ATS、LiveContainer 文件浏览、
  图标显示、冷启动时间）不变，见下。

## v2.1.1 改了什么（相对 v2.1）

用户在 LiveContainer 里装了 v2.1.0 后，懂片帝仍失败，但报错第一次带上了
真实原因（v2.1 的诊断改进在起作用）：

> 解析失败：Python 运行时初始化失败（错误码 4）：
> Py_InitializeFromConfig failed (stdlib /private/var/mobile/Containers/Data/
> Application/132103A4-.../Documents/Applications/com.yiplayer.app.app/
> python-stdlib/python3.13): failed to read thread state

首页仍是空的（两个源都出不来内容），设置页新 UI 正常出现，证明装的
确实是 v2.1。

- **根因：初始化被重复调用了——而且是从不同线程。**
  证据分三层，全部是读到的源码，不是猜的：
  1. CPython 3.13 源码 `Python/pylifecycle.c`（v3.13.0，2026-11-27
     下载核对）：`pyinit_core`（第 1068 行）按 `runtime->core_initialized`
     分支——第一次走 `pyinit_config`（第 917 行），它在
     `pycore_init_runtime` + `pycore_create_interpreter` +
     `pycore_interp_init` 全部成功后才把 `core_initialized` 置 1；
     第二次调用走 `pyinit_core_reconfigure`（第 467 行），第一步就是
     `_PyThreadState_GET()`，当前线程没有绑定的 thread state 就返回
     `_PyStatus_ERR("failed to read thread state")`（第 475 行）。文件
     头注释还写明：调用这些 API 时必须持有解释器锁，“you cannot use
     multiple threads”。
  2. v2.1.0 的 `YiCore/PySource.swift` 里 `call()` 先在 Swift 并发
     执行器线程上调 `ensureInitialized()`，再把蜘蛛调用 dispatch 到
     串行队列——初始化根本不在串行队列上，且 `initialized` 只是一个
     无锁的 Bool。首页、发现、搜索并发触发时，两个任务能同时进入
     `Py_InitializeFromConfig`：先到的把 `core_initialized` 置 1，
     后到的（或任何一次重试）走重配置分支，在另一个线程上
     `_PyThreadState_GET()` 为 NULL，于是报 "failed to read thread
     state"。第一次失败的真正原因就此被盖住，再也看不见。
  3. 参考实现佐证：tvbox-silicon 的 `ApplePython.c` 用
     `dispatch_once_f(&started, ...)` 保证初始化一生只跑一次，失败
     原因记进静态 `failure` 字符串，之后每次请求都直接返回它；
     `EmbeddedPythonHost` 是 Swift actor，所有请求走
     `SerializedPluginWorker`。MarcoMovie 的
     `docs/native-python-source-profile.md`（2026-11-27 读到上游
     原文）也写明失败策略是“retires a failed source”（失败的源直接
     退役，不重试），且 iOS 加载器用“independent native threads and
     own-GIL interpreters, bounded queues”。
  改动：
  - `YiCore/PySource.swift`：`call()` 改成在串行队列里先初始化
    （`withCheckedThrowingContinuation` + `queue.async`，初始化与
    每次蜘蛛调用都在同一队列上串行）；`ensureInitialized()` 只在
    队列上跑，失败记进 `initFailure`，之后直接抛缓存的错误，不再
    调 C 桥。`initialized` / `initFailure` 只在队列上读写，不再有
    数据竞争。
  - `Runtime/PythonHost/ApplePython.c`：`YiPythonInitialize` 包一层
    once 守卫（`g_initAttempted` / `g_initResult`，第一次尝试的结果
    被缓存，之后直接返回，不再进 `Py_InitializeFromConfig`）；配置
    上按 tvbox-silicon `configure()` 补了 `config.executable`（用
    `_NSGetExecutablePath` 取应用可执行文件路径）、`utf8_mode = 1`、
    `write_bytecode = 0`、`install_signal_handlers = 0`，以及
    `signal(SIGPIPE, SIG_IGN)` / `signal(SIGXFSZ, SIG_IGN)`（写关闭
    的 socket 只会让蜘蛛收到 BrokenPipeError，不会杀掉整个 app）。
    注意：tvbox-silicon 的 C 桥用的是 CPython 3.14 的 PEP 741
    `PyInitConfig` API（不透明配置，运行时 dlsym），BeeWare 3.13
    根本不导出这些符号，所以它的 `ApplePython.c` **无法逐字移植**，
    这里移植的是做法（once 启动、缓存失败、配置项、信号处理），
    不是逐字复制。`EmbeddedPythonHost.swift` 同理无法逐字移植
    （它引用 Yingxia 自家的 Site / TVError / SerializedPluginWorker
    等类型）。
  - `Runtime/NodeHost/NodeBridge.mm`：Node 启动线程显式设 2 MB 栈
    （`pthread_attr_setstacksize(2 << 20)`），移植自 tvbox-silicon
    `EmbeddedNodeHost.launch` 的 `thread.stackSize = 2 << 20`。
    之前 `pthread_create` 用默认属性，iOS 上副线程默认栈只有
    512 KB，低于 V8 的栈需求。
  - `Runtime/NodeHost/NodeHost.swift`：`isAvailable` 除检查
    `host.mjs` / `worker.mjs` 外，也检查 `NodeMobile.framework` 二
    进制是否存在（与 tvbox-silicon `EmbeddedNodeHost.available`
    一致）；`ensureStarted()` 里 `startTask` 的检查与设置改成在
    `NSLock` 下原子完成，两个并发猫源调用不会启动两次 Node。
  - **核查（只读代码，未改逻辑）**：`App/HomeView.swift` 的
    `loadHome()` 确实会 try 每一个源、失败就 `continue` 试下一个，
    首页空是因为两个源都真的失败/无内容，不是第一个源失败就停了
    （v2.1.0 截图里首页无红字，是因为截图时还在加载中，
    `isLoading` 为真时空状态不渲染）；`NodeHost.isAvailable`
    在 v2.1 改成包根目录后是正确的（与 IPA 清单一致）。
  - 版本：2.1.1 / build 4（project.yml 与 Info.plist 同步）。
  - **仍未验证**：第一次初始化失败的真正原因（v2.1.1 只保证如果
    再次失败，报错会是第一次的真实原因，而不是 "failed to read
    thread state"）；初始化是否真的在串行队列上只跑一次；9280 猫
    源在 v2.1.0 上为什么也没出内容（用户截图里没有 Node 报错，
    需要真机上再看）。

## v2.1 改了什么（相对 v2）

用户在 LiveContainer 里装了 v2.0.0 后报了 4 个问题，v2.1 逐个修：

- **根因 A：Python 初始化失败（错误码 4）——标准库根本没进包。**
  证据（实测 BeeWare 3.13-b18 的 `Python-3.13-iOS-support.b18.tar.gz`，
  本机解包验证）：标准库在 xcframework **根目录**的 `lib/python3.13`
  （2,512 个文件，`os.py`、`encodings/__init__.py` 都在那）；设备扩展
  模块在 `ios-arm64/lib-arm64/python3.13/lib-dynload/`（207 个 `.so`，
  含 `_socket`、`_ssl`、`_hashlib`）；`Python.framework/` 里**只有**
  二进制 + 头文件 + Info.plist。`PyConfig` 有 `stdlib_dir` 字段
  （`cpython/initconfig.h` 第 198 行）和 `platlibdir`（第 193 行）。
  旧路径（v2.0.0 错的） vs 新路径（v2.1）：
  | | 旧（v2.0.0） | 新（v2.1） |
  |---|---|---|
  | 标准库 | `<Python.framework>/lib/python3.13`（不存在） | 包内 `python-stdlib/python3.13` |
  | 扩展模块 | 未加入搜索路径 | `python-stdlib/python3.13/lib-dynload` |
  | 打包方式 | 只拷 `.framework`（Xcode 行为） | `Scripts/fetch-python.sh` 把 `lib/python3.13` + 设备切片 `lib-dynload/*.so` 拷到 `vendor/python-stdlib/`，project.yml 以 folder reference 打进包 |
  改动：`Scripts/fetch-python.sh` 重写（下载后分阶段打包标准库，剪掉
  `test` / `idlelib` / `tkinter` / `turtledemo` / `ensurepip` /
  `lib2to3`——与 Yingxia 的 python-runtime-plan 剪裁清单一致；缺
  `os.py` / `encodings` / `_socket` / `_ssl` 就大声失败；本机已用预置
  tarball 测过全新下载与缓存命中两条路，均分阶段 615 个文件 / 28 MB）；
  `project.yml` 加 `- path: vendor/python-stdlib` folder reference
  （CI 缓存键含 `Scripts/fetch-python.sh`，改脚本即失效缓存、下次重下）；
  `Runtime/PythonHost/ApplePython.h/.c` 重写初始化（新 6 参签名，
  显式设 `config.stdlib_dir`，`dynloadDir` 加进 `module_search_paths`，
  失败时把 PyStatus 的 `err_msg` 和试过的路径记进 `YiPythonLastError()`）；
  `YiCore/PySource.swift` 传新参数，初始化前先校验包内 `os.py` 是否存在，
  失败信息里带上具体原因，不再只剩“错误码 4”。
  参考来源：Yingxia `Docs/python-runtime-plan.md`（全文读过，2026-11-27；
  它把每个扩展模块转成独立 `.fwork` 框架——BeeWare 包里实际没有 `.fwork`
  文件，`.so` 直接放在 lib-dynload 里，YiPlayer 先用原样 `.so`，只在真机
  证明 `.so` 加载失败时才考虑 Yingxia 的重打包做法）。

- **根因 B：Node“未包含”——代码找错了目录。**
  证据：v2.0.0 的 IPA 清单证实 `host.mjs` 与 `worker.mjs` 在包根目录
  （`Payload/YiPlayer.app/host.mjs`），但 `NodeHost.swift` 的
  `nodeHostDirURL` 去找 `Bundle.main.resourceURL/nodehost/` 子目录，
  该目录不存在，所以 `isAvailable` 恒为 false。
  改动：`nodeHostDirURL` 改成包根目录（`Bundle.main.resourceURL`）。
  `host.mjs` 用 `new URL('./worker.mjs', import.meta.url)` 加载 worker，
  是相对自身位置的相对引用——两个文件都在包根，引用不断。
  启动失败时错误里带上实际查过的目录、入口与控制文件路径。
  参考来源：tvbox-silicon `Runtime/NodeHost/` 目录清单（只有
  `agents.mjs` / `main.mjs` / `worker.mjs` 三个文件，2026-11-27 读过）。

- **首页红色 "cancelled"（C）**：v2.0.0 只 catch 了 `CancellationError`，
  但被取消的 URLSession 任务抛的是 `URLError(.cancelled)`，
  `localizedDescription` 就是裸的英文 "cancelled"，落进 `lastError`
  显示出来。改动：`YiCore/Source.swift` 加共享 helper
  `isCancellation(_:)`（CancellationError / URLError .cancelled /
  NSUserCancelledError / 文本本身就是 "cancelled"）与
  `displayableErrorMessage(_:)`（取消返回 nil，含 "cancelled" 的文案
  也返回 nil）；Home / Discover / Search / Detail 全部走这两个 helper；
  首页空状态的“导入订阅源”原来是点了没反应的样式文字，现在是真按钮，
  点了跳到设置页（`YiPlayerApp.ContentView` 监听
  `.yiplayerShowSettings` 通知切 tab）。

- **设置页重做（D）**：订阅地址框下方放全宽显眼的“导入订阅”主按钮
  （地址为空禁用，导入中转圈）；“已导入的订阅”单独成区；新增**应用内
  文件浏览（主路径）**：列出 Documents / imports / spiders 里的
  `.json` / `.js` / `.py` / `.txt`（含 `.md5`），按修改时间倒序，点一下
  就导入，左滑删除，带刷新按钮，底部小字说明文件放法；系统文件选择器
  保留为次要按钮；粘贴导入、猫源站点选择、播放说明、本机数据保留；
  “关于”更新到 v2.1.0。导入逻辑抽成共享的 `importParsedFile(at:fileName:)`
  （应用内浏览与选择器复制后共用）。

- **诊断能力（E）**：Python 初始化失败时错误里带 PyStatus 的 `err_msg`
  和试过的路径；Node 启动失败/超时时带实际查过的目录、入口与控制文件路径。

- **版本（F）**：2.1.0 / build 3（project.yml 与 Info.plist 同步）。

- **参考代码阅读（用户要求）**：2026-11-27 读了用户 GitHub 上两个 fork
  的相关部分——tvbox-silicon 的 `Docs/python-runtime-plan.md` 全文与
  `Runtime/NodeHost/` 目录清单；`dongxipaopao/marcotv` 是 Android
  TV 启动器（不是播放器），没有可借鉴的播放器/源代码；上游
  MarcoMovie 的 `docs/native-python-source-profile.md` 在 v2.1 时抓取
  返回 HTTP 503 未读到，v2.1.1 时通过 raw.githubusercontent.com 读到
  了全文（见“v2.1.1 改了什么”）。
  **许可证**：两个项目都是 GPL-3.0。v2.1 只借鉴设计与做法（标准库分
  阶段打包、Node 控制协议、设置分区思路），YiPlayer 的代码是原创实现，
  没有整段复制它们的代码；如果之后往 YiPlayer 里抄了它们的代码，
  对外分发 IPA 时要按 GPL 提供对应源码并保留署名。

- **v2.1 仍未验证（等 Actions 构建 + 真机测试）**：`vendor/python-stdlib`
  文件夹引用是否原样打进包（`spiders/` 文件夹引用在 v2 已验证可行，
  同一机制）；包内 `.so` 在真机上是否加载成功（若失败，改走 Yingxia
  的 `.fwork` 框架化路线）；9280 bundle 的 `/config` / `/play` 返回
  形状仍是按 CatPawOpen 惯例推断；py 冷启动时间与包体；ATS 对
  `http://www.y456y.com` 在 v2.1 是否真的放行（v2.0.0 测试时用户未再
  报 ATS 错误，但也没有明确确认放行）；LiveContainer 下应用内文件
  浏览是否好用。

- **v2.1 构建实录**：run #36（workflow_dispatch，head d07afd5）
  在 `Fetch Python-Apple-support` 一步失败：`curl
  https://api.github.com/repos/beeware/Python-Apple-support/releases`
  返回 403（curl exit 56）——共享 Actions 跑者的未认证 API
  限额（60 次/小时/IP）被耗尽；v2.0.0 时缓存命中所以没触发。
  修复：`Scripts/fetch-python.sh` 在有 `GITHUB_TOKEN`（Actions
  每轮自带）时用 `Authorization: Bearer` 调 API；写成 if/else 而
  不是空数组（该脚本跑在 bash 3.2 下，`set -u` 时空数组展开会
  报错）。已推送，待下一次构建验证。
- **run #37（run 46012889503，push，head 7c4e7c7）成功**：
  YiPlayer-unsigned-ipa 30,854,790 字节（artifact），IPA
  31,357,817 字节，sha256
  `f1e76c8ddd6a27080bcbd5cca6923127efebbde38b351bb16f5a1d32d96a5228`，
  v2.1.0 build 3，iPhone+iPad。IPA 内已验证：`python-stdlib/
  python3.13/os.py` 与 `lib-dynload/_socket.cpython-313-iphoneos.so`
  都在包内（根因 A 已修）；`host.mjs`/`worker.mjs` 在包根目录
  （根因 B 已修）；Frameworks/NodeMobile.framework 与
  Python.framework 都在。已归档进 YiPlayer_ipa。
- **run #38（workflow_dispatch，head e5c0858）又在同一步失败，
  同样 403**：原因不是脚本——`GITHUB_TOKEN` 默认不会自动进入
  shell 步骤的环境变量，脚本里的 `${GITHUB_TOKEN:-}` 始终为空，
  所以还是未认证调用；#37 只是恰好分到了有限额的跑者 IP。
  真正的修复是 workflow 里给 Fetch Python 一步加
  `env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`（已改，未验证，
  下一次构建见分晓）。

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

- **v2.1 Xcode 构建（待跑）**：v2 的构建已在 Actions run #22 成功
  （见“v2 构建实录”），v2.1 的构建还没有跑。v2.1 新增的风险点按顺序：
  ① `vendor/python-stdlib/` 文件夹引用是否原样打进包（与 v2 已验证的
  `spiders/` 文件夹引用同一机制）；② `ApplePython.c` 的新 6 参签名
  与 `YiPythonLastError()` 是否与 Swift 侧一致；③ `Scripts/fetch-python.sh`
  重写后的分阶段步骤在 CI 上是否跑通（缓存键含该脚本，改动即失效缓存）；
  ④ 其余 v2 已验证的风险点（xcframework 下载、NodeBridge.mm、
  `.mm` / `.c` 编进 target、host.mjs / worker.mjs 进 Resources）不再重复。
- **BeeWare stdlib 路径（v2.1 已解决，见上）**：v2.0.0 的假设
  `<Python.framework>/lib/python3.13` 是错的，实测 BeeWare 3.13-b18
  的包里根本没有这条路径。v2.1 改走包内 `python-stdlib/python3.13`，
  初始化前校验 `os.py` 是否存在，失败时报错里写明试过的路径。
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

## v2 构建实录（2026-11-27，Actions 上已验证）

- #17（run 46005851164）Build 失败 exit 65，两个 Swift 错误：
  NodeHost.swift 里 `guard let control` 在 catch 块重复绑定（前面
  的 guard 已解包，`control` 不再是 Optional）→ 改成
  `guard let fresh = self.control`；SettingsView.swift 的
  `UTType.javascript` 不存在 → 改成
  `UTType(filenameExtension: "js") ?? .sourceCode`。
- #19（run 46007783251）Build 失败：`fatal error: 'node/node.h'
  file not found`。实测下载 nodejs-mobile-v26.13.0-apple.zip
  验证：xcframework 里只有 `NodeMobile.h`（声明
  `int node_start(int argc, char *argv[])`），根本没有 node/
  头文件。NodeBridge.mm 改用 `node_start`，不再 include
  `<node/node.h>`、不再调用 `node::Start`；project.yml 删掉
  HEADER_SEARCH_PATHS（框架头经 FRAMEWORK_SEARCH_PATHS 解析）。
- #22（run 46008258962）成功：YiPlayer-unsigned-ipa 23,082,294
  字节，IPA 23,416,561 字节，sha256
  `91be87c4…553fda0`，v2.0.0 build 2。IPA 内已验证含有
  Frameworks/NodeMobile.framework（66.5 MB）、
  Frameworks/Python.framework、host.mjs、worker.mjs、
  spiders/pd.py + _yi_bridge.py + requests。
- 仍未验证（等真机测试）：9280 bundle 在无 JIT Node 26 下
  能否启动 Fastify 并返回 /config / /play；pd.py 首次冷启动
  时间和包体；ATS 对 http://www.y456y.com 是否真的放行；
  LiveContainer 文件导入修复；图标显示。
- 补充：用户后来给了 classic PAT（custom.github-pat），接口
  403 的限制解除——workflow 文件、日志下载、二进制上传都
  可以直接走 API，不用再经网页上传。

## 移植与许可证（v2.1.1 更新）

用户在 v2.1.1 明确要求：那两个参考都在他 GitHub 库里，可以直接移植
相关代码来实现功能，不用再坚持“只借鉴设计、自己重写”。实际执行情况：

- **读过的参考文件**（2026-11-27，均为只读，未执行其中任何脚本）：
  - `dongxipaopao/tvbox-silicon`（fork）：`Runtime/AppleRuntime/Native/ApplePython.c`
    （全文）、`Sources/TVCore/EmbeddedPythonHost.swift`（全文）、
    `Sources/TVCore/EmbeddedNodeHost.swift`（全文）、
    `Docs/python-runtime-plan.md`（全文）、`Runtime/NodeHost/main.mjs` /
    `worker.mjs`（v2 时核对过控制协议）。
  - 上游 `Pilipala9919/MarcoMovie`：`docs/native-python-source-profile.md`
    （全文，v2.1.1 读到）。`dongxipaopao/marcotv` 这个 fork 本身是
    Android TV 启动器，没有播放器代码；播放器在上游 MarcoMovie 的
    `tvos/`、`shared/catpaw/`、`flutter/` 里。
- **移植了的做法**（改动处只改必须适配 YiPlayer 的部分，来源写在代码
  注释里）：Python 初始化 exactly-once + 缓存失败（对应 tvbox-silicon
  的 `dispatch_once_f` + `failure` 字符串）、`config.executable` /
  `utf8_mode` / `write_bytecode` / `install_signal_handlers` /
  SIGPIPE 与 SIGXFSZ 忽略（对应其 `configure()`）、Node 线程 2 MB 栈
  （对应 `EmbeddedNodeHost.launch` 的 `thread.stackSize = 2 << 20`）、
  `isAvailable` 同时检查框架二进制（对应其 `available`）。
- **没有逐字复制的**：tvbox-silicon 的 `ApplePython.c` 逐字移植不了——
  它用 CPython 3.14 的 PEP 741 `PyInitConfig` API（运行时 dlsym），
  BeeWare 3.13 不导出这些符号，逐字复制连链接都过不了；
  `EmbeddedPythonHost.swift` 也逐字移植不了（它引用 Yingxia 自家的
  Site / TVError / SerializedPluginWorker / PluginDownloads 等类型）。
  YiPlayer 这两个文件的代码仍是原创实现，只是按参考实现的做法改的。
  MarcoMovie 的播放器 / 界面代码 v2.1.1 没有移植：当前卡住的是运行
  时层（源不出内容），不是播放器，播放器只有在源返回内容后才能验证，
  现在移植属于无验证目标的重写。
- **许可证后果（如实记录）**：tvbox-silicon 与 MarcoMovie 都是
  GPL-3.0-only。v2.1.1 没有往 YiPlayer 里逐字复制它们的文件，所以
  YiPlayer 目前仍按原创实现对待；但只要之后有任何逐字移植（哪怕
  只有一处），YiPlayer 就要按 GPL 对待——保留原始文件的许可证头与
  作者署名；如果之后把 IPA 对外分发，对应源码也要提供（即使仓库是
  私有的）。这一点同样写在 README.md 的“许可证注意”里。
