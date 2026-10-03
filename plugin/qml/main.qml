import QtQuick 2.12
import QtQuick.LocalStorage 2.0
import "."
import "pages" as Pages
import "components" as Components

Item {
    id: root
    width: 320
    height: 170

    // ================= 框架约定 =================
    // PenMods 的 YDynamicPageStack.registerPage() 会检测插件根对象是否带 backButtonClicked 信号：
    //   if (incubatorObject.hasOwnProperty("backButtonClicked"))
    //       incubatorObject.backButtonClicked.connect(() => root._safeDestroy(incubatorObject))
    // 即「发这个信号 = 请求关闭本插件页」。weather / lx-pen / 笔里哔哩 三个在跑插件都遵守了这条约定。
    // （另一条退出路径是 Home 键：PluginManager 用 closeOnHomeRelease=true 注册）
    signal backButtonClicked()

    // ================= 路径 =================
    readonly property string pluginDir: "/userdisk/PenMods/plugins/gdmusic"
    readonly property string ipcScript: pluginDir + "/bin/gdipc.pl"
    readonly property string luaScript: pluginDir + "/bin/gdnext.lua"
    readonly property string mpvSock:   "/tmp/gdmusic.sock"
    readonly property string mpvBin:    "/userdisk/mpv/mpv"
    readonly property string apiHost:   "music-api.gdstudio.xyz"

    // ================= 常驻播放器（后台播放的实现方式） =================
    // 播放**不再由 QML 驱动**。mpv 里挂了一个 lua（bin/gdnext.lua），
    // 取流、顺序播放、播完续下一首、唤醒锁，全部在 mpv 进程内完成。
    //
    // 为什么这么做：本机不是 Android，没有 OS 级后台服务，mpv 被 init 收养后
    // 是独立进程（实测 ppid=1）。lua 跑在 mpv 内部，所以「插件页被销毁」
    // 完全不影响播放 —— 关掉插件，音乐照放，队列照续，队列播完自动释放唤醒锁并停下。
    //
    // 两个文件就是全部接口：
    //   queue.json  QML 写、lua 读：队列 / 当前索引 / 音源 / 优选 IP / 是否连播
    //   now.json    lua 写、QML 读：实时状态（index/status/pos/dur/曲目信息）
    // 命令走 mpv IPC 的 script-message（gd-load / gd-next / gd-prev / gd-stop）。
    readonly property string stateDir:  "/tmp/gdmusic"
    readonly property string queueFile: stateDir + "/queue.json"
    readonly property string nowFile:   stateDir + "/now.json"

    // PenMods 的 AudioDaemon 用 /tmp/audio_wakelocks/*.lock 判断「是否有外部进程正在出声」：
    // 文件名任意，内容是持有者 PID（守护进程用 kill(pid,0) 校验存活，进程死了会自动清理孤儿锁）。
    // 没有任何有效锁时，它会在 closeDelayMs 后 closeAudioOutput 关掉音频设备 —— 会把 mpv 掐断。
    // 现在这把锁由 lua 负责（开播落锁、队列播完释放），QML 只在强行重置播放器时兜底清理。
    readonly property string wakeLockDir:  "/tmp/audio_wakelocks"
    readonly property string wakeLockFile: wakeLockDir + "/gdmusic.lock"

    // ================= 系统媒体接口（词典笔自带的多媒体控制） =================
    // 原厂把一批管理器注册成 QML 上下文属性（`mediaPlayerManager` / `mediaManager` /
    // `soundCenter` / `qmlGlobal` …），与 PenMods 的 `shell` 同属 root context。
    // 我们插件的 QML 跑在同一个 engine、同一个 root context 里 ⇒ 理论上直接可用。
    //   · `mediaPlayerManager` = YMediaPlayerManager，系统媒体中枢：
    //       playState / title / mainLrc / hasLrc / duration / currentPos /
    //       currentSentenceId / playerMode …（只读属性）
    //       onClickedPlay / onClickedPause / onClickedPrev / onClickedNext …（槽）
    //     胶囊面板那张音乐卡片（components/YQuickMusicPlayer.qml）就是它的 UI。
    // 这里只做**能力探测 + 只读观察**，不写它的任何属性 ——
    // 那会伪装成系统播放器状态，可能干扰原厂音频页的判断逻辑。
    readonly property string sysMediaFile: stateDir + "/sysmedia.txt"
    property string sysMediaState: "未探测"     // 设置页显示：可用 / 不可用
    property string sysMediaProbe: ""           // 探测原始结果（一行行拼起来）

    // ================= 本地下载 =================
    // 目录选 /userdisk/Music 是因为它已经是设备上的音乐仓库：
    // LX-Pen 下载的歌就放在这里（LX-Pen / LX-Pen-ch / LX-Pen-jp …），命名格式是「歌名-歌手.mp3」。
    // 沿用同一个目录和命名，好处是系统自带的文件管理器和原生播放器也能直接看到这些歌，
    // 不必打开 GD音乐 插件才能听。（分区实测剩余 2.2G。）
    readonly property string downloadDir:    "/userdisk/Music/GDMusic"
    // 下载缓存区：.part 先落这里（tmpfs），**完整后**才 mv 进 downloadDir。
    // 歌曲文件夹里永远只有完整文件 —— 半截 mp3 被系统播放器扫到会播到一半炸。
    readonly property string dlTmpDir:       stateDir + "/parts"
    readonly property string dlDir:          stateDir + "/dl"
    readonly property string dlMarkL:        "@@GDDL"
    readonly property string dlMarkR:        "@@"
    readonly property string localMark:      "@@GDMUS@@"   // 文件夹扫描的行标记：size|文件名
    // ---- sidecar（随歌下载的附属文件：封面 + 歌词）----
    // 目录**与 mp3 同目录**、同名不同扩展名（歌名-歌手.jpg / 歌名-歌手.lrc）：
    //   · 跟随 mp3 一起被拷走/删除，不产生"孤儿附属文件对不上歌"的新形态；
    //   · 与已有的 .lrc 命名公式完全一致（localLrcFor 就在用同一个 replace）。
    // ⚠️ 扩展名白名单只留**设备 Qt 真有解码器**的格式（实测 /usr/lib/qt/plugins/imageformats
    //    只有 jpeg/gif/ico/svg；webp 没插件 ⇒ 存下来 QML Image 也加载不出来，只能是块空白）。
    //    API 侧实测 netease 返回 .jpg（`.../109951165671182684.jpg?param=500y500`），
    //    但别的音源可能给 png，所以两个都认，其余一律当 jpg 处理。
    readonly property var sidecarImgExts:   [".jpg", ".png"]
    readonly property string sidecarImgExt: ".jpg"       // 兜底扩展名
    readonly property string sidecarMark:   "@@GMSIDE@@" // 扫描输出里标记「这行是个 sidecar 文件名」
    readonly property string lrcMark:       "@@GMLRC@@"  // 扫描输出里标记「这行是个歌词文件名」

    // ================= 音源 / 音质 =================
    // 2026-10-03：**只保留网易云**。下面是 2026-10-01 在设备上**逐个实测**出来的结论，
    // 不是照文档抄的（实测方法：对每个 source 发一次 types=search，再发一次 types=url）。
    //
    //   netease  ✅ 搜索被接受，且 types=url 能拿到真实播放地址 → 唯一能播的
    //   joox     ⚠️ 能搜到，但 types=url 恒返回 {"url":"","br":-1}
    //                （JOOX 是海外服务，国内 IP 取不到流）
    //   bilibili ⚠️ 能搜到，types=url 同样恒空（B 站取流要登录态）
    //   kuwo / tencent / kugou / migu / xiami ❌ 连搜索都直接拒：
    //                {"detail":"Value of `source` is not supported."}
    //
    // 📌 陷阱：「能搜」≠「能播」。joox / bilibili 会正常返回搜索结果，点下去却没声音，
    //    失败点在取流（types=url）而不是搜索，排查时别在搜索层找原因。
    //    另：GD 官网（api.php 首页）写「当前稳定音乐源：netease、kuwo、joox」，
    //    但酷我实测已不支持 —— 别信文档，信实测。
    //
    // ⛔ 切源的**代码路径全部保留**（cycleSource / setSource / 搜索页那个 Repeater）：
    //    以后 GD 音乐台恢复了别的音源，把条目加回这个数组就能用，不必改逻辑。
    //    老存档里残留的 joox / bilibili 由 isValidSource() 兜底回落（见 loadSettings）。
    readonly property var sources: [
        { id: "netease",  label: "网易云" }
    ]
    readonly property var qualityList: ["128", "192", "320", "740", "999"]

    // ================= 设置 =================
    property string source: "netease"
    property string quality: "320"
    property bool   autoNext: true
    property bool   usePreferredIp: true
    property string cfIpText: "104.18.0.1,104.17.0.1,104.19.0.1,104.20.0.1,104.16.0.1,104.25.0.1,104.26.0.1,104.27.0.1,172.66.0.1,162.159.140.1"
    property string bestIp: ""
    property string apiBase: ""
    property bool   loadExtra: true
    // 下载歌曲时**同时**保存歌词（.lrc）与封面（.jpg/.png）到歌名旁边。
    // 与 loadExtra 分开是两个不同的东西：
    //   loadExtra —— 播放时要不要**联网**取（关掉 = 省流量，已下载的本地的照常显示）
    //   dlSidecar —— 下载时要不要**顺手存**（关掉 = 只下 mp3，文件夹保持干净）
    property bool   dlSidecar: true
    // 系统媒体控制（官方 mediaSession）：把在放的歌上报给下拉面板的音乐卡片，
    // 并接收卡片的上一首/播放暂停/下一首/停止。见 MediaBridge.qml。
    property bool   sysMedia: true
    // 面板按「停止」之后是否保留控制条。**默认关** —— 停播即收工：交还会话，宿主的
    // 音乐卡片消失、面板回落设置视图（与原厂播放器的 ✕ 语义一致）。
    // 打开它则卡片留在面板上、▶ 能一键续播（代价是 ✕ 不再是「彻底关掉」）。
    property bool   holdOnStop: false
    // 已下载优先：**在线**条目在写队列时先看本地有没有（精确匹配下载时的命名公式），
    // 命中就补一个 file 字段播本地，不再向 API 取流 —— 省流量、不受会员/音源下线影响。
    // 与「歌单类型」正交：本地歌单全是 file 条目、本来就播本地，对它无感。见 resolveEntry()。
    property bool   preferLocal: true
    // 小于这个字节数视为半截/下坏的文件，不算「本地命中」—— 否则本地优先会把
    // 本来能播的在线歌变成播不了（lua 见 file 就 loadfile，加载失败只能顺延）。
    readonly property int minLocalBytes: 65536

    // ================= 文件登记表（本地文件 ↔ 网易云 id） =================
    // key = 文件的**绝对路径**（不是文件名）：localList[i].file 本身就是绝对路径，
    // 查表零转换，也避免同名歧义。value 形状：
    //   { id, source, name, artist, pic_id, lyric_id, m:"auto"|"manual", t:秒 }
    //
    // 为什么需要它：localPathFor() 的「歌名-歌手.mp3」公式能覆盖**插件自己下的**文件，
    // 但覆盖不了 ① 被用户在文件管理器里改过名的 ② 别的工具（LX-Pen 等）下的。
    // 有了登记表，「在线歌 ↔ 本地文件」就不再依赖文件名公式。
    //   auto   的来源：下载完成那一刻（dlFinish，字段本来就在 .meta 里，见 buildMetaCmd）
    //   manual 的来源：本地页行右侧的匹配入口 → 匹配页
    property var fileMap: ({})

    // ================= 歌单 =================
    // 持久化在 kv["playlists"]，形状：
    //   [ { id:"pl_<毫秒>", name, type:"online"|"local", created:秒, songs:[ … ] } ]
    //     · online 歌单的条目：{ id, source, name, artist, pic_id, lyric_id }
    //     · local  歌单的条目：{ file, name, artist, size }（与 parseLocalScan() 输出同形，
    //       所以「从本地页加歌」是直接搬，零转换）
    //
    // 为什么用 type 分两类（而不是一个歌单混存）：
    //   online 歌单靠 preferLocal 在**播放期**动态命中本地文件 —— 本地删了还能回退网络，可逆；
    //   local  歌单则保证**离线必可播、永不缺歌**，代价是必须先下载。
    //   两者差的是「能收什么歌 + 离线可用性」，与播放出来的结果无关，所以用 type 表述。
    //
    // ⚠️ 只存"身份"、不存"资源"：不存封面地址与播放直链（都带时效，存下来必腐 ——
    //    过期后表现为封面裂图 / 播放 403，且很难与"音源挂了"区分开）。
    //    封面按 pic_id 现取、播放地址每次由 lua 向 API 要。
    property var playlists: []
    readonly property int playlistMax: 20        // 歌单数量上限
    readonly property int playlistSongMax: 300   // 单个歌单曲目上限
    readonly property int playlistNameMax: 24    // 歌单名字数上限（320 宽的标题栏放不下更多）

    // 详情页当前打开的歌单 id（"" = 不在详情页）。
    // 用 id 而不是 index：一次删除会让后面所有 index 整体前移，而 id 永远指得准。
    property string plCurId: ""
    // 正在新建的歌单类型。必须在弹键盘**之前**定下来 —— 键盘是宿主的独立页，
    // 弹出来就把本页盖住了，用户在那边没法再选一次类型。
    property string plNewType: ""
    // 从「加入歌单」页新建时，建完要**顺手加进去**的那首歌；从歌单页新建则为 null。
    // 用户点「新建」的意图本来就是"这首歌要有个地方放"，让他建完再点一次是白多一步。
    property var plNewSong: null
    // 正在重命名的歌单 id（"" = 没在重命名）。与 plNewType 一样：弹键盘前先定下目标，
    // 键盘一弹就把本页盖住了，用户在那边没法再点一次要改哪个歌单。
    property string plRenameId: ""

    // ============================================================
    // 网易云账号（登录 + 歌单同步）
    // 只存**长期凭证 cookie** 与**身份快照**，不存任何资源地址（封面/直链都带时效）。
    // 登录态判据：/api/nuser/account/get 的 profile 是否为 null（天然判据，无需另存 flag）。
    // ============================================================
    property string ncCookie: ""        // 网易云登录 cookie（MUSIC_U 等，curl 直接 -H 'Cookie: ...'）
    property string ncUid: ""           // 登录后的用户 uid（account.id）
    property string ncNick: ""          // 昵称（profile.nickname），登录页展示
    // 扫码登录三段状态机：
    property string ncUnikey: ""        // 当前二维码的 unikey（轮询用）
    property string ncPhase: "idle"     // idle / waiting(801 待扫) / scanned(802 待确认) / done(803) / expired(800) / error
    property bool   ncSyncing: false    // 正在同步歌单
    property string ncSyncMsg: ""       // 同步进度提示（登录页显示）
    property bool   ncSyncAbort: false  // 用户点了「取消同步」：下一拍收尾，已拿到的照常入库
    property var    ncSyncRetry: null   // 限频退避重试的现场 {own,i,acc,tries}
    property int    ncQrStamp: 0        // 二维码 cache-bust 时间戳（每次重新登录 +1，页面据此换 source）
    property bool   ncStarting: false   // 正在申请 unikey（重入守卫，见 ncStartLogin）
    property string ncQrFile: ""        // 当前该显示的二维码文件路径（带 unikey 前缀，避免并发覆盖）
    property int    ncCooldown: 0       // 冷却剩余秒数（>0 禁止重新申请 unikey，见 ncRisk）
    property string ncRiskMsg: ""       // 风控/异常提示文案（8821 等，登录页显示）
    property int    ncFail: 0           // 连续解析失败次数（网络抖动容错，非服务端拒绝）
    readonly property int ncCoolSec: 60 // 触发风控后的冷却时长（秒）

    // 🔴 请求头必须"像浏览器"，而且**全插件统一一个 UA**。
    //    以前写的是 `-A 'Mozilla/5.0'`（残缺到离谱），而且散落在 6 处各自硬编码 ——
    //    加上 curl 默认不发 Accept / Accept-Language，整套请求在风控眼里就是裸奔的脚本。
    //    对照设备上 bili 插件（稳定跑登录半年）：它用**完整 Chrome 120 UA** + Referer，
    //    并且登录走 C++ QtNetwork（自带全套浏览器头）。这是最像样的模板，照抄。
    //    实测 8821「请切换其他登录方式」= 网易云环境风控，请求头不像浏览器是首要嫌疑。
    readonly property string uaBrowser: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    // curl 默认不会发 Accept / Accept-Language，真实浏览器必带 —— 风控常拿这个筛脚本。
    readonly property string ncHdr: "Accept: */*|Accept-Language: zh-CN,zh;q=0.9"
    // 网易云第三方客户端的通行 cookie（os=pc + appver）。写进 jar 而不是 -H，
    // 避免与 -b jar 同时给出两个 Cookie 头。
    readonly property string ncBaseCookie: "os=pc; appver=2.9.7"

    // ============================================================
    // 屏幕快照（远程验收用）
    //
    // 为什么放在插件里而不是设备上截屏：设备上「从外部拿到画面」的路全被实测堵死了
    //（weston 没 --debug ⇒ screenshooter 拒；qmlscene offscreen/vnc 无 GL；
    //   外部 wayland 客户端建不出窗口；/dev/fb0 禁碰）。
    // 但**插件自己就跑在主程序那个真实窗口里**，Item.grabToImage() 走的是 Qt 场景图
    // 的 FBO 抓取，根本不需要外部客户端建窗口 —— 这条路以前从没试过。
    //
    // 用法：电脑侧 `touch /tmp/penmods_shot` 写一次哨兵文件，本插件的 shotPollTimer
    // 轮询到就把当前画面存成 PNG，电脑侧再 adb pull 走。
    // 这是**给验收用的调试通道**，平时 Timer 因 running=false 完全不耗电、不占资源。
    //
    // ⚠️ 哨兵路径与 C++ 侧 ScreenGrabber **故意用同一个** /tmp/penmods_shot：
    // 那条走 QQuickWindow::grabWindow()，任意页面都能截（连本插件页没打开时都行）；
    // 本条是它的插件页补充（页面局部、旋转已转正）。同名 ⇒ 一个 touch 同时覆盖两条，
    // 谁先跑完谁出图，另一条顶多再写一份 log。抢到同一张就当双通道互为验证。
    // ============================================================
    readonly property string shotReq:  "/tmp/penmods_shot"        // 哨兵（存在即抓图；与 C++ 侧同名）
    readonly property string shotOut:  "/tmp/penmods_gd_shot"     // 抓图输出（与 C++ 的 penmods_shot-N 区分）
    readonly property string shotLog:  "/tmp/penmods_shot.log"    // 抓图结果日志（共用，追加写）
    property bool shotBusy: false                                 // 抓图中（防重入）
    property int  shotSeq: 0                                      // 抓图计数（文件名带序号，防拉错帧）

    // 抓当前插件页画面 → 存 PNG。deviceLog 走 shell，日志落到 shotLog 供电脑侧读。
    function grabShot() {
        if (shotBusy) return
        if (typeof root.grabToImage !== "function") return
        shotBusy = true
        var path = shotOut + "-" + shotSeq + ".png"
        // grabToImage 是**异步**的：回调里才拿到结果对象，saveToFile 必须在回调里调。
        root.grabToImage(function (res) {
            shotBusy = false
            if (!res || typeof res.saveToFile !== "function") {
                if (typeof shell !== "undefined" && shell)
                    shell.exec("echo 'grab-nores' >> " + shotLog)
                return
            }
            var ok = false
            try { ok = res.saveToFile(path) } catch (e) { ok = false }
            if (typeof shell !== "undefined" && shell)
                shell.exec("echo '" + (ok ? "ok " : "fail ") + path
                           + " " + (res.width || 0) + "x" + (res.height || 0)
                           + "' >> " + shotLog)
            res.destroy()
            shotSeq++
        })
    }

    // 详情页的**视图快照** —— 这一层存在的唯一目的，是让「歌单内容变了」这件事
    // 一定能被界面看见。
    //
    // 为什么不直接在页面里写 `playlistById(plCurId).songs`：
    //   写操作虽然都「整体重新赋值 playlists」，但 clonePlaylists 只拷贝外层数组，
    //   歌单对象本身仍是**同一个引用** ⇒ 页面里 `property var pl: playlistById(id)`
    //   重算后拿到的是同一个对象，它下面挂的 songs 绑定很可能不再重算，
    //   症状就是「数据明明对了、列表就是不刷新」——最难查的一类问题。
    //   这里每次重算都返回**新建的对象 + slice 出来的新数组**，值必然不同 ⇒ 通知必然发出。
    // 顺带：songs 那一份拷贝让页面完全碰不到真数据（详情页怎么折腾都改不到 playlists）。
    readonly property var plView: {
        var pl = playlistById(plCurId)
        if (!pl) return null
        return { id: pl.id, name: pl.name, type: pl.type, source: pl.source || "",
                 songs: pl.songs.slice(0), count: pl.songs.length }
    }

    // 歌单列表页底部：N 个歌单 · 共 M 首
    readonly property string plStat: {
        var n = playlists.length, m = 0
        for (var i = 0; i < n; i++)
            if (playlists[i] && playlists[i].songs) m += playlists[i].songs.length
        return n + " 个歌单 · 共 " + m + " 首"
    }

    // ================= 「加入歌单」页 =================
    // 加歌的载体：**同时带在线形态（id/source）与本地形态（file）**，见 addTargetOf。
    property var    addPickSong: null
    // "list" = 选歌单 / "type" = 新建时选类型。做成页内两态而不是嵌套浮层：
    // 320×170 上叠两层浮层后，下层被盖住的部分既看不见也点不到，用户会以为卡住了。
    property string addPickStep: "list"

    // 每个歌单的**可加性**快照。与 plView 同一个套路：值重建，保证「加完一首后
    // 徽标从『加入』变『已在』」这件事界面一定看得见。
    // state: ok=可加 / dup=已在歌单里 / type=类型不符（离线歌单收不了在线曲，反之亦然）
    //        / full=该歌单已满
    readonly property var addPickEntries: {
        var out = []
        var song = addPickSong
        if (!song) return out
        for (var i = 0; i < playlists.length; i++) {
            var pl = playlists[i]
            if (!pl || !(pl.songs instanceof Array)) continue
            // 归一化一次就同时回答了"类型符不符"和"去重键是什么"两个问题
            var norm = sanitizeSong(song, pl.type)
            var st = "ok"
            if (!norm)                                          st = "type"
            else if (playlistHasSong(pl, plKeyOf(norm)))        st = "dup"
            else if (pl.songs.length >= playlistSongMax)        st = "full"
            out.push({ id: pl.id, name: pl.name, type: pl.type,
                       typeText: playlistTypeText(pl.type),
                       source: pl.source || "",
                       count: pl.songs.length, state: st })
        }
        return out
    }

    // 底部统计：只数"点得动"的那些 —— 直接说「N 个歌单」会让用户对着
    // 一列灰掉的条目纳闷"到底能加哪个"。
    readonly property string addPickStat: {
        var e = addPickEntries, ok = 0
        for (var i = 0; i < e.length; i++) if (e[i].state === "ok") ok++
        if (!e.length) return "还没有歌单"
        return e.length + " 个歌单 · " + ok + " 个可加入"
    }

    // 手动匹配页（page === "match"）的状态
    property var    matchRec: null      // 正在匹配的本地记录（localList 的一条）
    property string matchQuery: ""      // 搜索词，默认是从文件名反推的「歌名 歌手」
    property var    matchResults: []    // 匹配页的搜索结果
    property bool   matchBusy: false

    // ⚠️ 这里【刻意】没有 volume 属性：音量交给系统统一管（见 buildEnsurePlayerCmd 注释）。
    // 插件端一衰减，系统音量再拉满也上不去，两边叠乘后用户会以为"声音很小/调节失灵"。

    // ================= API 请求（后台执行 + 轮询结果文件） =================
    property var    apiPending: ({})
    property int    apiSeq: 0

    // ================= 页面 =================
    property string page: "search"
    property string backPage: "search"

    // ================= 搜索 =================
    property string keyword: ""
    property var    results: []
    property bool   searching: false
    property string lastMsg: ""
    property string netState: "点此测试"

    // ================= 搜索历史 =================
    // 只存关键词本身，不存音源：换音源重搜同一个词是很常见的操作，
    // 带上音源会让同一个词在列表里出现两遍，反而更难找。
    property var    searchHistory: []
    property bool   historyOpen: false
    readonly property int historyMax: 20

    // ================= 播放 =================
    // 注意：播放的「真相」在常驻播放器（bin/gdnext.lua）那边。
    // 这里的属性是它状态的镜像，由 now.json 每秒同步一次 ——
    // 所以插件开着、关着，看到的行为一致。
    property var    queue: []
    property int    queueIndex: -1
    property var    currentSong: null
    property bool   playing: false
    property bool   paused: true
    property double timePos: 0
    property double duration: 0
    property string coverUrl: ""
    property string statusText: ""

    // ================= 歌词 =================
    property var lyricLines: []
    property int lyricIndex: -1

    // 把「只有插件页才会去取」的两样东西喂给媒体会话桥：
    // 歌词数组、封面地址。桥自己按进度推进当前歌词行，所以这里只需在变化时推一次
    // —— 页面关掉之后，歌词行照样跟着 pos 往前走。
    onLyricLinesChanged: MediaBridge.setLyrics(lyricLines)
    onCoverUrlChanged:   MediaBridge.setCover(coverUrl)

    // 本地下载
    property var    localList: []       // 已下载曲目（**扫文件夹实时得出**，不做任何本地登记）
    // 已下载的封面：{ "歌名-歌手": 绝对路径 }，来自与 localList **同一次** shell 扫描。
    // 与 localList 分开存而不是把路径塞进每条记录：封面是**可有可无**的附属物，
    // 塞进记录会让"这首歌"这个概念背上两种形状（§3.8 的老问题）。
    property var    sidecarImgs: ({})
    property var    sidecarLrcs: ({})
    property string localStat: ""       // 本地页底部：N 首 · 占用 xx MB
    property var    dlPending: ({})     // key -> { id, song, file, st, meta, got, total, msg }  活动的任务（含排队）
    property var    dlState: ({})       // songId -> "queue" / "run" / "ok" / "fail"
    property int    dlSeq: 0
    // 串行队列：curl 一个一个下。设备只有 460MB，并发下载除了互抢带宽
    // 还会让进度没法看；排队的 key 放 dlQueue，正在下的放 dlRunning。
    property var    dlQueue: []         // 排队中的 key（FIFO）
    property string dlRunning: ""      // 正在下载的 key（""=空闲）
    property var    dlQueueView: []     // 给 UI 的队列快照（本地页卡片 + 标签角标）

    readonly property double progress: (duration > 0) ? Math.min(1, timePos / duration) : 0

    // ============================================================
    // 工具
    // ============================================================
    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    function fmtTime(sec) {
        if (sec === undefined || sec === null || isNaN(sec) || sec < 0) return "00:00"
        var m = Math.floor(sec / 60)
        var s = Math.floor(sec % 60)
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
    }

    function sourceLabel() {
        for (var i = 0; i < sources.length; i++)
            if (sources[i].id === source) return sources[i].label
        return source
    }

    function isValidSource(id) {
        for (var i = 0; i < sources.length; i++)
            if (sources[i].id === id) return true
        return false
    }

    function qualityLabel() {
        var map = { "128": "128k", "192": "192k", "320": "320k", "740": "无损 16bit", "999": "无损 24bit" }
        return map[quality] || (quality + "k")
    }

    // ============================================================
    // 网络层：优选 IP 轮换
    // ============================================================
    // 尝试顺序：实测最快的 IP -> 配置列表（最多 5 个） -> 系统 DNS 默认
    function preferredIps() {
        var list = []
        if (usePreferredIp && apiBase.length === 0) {
            if (bestIp.length) list.push(bestIp)
            var raw = String(cfIpText || "").split(",")
            for (var i = 0; i < raw.length && list.length < 5; i++) {
                var s = raw[i].trim()
                if (/^\d{1,3}(\.\d{1,3}){3}$/.test(s) && list.indexOf(s) < 0) list.push(s)
            }
        }
        list.push("")   // 兜底：走系统 DNS 默认解析
        return list
    }

    // 生成一段 shell：按 ips 顺序尝试，首个拿到 JSON 的即写入 outFile，最后补 token。
    // 关键点：整个重试循环在**一个**后台 shell 里跑，因此不受 shell.execAsync 5 秒上限约束，
    // 每个 IP 可以给足 6 秒（API 响应实测在 1.1s~16s 之间波动）。
    function buildApiCmdForIps(qs, outFile, token, ips) {
        var url = ""
        if (apiBase.length > 0) {
            var base = apiBase.replace(/\/+$/, "")
            url = base + (base.indexOf("?") >= 0 ? "&" : "?") + qs
        } else {
            url = "https://" + apiHost + "/api.php?" + qs
        }

        var s = "rm -f " + outFile + "; "
        if (apiBase.length > 0) {
            // 自定义中转：不做 IP 优选，直接请求
            s += "r=$(LC_ALL=C curl -s --max-time 12 -A " + shellQuote(uaBrowser) + " " + shellQuote(url) + " 2>/dev/null); "
            s += "case \"$r\" in \"[\"*|\"{\"*) printf '%s' \"$r\" > " + outFile + ";; esac; "
        } else {
            for (var i = 0; i < ips.length; i++) {
                var ip = ips[i]
                var curl = "LC_ALL=C curl -s --max-time 6 -A " + shellQuote(uaBrowser)
                if (ip && ip.length) curl += " --resolve " + shellQuote(apiHost + ":443:" + ip)
                s += "if [ ! -s " + outFile + " ]; then r=$(" + curl + " " + shellQuote(url) + " 2>/dev/null); "
                s += "case \"$r\" in \"[\"*|\"{\"*) printf '%s' \"$r\" > " + outFile + ";; esac; fi; "
            }
        }
        s += "printf '%s' " + shellQuote(token) + " >> " + outFile
        return s
    }

    function apiGet(qs, cb) { apiGetWithIps(qs, preferredIps(), cb) }

    function apiGetWithIps(qs, ips, cb) {
        if (typeof shell === "undefined" || !shell) { cb(false, ""); return }
        apiSeq++
        var key = "" + apiSeq
        var out = "/tmp/gdmusic_api_" + key + ".out"
        var token = "GDDONE" + key + "Z"
        apiPending[key] = { cb: cb, out: out, token: token, t0: Date.now() }
        shell.startDetached(buildApiCmdForIps(qs, out, token, ips))
        apiPollTimer.restart()
    }

    readonly property string apiMarkL: "@@GDMARK"
    readonly property string apiMarkR: "@@"

    function apiPoll() {
        var keys = Object.keys(apiPending)
        if (keys.length === 0) { apiPollTimer.stop(); return }

        // 🔴 两阶段读取：先只问「完成没有」（grep -c，回传几十字节），只有完成的才 cat 全文。
        //    旧实现每 400ms 把**所有** pending 文件整份 cat 回来再正则切分 —— 同步歌单时
        //    单个响应就有 500KB（一个歌单 205 首的完整 tracks），主线程被 400ms 一次的
        //    500KB 字符串 + split 反复卡住，症状正是「拉取期间界面点不动、连返回都退不出去」。
        var cmd = ""
        for (var i = 0; i < keys.length; i++) {
            var it = apiPending[keys[i]]
            cmd += "echo '" + apiMarkL + keys[i] + apiMarkR + "'; "
                 + "if [ -f " + it.out + " ]; then grep -c " + shellQuote(it.token) + " "
                 + it.out + " 2>/dev/null; else echo 0; fi; "
        }
        var dump = ""
        try { dump = String(shell.exec(cmd)) } catch (e) { dump = "" }

        var parts = dump.split(new RegExp(apiMarkL + "(\\d+)" + apiMarkR))
        var finished = []
        for (var j = 1; j + 1 < parts.length; j += 2) {
            var n = parseInt(String(parts[j + 1]).trim(), 10)
            if (n > 0) finished.push(parts[j])
        }
        for (var f = 0; f < finished.length; f++) apiFinish(finished[f])

        // 未命中且已超时的：判死回调（大响应给到 40s，别把慢但正常的请求误杀）
        var now = Date.now()
        var rest = Object.keys(apiPending)
        for (var k = 0; k < rest.length; k++) {
            var p = apiPending[rest[k]]
            if (p && now - p.t0 > 40000) {
                delete apiPending[rest[k]]
                p.cb(false, "")
            }
        }
    }

    // 收尾一个「已完成」的请求：cat 全文 → 截掉 token → 回调。
    function apiFinish(id) {
        var p = apiPending[id]
        if (!p) return
        delete apiPending[id]
        var content = ""
        try { content = String(shell.exec("cat " + p.out + " 2>/dev/null; true")) } catch (e) { content = "" }
        var idx = content.indexOf(p.token)
        var body = (idx >= 0) ? content.substring(0, idx).trim() : content.trim()
        // ⚠️ 别一律用 `body.length > 1` 判成功：有些请求的「产物」**就是那个 token 本身**
        //    （正文为空），例如等二维码下载落盘的 .done 文件。统一按长度判会把它们全判成
        //    失败 ⇒ 登录页一打开就显示"登录失败，点下方重试"。
        //    needsBody=false 的项只要 token 出现就算成功。
        var ok = (p.needsBody === false) ? (idx >= 0) : (body.length > 1)
        p.cb(ok, body)
    }

    Timer {
        id: apiPollTimer
        interval: 400
        repeat: true
        running: false
        onTriggered: root.apiPoll()
    }

    // ============================================================
    // 网易云官方 API（直连 music.163.com，与 GD apiHost 是两条独立链路）
    // 登录/歌单同步专用。GD 的 apiGet 复用不了：域名不同（不可 --resolve 到 CF IP）、
    // 要 POST（申请 unikey）、要带 Cookie（轮询与歌单请求）。所以单独一套。
    // 命令生成都是**纯函数**（不碰 shell），无头探针可直接抠出来断言。
    // ============================================================

    // 公共请求头（纯函数）。🔴 三处命令必须共用它，别再各自写 -A：
    //    以前三处都硬编码 `-A 'Mozilla/5.0'`，且不带 Accept / Accept-Language ——
    //    curl 默认不发这两个头，真实浏览器必发，风控拿它筛脚本成本极低。
    //    对照 bili 插件（同设备稳定登录）：完整 Chrome UA + Referer，登录走 C++ QtNetwork。
    //    实测 8821「请切换其他登录方式」正是环境风控，请求头不像浏览器是首要嫌疑。
    function ncCurlHdr(extra) {
        var s = " -A " + shellQuote(uaBrowser) + " -e 'https://music.163.com/'"
        var parts = ncHdr.split("|")
        for (var i = 0; i < parts.length; i++)
            s += " -H " + shellQuote(parts[i])
        if (extra && extra.length) s += " " + extra
        return s
    }

    // 生成一段 curl：GET 网易云接口。带 Cookie 时用 -H，超时 12s，输出判 JSON。
    // 与 buildApiCmdForIps 不同：这里域名固定 music.163.com，DNS 走系统（实测设备直连成功，
    // 阿里 DNS 223.5.5.5，不需要 CF 优选）。加 Referer 压低风控（部分接口裸请求会 405）。
    function buildNcGetCmd(url, outFile, token) {
        var extra = ncCookie.length ? "-H " + shellQuote("Cookie: " + ncCookie) : ""
        var s = "rm -f " + shellQuote(outFile) + "; "
        s += "r=$(LC_ALL=C curl -s --max-time 12" + ncCurlHdr(extra)
        s += " " + shellQuote(url) + " 2>/dev/null); "
        s += "case \"$r\" in \"[\"*|\"{\"*) printf '%s' \"$r\" > " + shellQuote(outFile) + ";; esac; "
        s += "printf '%s' " + shellQuote(token) + " >> " + shellQuote(outFile)
        return s
    }

    // 生成一段 curl：POST 网易云接口（申请 unikey 用）。body 走 -d 表单。
    function buildNcPostCmd(url, data, outFile, token) {
        var s = "rm -f " + shellQuote(outFile) + "; "
        s += "r=$(LC_ALL=C curl -s --max-time 12" + ncCurlHdr("")
        s += " -X POST -d " + shellQuote(data) + " " + shellQuote(url) + " 2>/dev/null); "
        s += "case \"$r\" in \"[\"*|\"{\"*) printf '%s' \"$r\" > " + shellQuote(outFile) + ";; esac; "
        s += "printf '%s' " + shellQuote(token) + " >> " + shellQuote(outFile)
        return s
    }

    // 生成一段 curl：请求并把 **Set-Cookie 存进 jar**（扫码 803 时抓 cookie 用）。
    // 用 -c 存 jar、-b 读回已存 jar，实现"每次轮询都带最新 cookie、拿到就更新"。
    function buildNcCheckCmd(url, jar, outFile, token) {
        var s = "rm -f " + shellQuote(outFile) + "; "
        s += "r=$(LC_ALL=C curl -s --max-time 12" + ncCurlHdr("")
        s += " -c " + shellQuote(jar) + " -b " + shellQuote(jar)
        s += " " + shellQuote(url) + " 2>/dev/null); "
        s += "case \"$r\" in \"[\"*|\"{\"*) printf '%s' \"$r\" > " + shellQuote(outFile) + ";; esac; "
        s += "printf '%s' " + shellQuote(token) + " >> " + shellQuote(outFile)
        return s
    }

    // 把 os=pc / appver 种进 cookie jar（Netscape 格式），**只在缺失时追加**。
    // 为什么写 jar 而不是 -H Cookie：-b jar 与 -H Cookie 同时给会让 curl 发出两行
    // Cookie 头；写进 jar 则由 curl 自己合并，且 -c 回写时不会丢。
    // 这两个值是网易云第三方客户端的通行标识，缺了容易被判"非官方环境"。
    function buildNcSeedJarCmd(jar) {
        var seed = "music.163.com\tFALSE\t/\tFALSE\t0\tos\tpc\n"
                 + "music.163.com\tFALSE\t/\tFALSE\t0\tappver\t2.9.7\n"
        return "touch " + shellQuote(jar) + "; "
             + "grep -q '^[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\tos\t' " + shellQuote(jar)
             + " 2>/dev/null || printf '" + seed.replace(/\n/g, "\\n") + "' >> " + shellQuote(jar)
    }

    // 生成二维码图片的下载命令：第三方 QR 服务（官方 /login/qrcode/<key> 已废弃 404）。
    // 二维码内容 = https://music.163.com/login?codekey=<unikey>
    function ncQrContent() {
        return "https://music.163.com/login?codekey=" + encodeURIComponent(ncUnikey)
    }

    function buildNcQrCmd(outImg) {
        var url = "https://api.pwmqr.com/qrcode/create/?url=" + encodeURIComponent(ncQrContent())
        // ⚠️ 必须 --http1.1：设备 curl 默认走 HTTP/2 时，pwmqr 返回 200 但 body 为空，
        //    下载下来是 0 字节空文件 ⇒ 二维码不显示。music.163.com 各接口 h2 正常，不用动。
        return "rm -f " + shellQuote(outImg) + "; "
             + "curl -sL --http1.1 --max-time 15 -A " + shellQuote(uaBrowser) + " -o " + shellQuote(outImg)
             + " " + shellQuote(url) + "; true"
    }

    // buildNcQrCmd + 完成信号：下载后把 token 写进 done 文件，供 ncWaitImg 判定"可换 source 了"。
    // 用 `wc -c` 判非空（设备 busybox 的 wc 带文件名，字节数在第一列）。
    function buildNcQrWaitCmd(outImg, doneFile, token) {
        return buildNcQrCmd(outImg) + "; "
             + "n=$(LC_ALL=C wc -c < " + shellQuote(outImg) + " 2>/dev/null || echo 0); "
             + "if [ \"$n\" -gt 0 ] 2>/dev/null; then printf '%s' " + shellQuote(token)
             + " > " + shellQuote(doneFile) + "; fi; true"
    }

    // 发起一次网易云请求（通用）。out/token 复刻 apiGetWithIps 的异步回读机制。
    // path 是 music.163.com 下的完整路径（含 query）。
    function ncGet(path, cb) { ncReq(function(out, token) { return buildNcGetCmd("https://music.163.com" + path, out, token) }, cb) }
    function ncPost(path, data, cb) { ncReq(function(out, token) { return buildNcPostCmd("https://music.163.com" + path, data, out, token) }, cb) }
    function ncReq(cmdBuilder, cb) {
        if (typeof shell === "undefined" || !shell) { cb(false, ""); return }
        apiSeq++
        var key = "" + apiSeq
        var out = "/tmp/gdmusic_api_" + key + ".out"
        var token = "GDDONE" + key + "Z"
        apiPending[key] = { cb: cb, out: out, token: token, t0: Date.now() }
        shell.startDetached(cmdBuilder(out, token))
        apiPollTimer.restart()
    }

    // 下载进度轮询。1.5s 一次 —— 下载动辄几十秒到几分钟，不必像播放器那样每秒问，
    // 但太慢又会让「点了下载」看起来没反应。
    Timer {
        id: dlPollTimer
        interval: 1500
        repeat: true
        running: false
        onTriggered: root.dlPoll()
    }

    // sidecar（歌词/封面）落盘后重扫本地列表，让"有封面/有歌词"标记立刻更新。
    // ⚠️ 用 restart() 而不是重复 start()：restart 在已运行时会把计时**归零**，
    //    连续三首的 sidecar 几乎同时回来 ⇒ 不归零就会触发三次几乎一样的全量扫描。
    Timer {
        id: sidecarRescanTimer
        interval: 800
        repeat: false
        running: false
        onTriggered: root.refreshLocal()
    }

    // ============================================================
    // 优选 IP 扫描（健康度会随时间漂移，可手动重扫）
    // ============================================================
    property bool scanning: false
    property int  scanIdx: 0
    property var  scanList: []
    property var  scanGood: []

    function ipCandidates() {
        return ["104.18.0.1", "104.17.0.1", "104.19.0.1", "104.20.0.1", "104.16.0.1",
                "104.25.0.1", "104.26.0.1", "104.27.0.1", "172.66.0.1", "162.159.140.1"]
    }

    function startIpScan() {
        if (scanning) { toast.show("正在扫描中…"); return }
        scanning = true
        scanGood = []
        scanIdx = 0
        scanList = ipCandidates()
        netState = "扫描中…"
        scanNext()
    }

    function scanNext() {
        if (scanIdx >= scanList.length) {
            scanning = false
            if (scanGood.length) {
                cfIpText = scanGood.join(",")
                bestIp = scanGood[0]
                saveSettings()
                netState = "可用 " + scanGood.length + " 个"
                toast.show("找到 " + scanGood.length + " 个可用 IP")
            } else {
                netState = "扫描失败"
                toast.show("没有找到可用 IP")
            }
            return
        }
        var ip = scanList[scanIdx]
        netState = "扫描 " + (scanIdx + 1) + "/" + scanList.length
        apiGetWithIps("types=search&source=netease&name=test&count=1", [ip], function(ok) {
            if (ok) scanGood.push(ip)
            scanIdx++
            scanNext()
        })
    }

    function testNetwork() {
        netState = "测试中…"
        var t0 = Date.now()
        apiGet("types=search&source=netease&name=test&count=1", function(ok) {
            var ms = Date.now() - t0
            netState = ok ? ("正常 " + ms + "ms") : "失败"
            toast.show(ok ? ("连接正常 " + ms + "ms") : "连接失败，请检查优选 IP 或网络")
        })
    }

    // ============================================================
    // 搜索
    // ============================================================
    function doSearch() {
        var kw = String(keyword).trim()
        if (!kw.length) { toast.show("请先输入关键词"); openKeyboard(); return }
        // 搜出结果后把历史浮层收起来，否则它盖在列表上，用户看不见刚搜到的歌。
        // （进插件时会自动摊开 —— 那时手上没有结果，正好当默认页用。）
        historyOpen = false
        searching = true
        lastMsg = ""
        results = []
        var qs = "types=search&source=" + source + "&name=" + encodeURIComponent(kw) + "&count=30&pages=1"
        apiGet(qs, function(ok, txt) {
            searching = false
            if (!ok) {
                lastMsg = "搜索失败\n请到设置里测试连通性"
                toast.show("搜索失败")
                return
            }
            var arr = null
            try { arr = JSON.parse(txt) } catch (e) { arr = null }
            if (!arr || !arr.length) { lastMsg = "没有找到结果"; toast.show("没有找到结果"); return }
            results = arr
            lastMsg = ""
            // 只有真的搜到了才记：把打错的词也攒进历史，列表很快就废了
            pushHistory(kw)
        })
    }

    // ============================================================
    // 搜索历史（LocalStorage kv 表，key="history"，值是 JSON 数组）
    // ============================================================
    function loadHistory() {
        try {
            var d = db()
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                var rs = tx.executeSql("SELECT value FROM kv WHERE key=?", ["history"])
                var raw = rs.rows.length ? String(rs.rows.item(0).value || "") : ""
                var arr = []
                try { arr = JSON.parse(raw) } catch (e) { arr = [] }
                if (!arr || typeof arr.length !== "number") arr = []
                // 读的时候就顺手去重 + 截断：sqlite 里的旧数据可能是任何形态
                var out = []
                for (var i = 0; i < arr.length && out.length < historyMax; i++) {
                    var s = String(arr[i] === undefined || arr[i] === null ? "" : arr[i]).trim()
                    if (s.length && out.indexOf(s) < 0) out.push(s)
                }
                searchHistory = out
            })
        } catch (e) { console.warn("loadHistory", e) }
    }

    function saveHistory() {
        try {
            var d = db()
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", ["history", JSON.stringify(searchHistory)])
            })
        } catch (e) { console.warn("saveHistory", e) }
    }

    // 去重 + 提到最前 + 截断。重复搜同一个词不该让列表越攒越长。
    function pushHistory(kw) {
        var s = String(kw === undefined || kw === null ? "" : kw).trim()
        if (!s.length) return
        var arr = searchHistory.slice()
        var at = arr.indexOf(s)
        if (at >= 0) arr.splice(at, 1)
        arr.unshift(s)
        if (arr.length > historyMax) arr = arr.slice(0, historyMax)
        searchHistory = arr
        saveHistory()
    }

    function removeHistoryAt(i) {
        if (i < 0 || i >= searchHistory.length) return
        var arr = searchHistory.slice()
        arr.splice(i, 1)
        searchHistory = arr
        saveHistory()
    }

    function clearHistory() {
        searchHistory = []
        saveHistory()
        toast.show("已清空搜索历史")
    }

    // 点历史条目 = 填词 + 立刻搜（和手输完按回车完全等价）
    function searchWord(kw) {
        keyword = String(kw === undefined || kw === null ? "" : kw).trim()
        historyOpen = false
        if (!keyword.length) return
        doSearch()
    }

    // ============================================================
    // 播放
    // ============================================================
    function playFrom(index) {
        if (!results || index < 0 || index >= results.length) return
        queue = results
        page = "player"
        startAt(index)
    }

    // 让常驻播放器播队列第 i 首。
    // QML 只做两件事：把队列写成文件，再发一条 script-message。
    // 取流、失败顺延、播完续下一首全在 lua 里做，QML 通过 now.json 跟随显示。
    function startAt(i) {
        if (!queue || !queue.length) return
        var idx = Math.max(0, Math.min(queue.length - 1, i))
        queueIndex = idx
        currentSong = queue[idx]
        timePos = 0
        duration = 0
        lyricLines = []
        lyricIndex = -1
        coverUrl = ""
        statusText = "解析播放地址…"
        loadExtras(currentSong)
        writeQueueJson(idx)

        ensurePlayer()
        sendScriptMsg("gd-load")
        pollTimer.fails = 0
        pollTimer.restart()
        MediaBridge.kick()   // 立刻让媒体会话桥上会话，面板不用等下一拍
    }

    // 队列的 JSON 文本（纯函数，便于无头校验直接断言）
    // list 逐条过 resolveEntry()：已下载的在线歌在这里被补上 file 字段 ⇒ 改播本地文件。
    // ⚠️ 用显式循环而不是 queue.map()：QML 的 JS 引擎虽然支持 ES5，但显式循环零兼容风险，
    //    而且这里是**唯一**的解析点，写直白点便于日后审查。
    function queueJsonString(idx) {
        if (!queue || !queue.length) return ""
        var list = []
        for (var i = 0; i < queue.length; i++) list.push(resolveEntry(queue[i]))
        var payload = {
            list: list,
            index: ((idx === undefined) ? queueIndex : idx) + 1,
            source: source,
            quality: quality,
            ips: preferredIps(),
            autoNext: autoNext,
            apiBase: apiBase
        }
        return JSON.stringify(payload)
    }

    // 把队列写进 queue.json 的完整命令行（纯函数，便于无头校验 + 端到端原样执行）。
    // 直接 printf 单引号包裹的 JSON 即可，不必走 base64：
    //   JSON.stringify 的输出只用双引号，不会含裸单引号；
    //   值里万一有单引号，shellQuote 会正确转义；
    //   中文是 UTF-8 字节，在单引号内原样写入；换行已被 JSON 转义成 \n。
    function buildQueueWriteCmd(idx) {
        var json = queueJsonString(idx)
        if (!json.length) return ""
        return "mkdir -p " + stateDir + "; printf '%s' " + shellQuote(json)
             + " > " + queueFile + "; true"
    }

    function writeQueueJson(idx) {
        if (typeof shell === "undefined" || !shell) return
        var c = buildQueueWriteCmd(idx)
        if (c.length) shell.startDetached(c)
    }

    // 启动常驻播放器的命令行（纯函数，便于无头校验直接断言）。
    // --keep-open=no 是**必需**的，不是可选优化：
    //   /userdisk/mpv/mpv 是包装脚本，它强制 --config-dir=/userdisk/mpv/config，
    //   而那份 mpv.conf 里写着 keep-open = "always"（为视频播放设的）。
    //   keep-open=always 会让 mpv 播完停在最后一帧而不进 idle，播完事件链就断了。
    //   命令行显式指定可覆盖 config（mpv 的 CLI 优先级高于配置文件），实测有效。
    // 【活性判据，不是存在判据】这里绝对不能只写 `[ ! -S sock ]`。
    // mpv 被 SIGKILL（OOM / 手动 kill / 崩溃）时不会 unlink IPC socket，
    // socket 文件会**残留成僵尸**；此时 "-S" 恒为真 ⇒ 播放器永远不再启动，
    // 现象就是「点了播放毫无反应，重启插件也没用」。实际踩过。
    // 正确判据 = socket 存在 **且** 真的有进程在听：用 gdipc.pl 要一次 pid，
    // 拿不到数字 pid 就说明是僵尸 ⇒ 删掉重拉。
    //   - gdipc.pl 连不上会立刻返回（0.2s，Connection refused，exit 3），不会挂住；
    //   - LC_ALL=C 必加：否则 perl 的 locale 警告会混进输出，误判成连通。
    // --demuxer-max-bytes 是 OOM 防线：设备只有 460MB，弱网下 mpv 的预读缓存
    // 实测能涨到 18MB+，足够把系统推向 OOM killer（而受害者就是它自己）。
    // ❗不传 --volume：让它保持 mpv 默认的 100（即完全不衰减），
    // 最终音量由系统侧的 ALSA Master 决定 —— 用户拨系统音量键才管用。
    // 传了就意味着系统音量 × mpv 音量的两级叠乘，系统拉满也只有 80%，体验是"音量键不太灵"。
    function buildEnsurePlayerCmd() {
        return "alive=0; "
             + "if [ -S " + mpvSock + " ]; then "
             + "LC_ALL=C " + shellQuote(ipcScript) + " " + shellQuote(mpvSock)
             + " pid > " + stateDir + "/probe.txt 2>/dev/null; "
             + "if grep -q '^[0-9]' " + stateDir + "/probe.txt 2>/dev/null; then alive=1; fi; "
             + "fi; "
             + "if [ \"$alive\" = 1 ]; then exit 0; fi; "
             + "rm -f " + mpvSock + "; "
             + "mkdir -p " + stateDir + "; "
             + "nohup " + mpvBin
             + " --no-video --force-window=no --idle=yes --keep-open=no"
             + " --demuxer-max-bytes=8MiB"
             + " --input-ipc-server=" + mpvSock
             + " --script=" + luaScript
             + " > /tmp/gdmusic_mpv.log 2>&1 & "
             + "true"
    }

    // 幂等拉起常驻播放器。socket 活着的含义是「上一轮（插件关闭前）留下的播放器
    // 还在后台播放」——这种情况下绝不能重启它，否则歌会断。
    function ensurePlayer() {
        if (typeof shell === "undefined" || !shell) return
        shell.startDetached(buildEnsurePlayerCmd())
    }

    // 给常驻播放器发 script-message 的命令行（纯函数，便于无头校验断言）。
    // 统一在后台等 socket 就绪再发（最多 15 秒）——否则紧跟着冷启动 mpv 发出的命令会丢。
    // 注意：mpv 的 script-message 参数必须全是字符串，所以命令名不带参数。
    function buildScriptMsgCmd(name) {
        return "i=0; while [ $i -lt 60 ]; do "
             + "if [ -S " + mpvSock + " ]; then "
             + "LC_ALL=C " + shellQuote(ipcScript) + " " + shellQuote(mpvSock)
             + " cmd script-message " + name + " >/dev/null 2>&1; break; "
             + "fi; i=$((i+1)); sleep 0.25; done; true"
    }

    function sendScriptMsg(name) {
        if (typeof shell === "undefined" || !shell) return
        shell.startDetached(buildScriptMsgCmd(name))
    }

    function killMpv() {
        if (typeof shell === "undefined" || !shell) return
        // 关键：用 [i]nput-... 的括号写法。否则 pkill 的模式会匹配到执行它的那个
        // sh 自身的命令行（里面含同样字符串），把执行者自己一起杀掉。
        // pkill 发 SIGTERM，mpv 会走 shutdown 让 lua 自己删锁；这里再兜底清一次。
        // ❗必须连 socket 一起删：mpv 被 SIGKILL 时不清理自己的 IPC socket，
        // 留下僵尸文件会让下一次 ensurePlayer 误以为播放器还在（见 buildEnsurePlayerCmd 注释）。
        shell.exec("LC_ALL=C pkill -f '[i]nput-ipc-server=" + mpvSock + "' 2>/dev/null; "
                   + "rm -f " + mpvSock + " " + stateDir + "/probe.txt "
                   + wakeLockFile + " " + nowFile + "; true")
    }

    // 停止播放。真正的动作全在媒体会话桥里（MediaBridge.requestStop）：
    // 发 gd-stop + **当场回收播放器进程** + 把会话转入「保留期」（卡片留在面板上、
    // ▶ 随时能接回；接回时由桥用 ensurePlayer 冷启动播放器）。
    // 这样插件页的停止按钮与面板卡片的 ✕ 行为完全一致。
    function stopPlayback() {
        MediaBridge.requestStop()
        pollTimer.stop()
        playing = false
        paused = true
        timePos = 0
        duration = 0
    }

    function next() {
        if (!queue || !queue.length) return
        if (queueIndex + 1 >= queue.length) { toast.show("已经是最后一首"); return }
        // 推进由 lua 负责（它会重新取流并更新 index），QML 从 now.json 跟随
        sendScriptMsg("gd-next")
        statusText = "切换中…"
        if (!pollTimer.running) pollTimer.restart()
    }

    function prev() {
        if (!queue || !queue.length) return
        if (queueIndex <= 0) { toast.show("已经是第一首"); return }
        sendScriptMsg("gd-prev")
        statusText = "切换中…"
        if (!pollTimer.running) pollTimer.restart()
    }

    function togglePause() {
        if (!playing) {
            // 已停播（或还没开播）→ 从当前曲目重新开播
            if (queue && queue.length) startAt(queueIndex >= 0 ? queueIndex : 0)
            return
        }
        var np = !paused
        paused = np
        mpvCmd(["set_property", "pause", np ? "true" : "false"])
    }

    function seekRatio(r) {
        if (duration <= 0) return
        var t = Math.max(0, Math.min(1, r)) * duration
        timePos = t
        updateLyricIndex()
        mpvCmd(["seek", String(t), "absolute"])
    }

    // ============================================================
    // mpv IPC
    // ============================================================
    function buildIpcCmd(args) {
        var cmd = "LC_ALL=C " + shellQuote(ipcScript) + " " + shellQuote(mpvSock) + " cmd"
        for (var i = 0; i < args.length; i++) cmd += " " + shellQuote(args[i])
        return cmd
    }

    function mpvCmd(args) {
        if (typeof shell === "undefined" || !shell) return
        shell.exec(buildIpcCmd(args))
    }

    // 用 lua 写出的 now.json 同步界面状态。
    // 播放推进（含自动续播、跳过无链接的曲子）全部由 lua 完成，QML 只在
    // 检测到 index 变化时跟随显示 —— 于是「插件开着」与「插件已关」两条路径
    // 下的行为完全一致，不存在两套播放逻辑打架。
    function applyNow(o) {
        if (!o) return
        var st = String(o.status || "")
        var idx = parseInt(o.index, 10)
        playing = (st === "playing" || st === "loading")
        paused  = (st === "paused")
        if (typeof o.pos === "number" && o.pos >= 0) timePos = o.pos
        if (typeof o.dur === "number" && o.dur > 0)   duration = o.dur

        // 曲目变了（用户点播 / 自动续播 / lua 跳过取不到链接的曲子）→ 同步并拉歌词封面
        if (idx >= 1 && idx - 1 !== queueIndex && queue && queue[idx - 1]) {
            queueIndex = idx - 1
            currentSong = queue[idx - 1]
            timePos = 0
            duration = 0
            lyricLines = []
            lyricIndex = -1
            coverUrl = ""
            loadExtras(currentSong)
        }

        if (st === "stopped") {
            var r = String(o.reason || "")
            // 失败原因分两种，别笼统归给"会员"：
            // netease 多是需要会员；而 joox / bilibili 实测 types=url 恒返回空 url
            // （海外服务国内取不到流 / B站取流要登录态），换成"试试网易云"才是真有用的提示。
            statusText = (r === "fail")
                       ? (source === "netease" ? "取不到播放地址（可能需会员）"
                                               : "该音源取不到流，试试网易云")
                       : (r === "user") ? "已停止" : "播放结束"
            playing = false
            paused = true
            timePos = 0
            duration = 0
        } else if (st === "loading") {
            statusText = "解析播放地址…"
        } else if (st === "playing") {
            statusText = ""
        }
        updateLyricIndex()
    }

    // 进插件时接回可能还在后台播放的播放器。
    // 播放不随插件关闭而停止，所以这里是「恢复」而不是「初始化」：
    // 队列从 queue.json 读回，状态从 now.json 读回（并校验新鲜度，避免认了陈旧数据）。
    function reconcile() {
        if (typeof shell === "undefined" || !shell) return
        var dump = ""
        try {
            dump = String(shell.exec("cat " + queueFile + " 2>/dev/null; echo '@@'; "
                                     + "cat " + nowFile + " 2>/dev/null"))
        } catch (e) { dump = "" }
        if (!dump.length) return
        var parts = dump.split("@@")
        var q = null, n = null
        try { q = JSON.parse(String(parts[0] || "").trim()) } catch (e) { q = null }
        try { n = JSON.parse(String(parts[1] || "").trim()) } catch (e) { n = null }

        if (q && q.list && q.list.length) {
            queue = q.list
            queueIndex = (q.index >= 1) ? (q.index - 1) : -1
            // 队列存档里可能带旧音源（joox / bilibili 已从 sources 移除）⇒ 先校验再采纳，
            // 否则 sourceLabel() 会显示一个列表里根本不存在的音源。
            if (q.source && isValidSource(q.source)) source = q.source
            if (q.quality) quality = q.quality
        }
        if (!n) {
            if (queueIndex >= 0 && queue.length) currentSong = queue[queueIndex]
            return
        }
        var fresh = true
        if (typeof n.ts === "number") {
            var age = Date.now() / 1000 - n.ts
            fresh = (age >= -5 && age < 15)
        }
        if (!fresh) {
            if (queueIndex >= 0 && queue.length) currentSong = queue[queueIndex]
            return
        }
        applyNow(n)
        if (playing) { pollTimer.fails = 0; pollTimer.restart() }
    }

    // ============================================================
    // 歌词 / 封面
    // ============================================================
    function parseLrc(text) {
        var out = []
        if (!text) return out
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
            var tags = lines[i].match(/\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]/g)
            if (!tags) continue
            var body = lines[i].replace(/\[[^\]]*\]/g, "").trim()
            if (!body.length) continue
            for (var j = 0; j < tags.length; j++) {
                var m = tags[j].match(/\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/)
                if (!m) continue
                var frac = m[3] ? parseFloat("0." + m[3]) : 0
                out.push({ time: parseInt(m[1], 10) * 60 + parseInt(m[2], 10) + frac, text: body })
            }
        }
        out.sort(function(a, b) { return a.time - b.time })
        return out
    }

    function updateLyricIndex() {
        if (!lyricLines.length) { lyricIndex = -1; return }
        var idx = -1
        for (var i = 0; i < lyricLines.length; i++) {
            if (lyricLines[i].time <= timePos + 0.2) idx = i
            else break
        }
        lyricIndex = idx
    }

    // ============================================================
    // 本地下载（下载到 /userdisk/Music/GDMusic，之后离线可播）
    // ============================================================
    // 文件名里的非法字符必须清掉 —— 设备是 ext4，"/" 会变成子目录，
    // "'" 会打断 shell 单引号，任一项都会让下载写到一个莫名其妙的地方。
    // 纯函数，便于无头校验直接断言。
    function sanitizeName(s) {
        var t = String((s === undefined || s === null) ? "" : s).trim()
        t = t.replace(/[\/\\:\*\?"<>\|\x00-\x1F]/g, "_")
        t = t.replace(/\s+/g, " ")
        if (t.length === 0) t = "untitled"
        if (t.length > 80) t = t.substring(0, 80)
        return t
    }

    // 沿用设备已有习惯：「歌名-歌手.mp3」（歌手有多个时用「、」连接）
    function localNameFor(song) {
        var n = sanitizeName(song && song.name ? song.name : "untitled")
        var a = sanitizeName(song && song.artist ? String(song.artist).replace(/,/g, "、") : "")
        return a.length ? (n + "-" + a + ".mp3") : (n + ".mp3")
    }

    function localPathFor(song) { return downloadDir + "/" + localNameFor(song) }

    function localLrcFor(file) { return String(file || "").replace(/\.[^.]+$/, "") + ".lrc" }

    // ---- sidecar 路径推导（与 localLrcFor 同一个 replace 公式，只是换扩展名）----
    // ⚠️ 这三个函数是**纯函数**（不碰 shell），探针直接断言它们的输出。
    // 存在的意义：mp3 / 封面 / 歌词三者的路径必须**永远同源** ——
    // 一旦各写各的公式，改了命名规则就会只对上一半（这跟 §5.7「复制粘贴只对一半」同类）。
    function sidecarBase(file) { return String(file || "").replace(/\.[^.]+$/, "") }
    function localImgFor(file) { return sidecarBase(file) + sidecarImgExt }

    // 从 API 返回的封面 URL 猜该存成什么扩展名（纯函数，探针可直测）。
    // 只认白名单里的两个；URL 带查询串（?param=500y500）必须先剥掉再取扩展名，
    // 否则会从 "xxx.jpg?param=..." 里截出 ".jpg?param=500y500" 这种废串。
    function imgExtForUrl(url) {
        var s = String(url || "")
        var q = s.indexOf("?")
        if (q >= 0) s = s.substring(0, q)
        var slash = s.lastIndexOf("/")
        if (slash >= 0) s = s.substring(slash + 1)
        var dot = s.lastIndexOf(".")
        if (dot < 0) return sidecarImgExt
        var e = s.substring(dot).toLowerCase()
        return (sidecarImgExts.indexOf(e) >= 0) ? e : sidecarImgExt
    }

    // ============================================================
    // 文件登记表：查询与维护（表本身见顶部 fileMap 属性注释）
    // ============================================================

    // 一首歌的"身份键"。id 为空（本地扫描出来的记录）时返回 "" —— 那种记录本来就不该反查。
    function songKeyOf(song) {
        if (!song || song.id === undefined || song.id === null || String(song.id).length === 0) return ""
        return String(song.source || source) + ":" + String(song.id)
    }

    // 按（在线）歌曲反查已登记的文件路径；没登记返回 ""。
    // 线性扫而不是维护反向索引：本地歌就几十上百首，几百次字符串比较可忽略；
    // 更重要的是**单一数据源**，不会出现"正查命中、反查没有"这种最难查的不一致。
    // 同一首歌被绑了多个文件时取 t 最大（最新）的那个。
    function mappedPathFor(song) {
        var k = songKeyOf(song)
        if (!k.length) return ""
        var best = "", bestT = -1
        for (var p in fileMap) {
            var e = fileMap[p]
            if (!e) continue
            if ((String(e.source || "") + ":" + String(e.id || "")) !== k) continue
            if ((e.t || 0) > bestT) { bestT = (e.t || 0); best = p }
        }
        return best
    }

    // 这条本地记录对应的登记信息；没登记返回 null。
    // ⚠️ 先与 localList 求交再查表：登记表是"路径索引"，文件被外部删/改名后那条就是
    //    悬空的，宁可判为未匹配，也不能凭表去播一个不存在的路径。
    function mapEntryOf(rec) {
        if (!rec || !rec.file) return null
        for (var i = 0; i < localList.length; i++)
            if (localList[i] && localList[i].file === rec.file) return fileMap[rec.file] || null
        return null
    }

    // 登记一条（path 必须非空）。mode: "auto"（下载时自动）/ "manual"（手动匹配）。
    // 只补不删：重新匹配同一首（或同一文件换个 id）就是整体覆盖这一条。
    function mapPut(path, song, mode) {
        if (!path || !song) return
        if (song.id === undefined || song.id === null || String(song.id).length === 0) return
        var m = fileMap
        m[path] = {
            id:       String(song.id),
            source:   String(song.source || source),
            name:     String(song.name || ""),
            artist:   String(song.artist || ""),
            pic_id:   song.pic_id  ? String(song.pic_id)  : "",
            lyric_id: song.lyric_id ? String(song.lyric_id) : String(song.id),
            m:        (mode === "auto") ? "auto" : "manual",
            t:        Math.floor(Date.now() / 1000)
        }
        fileMap = m                  // 整体重新赋值：靠属性变更通知驱动界面刷新
        saveFileMap()
    }

    function mapRemove(path) {
        if (!path || !fileMap[path]) return
        var m = fileMap
        delete m[path]
        fileMap = m
        saveFileMap()
    }

    // 惰性 GC：清掉指向"已不在 localList 里"的条目（文件被外部删/改名了）。
    // 必须在一次**成功的**扫描之后调用。⚠️ localList 为空时**绝不动手** ——
    // 「文件夹真的空了」和「扫描挂了」在输出上无法区分，赌错的代价是清空整张表。
    function gcFileMap() {
        if (!localList.length) return
        var alive = {}, i
        for (i = 0; i < localList.length; i++)
            if (localList[i] && localList[i].file) alive[localList[i].file] = true
        var m = fileMap, drop = 0
        for (var p in m) if (!alive[p]) { delete m[p]; drop++ }
        if (drop > 0) {
            fileMap = m
            saveFileMap()
            console.log("fileMap: GC 清掉 " + drop + " 条悬空登记")
        }
    }

    // ============================================================
    // 歌单（数据层）
    // 全部是**纯数据变换**：不碰 shell、不碰页面状态 ——
    // 于是整段可以在无头环境里抽出来直接断言（见 probe/playlists.sh）。
    // 操作统一返回 { ok, err, id }：用返回码而不是「抛异常 / 静默失败」，
    // 是为了让 UI 能给出**具体**提示（"名字不能为空" vs "最多 20 个歌单"）。
    // ============================================================

    // 歌单条目的去重键：本地条目用文件**绝对路径**、在线条目用 source:id。
    // 两者天然不撞车（路径含 "/"，source:id 不含），所以一个键就能同时管两类歌单。
    function plKeyOf(song) {
        if (!song) return ""
        if (song.file) return String(song.file)
        return songKeyOf(song)          // 复用登记表那套；id 为空时返回 ""
    }

    // 浅拷贝一个队列条目。⚠️ 播歌单时必须拷 —— 队列若直接引用 playlists[i].songs，
    // 之后对歌单的增删（同一个数组对象）会**当场改掉正在播的队列**。
    function copySong(song) {
        var o = {}
        for (var k in song) o[k] = song[k]
        return o
    }

    // 克隆歌单数组的**外层一层**，每个写操作都「克隆 → 改 → 整个赋回去」。
    //
    // 真机实测结论（probe/playlists-device.qml 的对照实验，别凭印象改）：
    //   QML 对 `property var` 赋值时会重算依赖它的绑定 —— **即便赋的是同一个数组引用**。
    //   所以严格说这一步不是必需品（不克隆，歌单页照样刷新）。
    // 保留它是因为「每次写 = 赋一个完整的新数组」这个不变量让调用方不必关心
    //   自己是不是在原地改；而且不依赖"赋同一引用也会重算"这个未文档化的行为
    //   （Qt 版本一变就可能不同，届时的症状是「数据对了、界面不刷新」——最难查的一类）。
    // 代价可以忽略：歌单也就几十个，外层数组拷贝是几十次指针复制。
    // （歌单对象与 songs 数组仍共享引用；它们只被这里改，没有别名风险。
    //   正在播的队列那边靠 copySong 单独隔离。）
    function clonePlaylists() {
        var arr = []
        for (var i = 0; i < playlists.length; i++) arr.push(playlists[i])
        return arr
    }

    // 收敛成合法歌单名；空则返回 ""（调用方据此拒绝）。控制字符与连续空白一并压平，
    // 否则名字里混进换行会把标题栏撑坏。
    function cleanPlaylistName(name) {
        var n = String(name === undefined || name === null ? "" : name)
        n = n.replace(/[\r\n\t]/g, " ").replace(/\s+/g, " ").trim()
        if (n.length > playlistNameMax) n = n.substring(0, playlistNameMax)
        return n
    }

    // 归一化歌单里的**一条歌**；非法返回 null（宁可丢这一条，也不让坏数据流进队列）。
    // type 决定合法形状：online 必须有 id、local 必须有 file ⇒ 队列条目形状恒完整，
    // 播放链路上不需要任何"这条是不是本地歌"的判断。
    function sanitizeSong(raw, type) {
        if (!raw || typeof raw !== "object") return null
        if (type === "local") {
            if (!raw.file) return null
            return { file:   String(raw.file),
                     name:   String(raw.name   || ""),
                     artist: String(raw.artist || ""),
                     size:   Number(raw.size)  || 0 }
        }
        if (raw.id === undefined || raw.id === null || String(raw.id).length === 0) return null
        var s = { id:     String(raw.id),
                  source: String(raw.source || source),
                  name:   String(raw.name   || ""),
                  artist: String(raw.artist || "") }
        if (raw.pic_id)   s.pic_id   = String(raw.pic_id)
        if (raw.lyric_id) s.lyric_id = String(raw.lyric_id)
        return s
    }

    // 归一化一条歌单；非法（无 id / type 不认识）返回 null。
    // songs 逐条过 sanitizeSong 并按去重键去重 —— 手改过的库、或早年版本都可能带重复。
    function sanitizePlaylist(raw) {
        if (!raw || typeof raw !== "object") return null
        var id = String(raw.id || "")
        if (!id.length) return null
        var type = (raw.type === "local") ? "local" : (raw.type === "online" ? "online" : "")
        if (!type.length) return null
        var songs = [], seen = {}
        var src = (raw.songs instanceof Array) ? raw.songs : []
        if (src.length > playlistSongMax)
            console.warn("歌单「" + (raw.name || id) + "」曲目数 " + src.length
                         + " 超过上限 " + playlistSongMax + "，只保留前 " + playlistSongMax + " 首")
        for (var i = 0; i < src.length && songs.length < playlistSongMax; i++) {
            var s = sanitizeSong(src[i], type)
            if (!s) continue
            var k = plKeyOf(s)
            if (!k.length || seen[k]) continue
            seen[k] = true
            songs.push(s)
        }
        // ⚠️ source 必须在这里显式透传：本函数是**重建**对象（不是浅拷贝），
        //    任何没写进来的字段都会在这次归一化里被剥掉。歌单从数据库 load 回来
        //    必经此路 ⇒ 漏了它，"网易云导入"标记重启插件后就没了（存量数据一致，
        //    只有 UI 丢 —— 极难联想到是这里吞的）。
        return { id:      id,
                 name:    cleanPlaylistName(raw.name) || "未命名歌单",
                 type:    type,
                 source:  (raw.source === "netease") ? "netease" : "",
                 created: Number(raw.created) || 0,
                 songs:   songs }
    }

    // 纯函数：解析 kv 里读出的原始文本，**永不抛**。
    // 理由同 filemap —— 一条坏 JSON 不该连坐掉整个 loadSettings
    //（那会连音源、优选 IP 都读不出来，症状看起来完全无关）。
    function parsePlaylists(raw) {
        var out = []
        var v = null
        try { v = JSON.parse(raw) } catch (e) {
            console.warn("playlists 解析失败，按空处理")
            return out
        }
        if (!(v instanceof Array)) return out
        // 正常路径下 createPlaylist 已经拦住了上限，这里超了只可能是手改过库。
        // 不静默截断 —— 少了几个歌单而用户毫不知情是最糟的失败方式。
        if (v.length > playlistMax)
            console.warn("歌单数 " + v.length + " 超过上限 " + playlistMax + "，只载入前 " + playlistMax + " 个")
        for (var i = 0; i < v.length && out.length < playlistMax; i++) {
            var p = sanitizePlaylist(v[i])
            if (p) out.push(p)
        }
        return out
    }

    function playlistIndexById(id) {
        for (var i = 0; i < playlists.length; i++)
            if (playlists[i] && playlists[i].id === id) return i
        return -1
    }
    function playlistById(id) {
        var i = playlistIndexById(id)
        return i < 0 ? null : playlists[i]
    }
    function playlistTypeText(type) { return (type === "local") ? "离线" : "在线" }

    function playlistHasSong(pl, key) {
        if (!pl || !key || !(pl.songs instanceof Array)) return false
        for (var i = 0; i < pl.songs.length; i++)
            if (plKeyOf(pl.songs[i]) === key) return true
        return false
    }

    // 错误码 → 用户能看懂的一句话。UI 直接 toast 它，不自己拼文案。
    function plErrText(err) {
        if (err === "E_NAME")  return "歌单名不能为空"
        if (err === "E_MAX")   return "最多 " + playlistMax + " 个歌单"
        if (err === "E_FULL")  return "单个歌单最多 " + playlistSongMax + " 首"
        if (err === "E_DUP")   return "这首歌已在歌单里"
        if (err === "E_TYPE")  return "歌单类型不符：在线歌单只收在线曲，离线歌单只收已下载的"
        if (err === "E_EMPTY") return "歌单是空的"
        return "操作失败"
    }

    // ---- 增删改 ----
    // 每个操作都「整体重新赋值 playlists」：靠属性变更通知驱动界面刷新，
    // 与 fileMap / localList 的写法保持一致（别原地 mutate 后指望界面自己发现）。

    function createPlaylist(name, type) {
        var n = cleanPlaylistName(name)
        if (!n.length) return { ok: false, err: "E_NAME", id: "" }
        if (type !== "online" && type !== "local") return { ok: false, err: "E_ARG", id: "" }
        if (playlists.length >= playlistMax) return { ok: false, err: "E_MAX", id: "" }
        var id = "pl_" + Date.now()
        // 同一毫秒内连续新建两次时补后缀，保证 id 唯一（删除/重命名都靠它定位）
        while (playlistIndexById(id) >= 0) id += "x"
        var arr = clonePlaylists()
        arr.push({ id: id, name: n, type: type,
                   created: Math.floor(Date.now() / 1000), songs: [] })
        playlists = arr
        savePlaylists()
        return { ok: true, err: "", id: id }
    }

    function renamePlaylist(id, name) {
        var i = playlistIndexById(id)
        if (i < 0) return { ok: false, err: "E_ARG" }
        var n = cleanPlaylistName(name)
        if (!n.length) return { ok: false, err: "E_NAME" }
        var arr = clonePlaylists()
        arr[i].name = n
        playlists = arr
        savePlaylists()
        return { ok: true, err: "" }
    }

    function deletePlaylist(id) {
        var i = playlistIndexById(id)
        if (i < 0) return { ok: false, err: "E_ARG" }
        var arr = []
        for (var k = 0; k < playlists.length; k++) if (k !== i) arr.push(playlists[k])
        playlists = arr
        savePlaylists()
        return { ok: true, err: "" }
    }

    // 上移/下移一个歌单（dir: -1 = 上移，+1 = 下移）。边界是静默 no-op 而不是报错：
    // UI 已经用置灰把「首行上移 / 末行下移」挡掉了，这里再报错只会是「按钮灰着却弹提示」。
    function movePlaylist(id, dir) {
        var i = playlistIndexById(id)
        if (i < 0) return { ok: false, err: "E_ARG" }
        var j = i + (dir > 0 ? 1 : -1)
        if (j < 0 || j >= playlists.length) return { ok: true, err: "" }   // 到边了，不动
        var arr = clonePlaylists()
        var t = arr[i]; arr[i] = arr[j]; arr[j] = t
        playlists = arr
        savePlaylists()
        return { ok: true, err: "" }
    }

    // 判定顺序很重要：先类型（用户加错了歌是最常见的），再重复，最后才是容量 ——
    // 这样"已满"的提示只在真的加不进去时才出现。
    function addSongToPlaylist(id, song) {
        var i = playlistIndexById(id)
        if (i < 0) return { ok: false, err: "E_ARG" }
        var pl = playlists[i]
        if (!pl || !(pl.songs instanceof Array)) return { ok: false, err: "E_ARG" }
        var s = sanitizeSong(song, pl.type)
        if (!s) return { ok: false, err: "E_TYPE" }
        if (playlistHasSong(pl, plKeyOf(s))) return { ok: false, err: "E_DUP" }
        if (pl.songs.length >= playlistSongMax) return { ok: false, err: "E_FULL" }
        var arr = clonePlaylists()
        arr[i].songs.push(s)
        playlists = arr
        savePlaylists()
        return { ok: true, err: "" }
    }

    function removeSongFromPlaylist(id, key) {
        var i = playlistIndexById(id)
        if (i < 0) return { ok: false, err: "E_ARG" }
        var pl = playlists[i]
        if (!pl || !(pl.songs instanceof Array) || !key) return { ok: false, err: "E_ARG" }
        var keep = []
        for (var k = 0; k < pl.songs.length; k++)
            if (plKeyOf(pl.songs[k]) !== key) keep.push(pl.songs[k])
        if (keep.length === pl.songs.length) return { ok: false, err: "E_ARG" }   // 本来就没有
        var arr = clonePlaylists()
        arr[i].songs = keep
        playlists = arr
        savePlaylists()
        return { ok: true, err: "" }
    }

    // 按行号移除（详情页列表用；界面天然持有 index）。
    function removeSongAt(id, idx) {
        var pl = playlistById(id)
        if (!pl || idx < 0 || idx >= pl.songs.length) return { ok: false, err: "E_ARG" }
        return removeSongFromPlaylist(id, plKeyOf(pl.songs[idx]))
    }

    // 播歌单第 index 首。⚠️ 队列必须是**拷贝**（见 copySong 的注释）。
    // 在线歌单的条目在这里保持原样 —— 命中本地由 queueJsonString → resolveEntry 完成，
    // 所以 preferLocal 开关对歌单同样生效，不需要在这里写任何判断。
    function playPlaylist(id, index) {
        var pl = playlistById(id)
        if (!pl || !pl.songs.length) return { ok: false, err: "E_EMPTY" }
        var idx = Math.max(0, Math.min(pl.songs.length - 1, index))
        var list = []
        for (var i = 0; i < pl.songs.length; i++) list.push(copySong(pl.songs[i]))
        queue = list
        page = "player"
        startAt(idx)
        return { ok: true, err: "" }
    }

    // ============================================================
    // 网易云登录（扫码）+ 歌单同步
    // 三段：申请 unikey → 生成二维码 → 轮询状态。全程直连 music.163.com，
    // 唯一外部依赖是第三方 QR 图床（官方二维码图接口已废弃）。
    // ============================================================

    // 纯函数：解析轮询 check 的响应，返回状态码（800/801/802/803/其他）。
    function ncParseCheckCode(txt) {
        var o = null
        try { o = JSON.parse(txt) } catch (e) { return -1 }
        if (!o || typeof o.code === "undefined") return -1
        return Number(o.code)
    }

    // 纯函数：从登录 check 成功响应里提取 cookie。响应体可能直接带 cookie 字段，
    // 也可能为空（cookie 在 Set-Cookie 头，靠 jar 抓）。这里做防御：两者都读。
    function ncExtractCookie(txt) {
        var o = null
        try { o = JSON.parse(txt) } catch (e) { o = null }
        if (o && typeof o.cookie === "string" && o.cookie.length) return o.cookie
        return ""
    }

    // 纯函数：把网易云歌单详情里的 trackIds + 歌名数组 映射成插件在线歌单的 songs。
    // detail = { name, tracks: [{id,name,ar:[{name}]}] }（song/detail 的返回）
    function ncMapSongs(detail) {
        var out = []
        if (!detail || !(detail.tracks instanceof Array)) return out
        for (var i = 0; i < detail.tracks.length; i++) {
            var t = detail.tracks[i]
            if (!t || !t.id) continue
            var artist = ""
            if (t.ar instanceof Array) {
                var names = []
                for (var a = 0; a < t.ar.length; a++)
                    if (t.ar[a] && t.ar[a].name) names.push(t.ar[a].name)
                artist = names.join("、")
            }
            var s = { id: String(t.id), source: "netease", name: String(t.name || ""), artist: artist }
            if (t.al && t.al.picUrl) {
                // picUrl 形如 .../xxxx.jpg，末尾 14 位数字是 pic_id（正是 GD 的 pic_id）
                var m = String(t.al.picUrl).match(/(\d{10,})\.(?:jpg|png)$/i)
                if (m) s.pic_id = m[1]
            }
            out.push(s)
        }
        return out
    }

    // 纯函数：从 user/playlist 返回里筛出"用户自己的歌单"（subscribed=false 才是本人建的），
    // 返回 [{id, name, count}]。收藏的歌单（subscribed=true）也同步会噪音很大，先只同步本人建的。
    function ncFilterOwnPlaylists(txt) {
        var out = []
        var o = null
        try { o = JSON.parse(txt) } catch (e) { return out }
        if (!o || !(o.playlist instanceof Array)) return out
        for (var i = 0; i < o.playlist.length; i++) {
            var p = o.playlist[i]
            if (!p) continue
            if (p.subscribed === true) continue        // 只同步本人建的，收藏的跳过
            out.push({ id: String(p.id), name: String(p.name || ""), count: Number(p.trackCount) || 0 })
        }
        return out
    }

    // 开始扫码登录：申请 unikey → 生成二维码。
    //
    // ⚠️ ncQrStamp 必须在**图片落盘之后**才能递增（ncQrWaitImg 回调里），不能在申请
    // unikey 之前就加。踩过的坑：早先在 ncPost 之前 ncQrStamp++，此时新码还没开始下载，
    // 登录页 Image 换 source 后读到的是**上一次的旧 PNG**，之后再无 source 变化 ⇒
    // 界面一直显示旧码，用户扫了必然「二维码已失效」（unikey 本身却是好的，服务端仍返 801）。
    // 症状与"码过期"几乎一样，判据是**解码 PNG 里的 codekey 与当前 ncUnikey 是否一致**。
    function ncStartLogin() {
        if (typeof shell === "undefined" || !shell) { ncPhase = "error"; return }
        // 🔴 重入守卫：ncStartLogin 可能被连续触发（onVisibleChanged 进页 + 用户点刷新 +
        //    离页再进页）。没有守卫时两次调用会**并发**申请两个 unikey、并发 curl 写
        //    同一个 PNG 路径，后落盘的那张码与 ncUnikey 对不上 ⇒ 用户扫码授权的是 A 的码，
        //    插件却轮询 B 的 key ⇒ 永远 801，界面还显示"等待扫码"，零异常表现。
        //    实测踩过：23:56:13 申请 45206508、23:56:18 申请 71b6ab0a，屏上码是前者。
        // 🔴 冷却中禁止重新申请：已经触发限频时再猛点刷新，只会让风控窗口更长。
        //    实测踩过：4 秒内连点刷新 ⇒ 4 个 unikey，紧接着服务端开始返回 8821。
        if (ncCooldown > 0) return
        if (ncStarting) return
        ncStarting = true
        ncFail = 0
        ncPhase = "idle"
        ncUnikey = ""
        ncQrFile = ""                 // 先清空：旧码立即下屏，避免用户扫到上一次的
        // 先把 os=pc / appver 种进 cookie jar：后续每次轮询 -b 都会带上，
        // 让请求看起来像网易云的第三方客户端而不是裸脚本。纯本地写文件，同步执行安全。
        try { shell.exec(buildNcSeedJarCmd(ncJarPath())) } catch (e) {}
        ncPost("/api/login/qrcode/unikey", "type=1", function(ok, txt) {
            ncStarting = false
            if (!ok) { ncPhase = "error"; return }
            var o = null
            try { o = JSON.parse(txt) } catch (e) { o = null }
            if (!o || !o.unikey) { ncPhase = "error"; return }
            ncUnikey = String(o.unikey)
            // 二维码文件名**带 unikey 前缀**：不同 unikey 落到不同文件，
            // 这样即使有上一次残留的 curl 还在跑，也不会互相覆盖（同一路径并发 rm+写
            // 是上面那个 bug 的机制）。unikey 首 8 位足够区分，又不会让路径过长。
            var img = "/tmp/gdmusic_ncqr_" + ncUnikey.substring(0, 8) + ".png"
            ncWaitImg(img, function(got) {
                // 回调可能属于一个已被新登录取代的旧 unikey —— 只认当前这次的
                if (ncUnikey.substring(0, 8) !== img.substring(img.length - 12, img.length - 4))
                    return
                if (!got) { ncPhase = "error"; return }
                ncQrFile = img        // 路径本身就是新的 ⇒ 不再需要 cache-bust 时间戳
                ncPhase = "waiting"
                ncPollTimer.restart()
            })
        })
    }

    // 轮询等二维码图片下载完成。走 apiPending/apiPollTimer 那套 token 机制，
    // 完成信号 = 单独的 .done 文件出现（命令末尾写入），避免"命令返回 ≠ 文件写完"。
    // needsBody=false：这个请求的产物就是 token 本身（.done 里没有正文），
    // 不能按 body 长度判成功，否则会被 apiPoll 判成失败。
    function ncWaitImg(img, cb) {
        if (typeof shell === "undefined" || !shell) { cb(false); return }
        apiSeq++
        var key = "" + apiSeq
        var done = "/tmp/gdmusic_ncqr_" + key + ".done"
        var token = "GDDONE" + key + "Z"
        apiPending[key] = { cb: function(ok) { cb(ok) }, out: done, token: token, t0: Date.now(), needsBody: false }
        shell.startDetached(buildNcQrWaitCmd(img, done, token))
        apiPollTimer.restart()
    }

    // 离页时停轮询（LoginPage.onVisibleChanged 调用）。
    function ncStopPoll() { ncPollTimer.stop() }

    // cookie jar 路径（轮询 -c/-b 与种初始 cookie 共用，避免两处各写一份）。
    function ncJarPath() { return "/tmp/gdmusic_nc_cookie.jar" }

    // 轮询扫码状态。
    function ncPoll() {
        if (ncPhase !== "waiting" && ncPhase !== "scanned") { ncPollTimer.stop(); return }
        if (!ncUnikey.length) { ncPollTimer.stop(); return }
        var jar = ncJarPath()
        var path = "/api/login/qrcode/client/login?key=" + encodeURIComponent(ncUnikey) + "&type=1"
        // check 要用 -c/-b 抓 Set-Cookie，所以单独走 buildNcCheckCmd。
        if (typeof shell === "undefined" || !shell) { ncPollTimer.stop(); return }
        apiSeq++
        var key = "" + apiSeq
        var out = "/tmp/gdmusic_api_" + key + ".out"
        var token = "GDDONE" + key + "Z"
        apiPending[key] = { cb: function(ok, txt) { ncOnPoll(ok, txt, jar) }, out: out, token: token, t0: Date.now() }
        shell.startDetached(buildNcCheckCmd("https://music.163.com" + path, jar, out, token))
        apiPollTimer.restart()
    }

    function ncOnPoll(ok, txt, jar) {
        if (!ok) return
        var code = ncParseCheckCode(txt)
        if (code === 800) { ncPhase = "expired"; ncPollTimer.stop() }
        else if (code === 801) { ncPhase = "waiting"; ncFail = 0 }
        else if (code === 802) { ncPhase = "scanned"; ncFail = 0 }
        else if (code === 803) {
            ncPhase = "done"
            ncPollTimer.stop()
            ncOnLoginSuccess(txt, jar)
        } else if (code > 0) {
            // 🔴 白名单之外的**任何** code 都是服务端在拒绝 —— 实测最常见的是
            //    8821「请切换其他登录方式或升级新版本再试」= **频率风控**。
            //    老实现在这里写的是"其它 code 不动，等下一拍重试"，于是：
            //      界面继续显示"请用手机网易云 App 扫码" + 2 秒一次的轮询不停
            //      ⇒ 风控永不解除 + 用户零感知 ⇒ 就是"扫码授权完没反应"。
            //    所以必须停轮询、进冷却、把原因显示出来。
            ncRisk(code)
        } else {
            // -1 = 解析失败（空响应/网络抖动），这不是服务端拒绝，容忍几次。
            ncFail++
            if (ncFail >= 3) { ncPhase = "error"; ncPollTimer.stop() }
        }
    }

    // 服务端拒绝（限频风控等）：停轮询 + 冷却，并把原因写到界面。
    function ncRisk(code) {
        ncPollTimer.stop()
        ncPhase = "risk"
        ncRiskMsg = "网易云限频（" + code + "），请稍后再试"
        ncCooldown = ncCoolSec
        ncCoolTimer.restart()
    }

    // 登录成功：先从 jar 读 cookie（Set-Cookie 已存进去），再查 account/get 拿 uid/nick。
    function ncOnLoginSuccess(txt, jar) {
        // 响应体里可能直接给 cookie；否则从 jar 文件读（curl -c 存的 Netscape 格式）。
        var ck = ncExtractCookie(txt)
        if (!ck.length) {
            ck = ncReadJar(jar)
        }
        if (ck.length) {
            ncCookie = ck
            ncSaveCookie()
        }
        ncFetchAccount()
    }

    // 从 curl -c 的 jar（Netscape cookie 格式）读回 Cookie 头。纯函数（输入 jar 文本）。
    function ncJarToCookie(jarText) {
        var parts = []
        var lines = String(jarText || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim()
            if (!ln.length || ln.charAt(0) === "#") continue
            var f = ln.split("\t")
            if (f.length < 7) continue
            parts.push(f[5] + "=" + f[6])
        }
        return parts.join("; ")
    }

    // 读设备上的 jar 文件（异步，回读后走 account/get）。
    function ncReadJar(jar) {
        // jar 是 curl 写设备 /tmp 的，得靠 shell 读回来。失败静默（cookie 可能已从响应体拿到）。
        if (typeof shell === "undefined" || !shell) return ""
        var txt = ""
        try { txt = String(shell.exec("cat " + shellQuote(jar) + " 2>/dev/null; true")) } catch (e) { txt = "" }
        return ncJarToCookie(txt)
    }

    // 登录后拉 uid + 昵称（也是"登录态是否有效"的判据）。
    function ncFetchAccount() {
        ncGet("/api/nuser/account/get", function(ok, txt) {
            if (!ok) { ncPhase = "error"; return }
            var o = null
            try { o = JSON.parse(txt) } catch (e) { o = null }
            if (o && o.account && o.account.id) {
                ncUid = String(o.account.id)
                ncNick = (o.profile && o.profile.nickname) ? String(o.profile.nickname) : ""
                ncSaveCookie()
            } else {
                // 有 cookie 但 account 为空 ⇒ cookie 无效/过期
                ncCookie = ""
                ncSaveCookie()
                ncPhase = "error"
            }
        })
    }

    // 退出登录：清 cookie 与身份，同步来的歌单保留（用户攒下的资产不清）。
    function ncLogout() {
        ncCookie = ""
        ncUid = ""
        ncNick = ""
        ncPhase = "idle"
        ncUnikey = ""
        ncPollTimer.stop()
        ncSaveCookie()
    }

    // 同步网易云歌单到插件歌单库（登录后手动触发）。
    // 流程：user/playlist 拉本人歌单 → 逐个 v6/playlist/detail 取 trackIds →
    //       song/detail?ids 批量取歌名/歌手/pic_id → 映射成在线歌单，merge 进 playlists。
    function ncSyncPlaylists() {
        if (!ncCookie.length && !ncUid.length) { ncSyncMsg = "请先登录"; return }
        if (ncSyncing) return
        ncSyncAbort = false
        ncSyncRetry = null
        ncSyncing = true
        ncSyncMsg = "拉取歌单列表…"
        ncGet("/api/user/playlist?uid=" + encodeURIComponent(ncUid) + "&limit=1000&offset=0", function(ok, txt) {
            if (ncSyncAbort) { ncSyncDone([], "已取消"); return }
            if (!ok) { ncSyncing = false; ncSyncMsg = "拉取歌单失败（网络？）"; return }
            var own = ncFilterOwnPlaylists(txt)
            if (!own.length) { ncSyncing = false; ncSyncMsg = "没有可同步的歌单"; return }
            // 先回填来源标记：**早先同步进来的那批**入库时还没有 source 字段，
            //    不补的话"只有这次新拉的才有网易云标记、老的一批没有"，
            //    用户会以为标记坏了。按 id 匹配（网易云歌单 id 就是插件里的歌单 id）。
            ncMarkSyncedSource(own)
            ncSyncMsg = "共 " + own.length + " 个歌单，开始拉取…"
            ncSyncNext(own, 0, [], 0)
        })
    }

    // 给「已经躺在本地歌单库里、但还没打来源标记」的网易云歌单补 source。
    // 判据是 id 相等：同步入库时歌单 id 直接用的是网易云歌单 id。
    // ⚠️ 只有这一次是"就地改对象"（与其它写操作 clone + 整体赋值不同）：
    //    这里要改的是**存量对象上的一个新字段**，逐个重建反而容易漏字段；
    //    改完仍整体重新赋值 playlists 触发绑定，界面一定看得到。
    function ncMarkSyncedSource(own) {
        if (!(own instanceof Array) || !own.length) return
        var arr = clonePlaylists()
        var changed = 0
        for (var i = 0; i < arr.length; i++) {
            var pl = arr[i]
            if (!pl || pl.source === "netease") continue
            for (var k = 0; k < own.length; k++) {
                if (own[k] && own[k].id === pl.id) { pl.source = "netease"; changed++; break }
            }
        }
        if (changed > 0) { playlists = arr; savePlaylists() }
    }

    // 用户取消：只置标志，当前这一拍的请求跑完自然在下一拍收尾（不能真杀后台 curl）。
    function ncCancelSync() {
        if (!ncSyncing) return
        ncSyncAbort = true
        ncSyncRetry = null
        ncSyncMsg = "正在取消…"
    }

    // ncSyncNext 的实体（带 tries：限频退避后重试同一歌单的次数）。
    function ncSyncNext(own, i, acc, tries) {
        if (ncSyncAbort) { ncSyncDone(acc, "已取消"); return }
        if (i >= own.length) { ncSyncDone(acc, ""); return }
        var p = own[i]
        ncSyncMsg = "歌单 " + (i + 1) + "/" + own.length + "「" + (p.name || p.id) + "」…"
        // n = playlistSongMax：反正只存这么多首，多拉的部分既没用又白增响应体
        // （实测这个 n 真的控制返回条数：n=10 回 61KB、n=300 回全量 515KB；
        //   响应体每大 1MB，apiPoll 的同步回读就多按住主线程几百毫秒）。
        ncGet("/api/v6/playlist/detail?id=" + encodeURIComponent(p.id) + "&n=" + playlistSongMax, function(ok, txt) {
            if (ncSyncAbort) { ncSyncDone(acc, "已取消"); return }
            var o = null
            try { o = JSON.parse(txt) } catch (e) { o = null }

            // 🔴 限频（406/405「操作频繁」）必须**看得见 + 退避**，不能静默跳过：
            //    旧实现只判断 "有没有 trackIds"，限频响应 parse 出来 songs 为空，
            //    于是整首歌单被当成"空歌单"丢掉，界面却还停在"拉取「xxx」"不动。
            //    实测两种码都见过：406（歌单接口）、405（song/detail 探测时）。
            var code = (o && o.code !== undefined) ? Number(o.code) : -1
            var limited = (code === 406 || code === 405)
            if (!ok || (code !== 200 && code !== -1)) {
                if (limited && tries < 1) {
                    ncSyncMsg = "网易云限频，稍等 5 秒重试…"
                    ncSyncRetry = { own: own, i: i, acc: acc, tries: tries + 1 }
                    ncSyncRetryTimer.restart()
                    return
                }
                ncSyncMsg = (limited ? "被限频，" : "") + "「" + (p.name || p.id) + "」拉取失败，跳过"
                ncSyncNext(own, i + 1, acc, 0)
                return
            }

            // ✅ 首选路径：detail 响应里**本来就带完整 tracks**（实测 205 首歌单，
            //    tracks 里有全部 205 首的 name/歌手/封面 picUrl），一次请求拿全，
            //    不再需要 song/detail 每 4 首一次地反复请求（那个老路径一个歌单就要
            //    50+ 次请求，十几个歌单 ⇒ 上千次请求，界面几分钟不动 + 必然触发 406）。
            var songs = (o && o.playlist) ? ncMapSongs(o.playlist) : []
            if (songs.length) {
                acc.push({ id: p.id, name: p.name, type: "online", songs: songs })
                ncSyncNext(own, i + 1, acc, 0)
                return
            }

            // 回退路径：个别歌单 detail 只给 trackIds（无 tracks）时才走 song/detail 分批。
            var trackIds = []
            if (o && o.playlist && o.playlist.trackIds instanceof Array) {
                for (var t = 0; t < o.playlist.trackIds.length && trackIds.length < playlistSongMax; t++)
                    if (o.playlist.trackIds[t] && o.playlist.trackIds[t].id)
                        trackIds.push(String(o.playlist.trackIds[t].id))
            }
            if (!trackIds.length) { ncSyncNext(own, i + 1, acc, 0); return }
            ncFetchSongBatch(p, trackIds, 0, [], function(s) {
                acc.push({ id: p.id, name: p.name, type: "online", songs: s })
                ncSyncNext(own, i + 1, acc, 0)
            })
        })
    }

    // 限频退避：等 5 秒再重试同一歌单（只重试一次，仍失败就跳过）。
    function ncSyncDoRetry() {
        var r = ncSyncRetry
        ncSyncRetry = null
        if (!r) return
        ncSyncNext(r.own, r.i, r.acc, r.tries)
    }

    // 分批拉歌名（song/detail 一次 4 首）。chunks 是已分好的 4 首一组。
    function ncFetchSongBatch(p, ids, bi, out, done) {
        var chunks = []
        for (var c = 0; c < ids.length; c += 4) chunks.push(ids.slice(c, c + 4))
        ncFetchSongChunks(chunks, 0, out, done)
    }

    function ncFetchSongChunks(chunks, ci, out, done) {
        if (ci >= chunks.length) { done(out); return }
        var idsStr = chunks[ci].join(",")
        ncGet("/api/song/detail/?ids=" + encodeURIComponent("[" + idsStr + "]"), function(ok, txt) {
            if (ok) {
                var o = null
                try { o = JSON.parse(txt) } catch (e) { o = null }
                var mapped = ncMapSongs({ tracks: (o && o.songs) ? o.songs : [] })
                for (var m = 0; m < mapped.length; m++) out.push(mapped[m])
            }
            ncFetchSongChunks(chunks, ci + 1, out, done)
        })
    }

    // 同步收尾：把已拿到的入库并给出明确结论。取消/失败也算收尾，不留 ncSyncing=true
    // 的悬空状态（那会让登录页按钮永久停在「同步中…」，看起来就是"卡死退不出去"）。
    function ncSyncDone(acc, note) {
        ncSyncing = false
        ncSyncAbort = false
        ncSyncRetry = null
        ncMergeSynced(acc || [])
        if (note.length) ncSyncMsg = note + (acc.length ? ("（已入库 " + acc.length + " 个）") : "")
        else if (acc.length) toastMsg("已同步 " + acc.length + " 个歌单")
    }

    // 把同步来的歌单 merge 进 playlists（按 id 覆盖或新增），落盘。
    function ncMergeSynced(synced) {
        if (!synced || !synced.length) { ncSyncMsg = "没有拉到歌单"; return }
        var arr = clonePlaylists()
        for (var i = 0; i < synced.length; i++) {
            var np = synced[i]
            if (!np || !np.songs.length) continue
            var existing = -1
            for (var k = 0; k < arr.length; k++)
                if (arr[k].id === np.id) { existing = k; break }
            // source="netease" = 「这是从网易云同步来的」标记，界面据此显示来源徽标。
            //   注意它会**覆盖**同名同 id 的手建歌单（同步就是按 id 覆盖），覆盖后
            //   该歌单也算网易云来源 —— 语义正确：它的内容确实来自网易云。
            var pl = { id: np.id, name: np.name, type: "online", source: "netease",
                       created: Date.now(),
                       songs: np.songs.slice(0, playlistSongMax) }
            if (existing >= 0) arr[existing] = pl
            else arr.push(pl)
        }
        playlists = arr
        savePlaylists()
        ncSyncMsg = "已同步 " + synced.length + " 个歌单"
    }

    // 轮询定时器。⚠️ 3s 一拍而不是 2s：实测 2s + 多次重刷二维码会让网易云返回
    // 8821（频率风控），一旦触发整个登录链路会静默失效好几分钟。
    // 802（已扫待确认）时加快到 1s，那一步用户正在等，跟手更重要。
    Timer {
        id: ncPollTimer
        interval: (ncPhase === "scanned") ? 1000 : 3000
        repeat: true
        running: false
        onTriggered: root.ncPoll()
    }

    // 同步限频退避：遇到 406 等 5 秒再续，别原地猛打（猛打只会让限频更久）。
    Timer {
        id: ncSyncRetryTimer
        interval: 5000
        repeat: false
        running: false
        onTriggered: root.ncSyncDoRetry()
    }

    // 风控冷却倒计时：1s 减一格，归零后自动放行（允许用户重新获取二维码）。
    Timer {
        id: ncCoolTimer
        interval: 1000
        repeat: true
        running: false
        onTriggered: {
            if (ncCooldown > 0) ncCooldown--
            if (ncCooldown <= 0) {
                stop()
                // 冷却结束：转成 expired，界面自然显示"点下方刷新"
                if (ncPhase === "risk") ncPhase = "expired"
            }
        }
    }

    // ---- 界面层辅助：数据层 → UI 的最后一跳 ----
    // 放在这里而不是写进页面：页面拿 .qml 文件访问不到 main.qml 的 toast / keyboard
    //（QML 的 id 作用域是单文件内），所以一律由 controller 转发，与 openMatch 那套一致。

    // 磁盘上找这首歌的本地文件，返回扫描记录（找不到返回 null）。
    //
    // ⚠️ 与 preferLocal **无关** —— 这是个事实判断（"文件在不在"），不是偏好判断。
    //    两个用途必须分开，混用会出真 bug：
    //      · localFileOf → 回答"点下去会不会走本地"（受"已下载优先"开关影响，用于 ✓ 徽标）
    //      · localRecOf  → 回答"本地有没有这个文件"（用于"能不能加进离线歌单"）
    //    拿 localFileOf 当后者用，用户一关"已下载优先"，所有歌就都加不进离线歌单了。
    // 判据里含 minLocalBytes：离线歌单要保证"加进去就播得出来"，
    // 半截/坏文件加进去只会变成一个点下去报错的条目。
    function localRecOf(song) {
        if (!song) return null
        if (song.file) {
            // 本来就是本地条目：仍要与 localList 求交（扫文件夹才是磁盘真源）——
            // 否则"文件已被外部删掉"的条目会一直显示成能加。
            for (var j = 0; j < localList.length; j++)
                if (localList[j] && localList[j].file === song.file) return localList[j]
            return null
        }
        var rec = findLocal(song)
        if (!rec) return null
        if ((rec.size || 0) < minLocalBytes) return null
        return rec
    }

    // 把一首歌变成"加歌单用的载体"：**两种形态都带上**。
    //   · 在线形态 id/source/pic_id/lyric_id —— 在线歌单要的
    //   · 本地形态 file/size               —— 离线歌单要的
    // 由 addSongToPlaylist → sanitizeSong(song, pl.type) 各取所需、自动剥掉多余字段，
    // 所以界面完全不需要"这条能不能加"的预判 —— 那会让同一套类型规则在界面里再写一遍。
    function addTargetOf(song) {
        if (!song) return null
        var o = copySong(song)
        // 正向：在线歌 → 补本地文件（已下载的话）
        if (!o.file) {
            var rec = localRecOf(song)
            if (rec) {
                o.file = String(rec.file)
                if (!(o.size > 0)) o.size = Number(rec.size) || 0
            }
        }
        // 反向：本地条目 → 补网易云身份。不补的话它只能进离线歌单，
        // 而"我下载过的这首在网易云歌单里也有"恰恰是很常见的情况。
        // 登记表（fileMap）就是为这件事存在的，这里只是把它用起来。
        if (o.file && !o.id) {
            var e = mapEntryOf({ file: o.file })
            if (e && e.id) {
                o.id     = e.id
                o.source = e.source || source
                if (e.pic_id)   o.pic_id   = e.pic_id
                if (e.lyric_id) o.lyric_id = e.lyric_id
                if (e.name)     o.name     = e.name
                if (e.artist)   o.artist   = e.artist
            }
        }
        return o
    }

    // 这个载体能不能进某一类型的歌单（新建歌单那一步用它灰掉不可选的类型）。
    function addTargetFits(song, type) { return !!sanitizeSong(song, type) }

    // 详情页的「本地命中」徽标。用 resolveEntry 而不是 findLocal：两者判据不同 ——
    // resolveEntry 额外要求文件 ≥ minLocalBytes，而徽标要回答的正是
    // "点下去会不会真的走本地"，用 findLocal 会显示成 ✓ 却仍然联网（自相矛盾）。
    // 对本地条目（本来就带 file）它原样返回自己的文件，所以同一支能同时管两类。
    function localFileOf(song) {
        var e = resolveEntry(song)
        return (e && e.file) ? String(e.file) : ""
    }

    // { ok, err } 结果码 → 一句提示。成功返回 true，让调用方能接着做下一步。
    function plToast(res) {
        if (!res || res.ok) return true
        toast.show(plErrText(res.err))
        return false
    }

    function playPlaylistUI(id, index) { return plToast(playPlaylist(id, index)) }

    function removeSongAtUI(id, idx) {
        if (!plToast(removeSongAt(id, idx))) return false
        toast.show("已从歌单移除")
        return true
    }

    // 新建歌单：先选类型，再弹宿主输入页让用户打名字。
    // 上限在这里先拦一次：让用户在**打名字之前**就知道满了，而不是打完才被拒。
    // song 可选：从「加入歌单」页新建时传进来，建完由 onKeyboardAccepted 一并把它加进去。
    function beginCreatePlaylist(type, song) {
        if (type !== "online" && type !== "local") return
        if (playlists.length >= playlistMax) { toast.show(plErrText("E_MAX")); return }
        plNewType = type
        plNewSong = (song === undefined) ? null : song
        keyboard.open("")
        editTarget = "plName"
    }

    // 重命名：预填**当前名**（用户多是改一两个字，预填比全删重打省事）。
    // 目标 id 存 plRenameId，回填走 onKeyboardAccepted 的 "plRename" 分支。
    function beginRenamePlaylist(id) {
        var pl = playlistById(id)
        if (!pl) { toast.show("歌单不存在"); return }
        plRenameId = id
        keyboard.open(pl.name)
        editTarget = "plRename"
    }

    // 删除歌单：二次确认在页面里做（行内变身，见 PlaylistPage），
    // 这里只负责真正删。删的是歌单本身，不碰歌单里的歌（那些是 mp3/在线条目，各有归属）。
    function deletePlaylistUI(id) {
        if (!plToast(deletePlaylist(id))) return false
        toast.show("已删除歌单")
        return true
    }

    // 上移/下移。返回 plToast 的布尔：UI 据此知道要不要重绘（其实重赋值已触发，这里只吃错误提示）。
    function movePlaylistUI(id, dir) { return plToast(movePlaylist(id, dir)) }

    // ============================================================
    // 「加入歌单」页（page === "addpick"）
    // ============================================================

    // 打开加歌页。song 可以是搜索结果的在线歌、本地列表的一条、或播放页正在播的那首 ——
    // 由 addTargetOf 统一补成"两种形态都在"的载体。
    // ⚠️ backPage 记的是**当前**页：从详情页长按进来的要回详情页、从搜索页进来的回搜索页。
    function openAddPick(song) {
        var t = addTargetOf(song)
        if (!t || (!t.file && !t.id)) { toast.show("这首歌没有可保存的信息"); return }
        addPickSong = t
        addPickStep = "list"
        // ⚠️ 已经在加歌页里再开一次时**不要**覆盖 backPage。
        //    那样它会被写成 "addpick"，之后「关闭」永远是回到本页 ——
        //    症状是「怎么按返回都出不去这个页面」，而且只在特定操作顺序下出现，
        //    极难复现定位。允许的入口本来就只有一个（从别的页长按 / 播放页 ＋），
        //    所以"已经在本页"只可能是重复调用，跳过记 backPage 一定是对的。
        if (page !== "addpick") backPage = page
        page = "addpick"
    }

    function closeAddPick() {
        addPickSong = null
        addPickStep = "list"
        plNewSong = null
        page = backPage
    }

    // 页面只传歌单 id：用哪种形态（在线 id / 本地 file）由数据层按歌单类型挑，
    // 界面不需要、也不应该自己判断这些（判断写两份就会有两套不一致的规则）。
    function doAddPick(id) {
        var pl = playlistById(id)
        if (!pl) { toast.show("歌单不存在"); return }
        var res = addSongToPlaylist(id, addPickSong)
        if (!res.ok) { toast.show(plErrText(res.err)); return }
        toast.show("已加入「" + pl.name + "」")
        closeAddPick()
    }

    // 从加歌页新建：先按"这首歌能不能进去"拦一道，再走通用的新建流程。
    function beginCreateFromPick(type) {
        if (!addTargetFits(addPickSong, type)) { toast.show("这首歌不适合该类型"); return }
        beginCreatePlaylist(type, addPickSong)
    }

    // 找本地文件：两级查找。
    // ① 精确路径 —— 下载与命名同源（都走 localPathFor），置信度最高，保留原有行为；
    // ② 登记表反查 —— 覆盖「改过名 / 别的工具下载的」这两种公式覆盖不到的情况。
    // 两级都要与 localList 求交：localList 是磁盘的真源，表只是个索引。
    function findLocal(song) {
        if (!song) return null
        var f = localPathFor(song), i
        for (i = 0; i < localList.length; i++)
            if (localList[i] && localList[i].file === f) return localList[i]
        var p = mappedPathFor(song)
        if (p.length)
            for (i = 0; i < localList.length; i++)
                if (localList[i] && localList[i].file === p) return localList[i]
        return null
    }

    function isDownloaded(song) { return findLocal(song) !== null }

    // ============================================================
    // 已下载优先（preferLocal）—— 写队列前的最后一道解析
    // ============================================================
    // 关键是**给在线条目补一个 file 字段**，而不是把它替换成一个本地对象：
    //   · lua 见 file 即 loadfile，完全不碰网络（gdnext.lua 的 play_index 分支）
    //   · id / source / pic_id / lyric_id 全部保留 ⇒ 封面仍可按 pic_id 联网取，
    //     歌词则自动落到本地同名 .lrc（fetchLyric 里 `if (song.file)` 那一支）
    //   ⇒ 三条支路各自落在正确的一边，不需要任何额外的分支判断。
    //
    // 匹配是**精确**的：localPathFor() 用的就是下载时写文件的同一个公式（localNameFor），
    // 所以不存在「匹配到同名翻唱/别的版本」的风险。代价是：在文件管理器里改过名的
    // 文件匹配不上 —— 那种情况老实走网络即可。
    // 纯函数，探针可直接断言（见 probe/preferlocal.sh）。
    function resolveEntry(song) {
        if (!song) return song
        if (song.file) return song                  // 已经是本地条目，原样放行
        if (!preferLocal) return song
        var rec = findLocal(song)
        if (!rec) return song
        if ((rec.size || 0) < minLocalBytes) return song    // 半截/坏文件，不认
        var out = {}
        for (var k in song) out[k] = song[k]         // 手写浅拷贝：QML 引擎未必有 Object.assign
        out.file = rec.file
        return out
    }

    function dlStatus(song) {
        return (song && dlState[song.id]) ? dlState[song.id] : ""
    }

    // 百分比：total 未知（HEAD 拿不到 Content-Length）返回 -1，UI 退化成只显示字节
    function pctOf(e) {
        if (!e || !(e.total > 0)) return -1
        var p = Math.floor((e.got || 0) * 100 / e.total)
        return (p > 100) ? 100 : p
    }

    // 队列视图快照：正在下的排最前，后面按排队顺序。每次状态变化/轮询后重建。
    readonly property int    dlActiveCount: dlQueueView.length
    readonly property string dlTabLabel: "本地" + (dlQueueView.length ? "(↓" + dlQueueView.length + ")" : "")

    function refreshQueueView() {
        var order = []
        if (dlRunning !== "" && dlPending[dlRunning]) order.push(dlRunning)
        for (var i = 0; i < dlQueue.length; i++)
            if (dlPending[dlQueue[i]]) order.push(dlQueue[i])
        var arr = []
        for (var j = 0; j < order.length; j++) {
            var e = dlPending[order[j]]
            arr.push({
                key: order[j], id: e.id,
                name: (e.song && e.song.name) ? e.song.name : "",
                running: order[j] === dlRunning,
                pct: pctOf(e), got: e.got || 0, total: e.total || -1, msg: e.msg || ""
            })
        }
        dlQueueView = arr
    }

    // .meta 记住这首歌是谁 —— 插件页关掉后下载还在后台跑（startDetached），
    // 重开插件时 dlRecover 靠它把任务认回来，进度不至于「凭空消失又从头下」。
    function buildMetaCmd(metaFile, song, file, partFile) {
        // ⚠️ pic_id 必须写进 .meta —— dlRecover 冷启动恢复时要靠它补下载封面
        //    （见 saveSidecars 的调用点）。早先的 .meta 没有这个字段，于是
        //    "关掉插件页时下的歌"永远没有封面，而正常下的有 —— 同一种操作两种结果。
        var j = JSON.stringify({ id: song.id, source: song.source || source,
                                 name: song.name || "", artist: song.artist || "",
                                 pic_id: song.pic_id ? String(song.pic_id) : "",
                                 lyric_id: song.lyric_id || song.id, file: file, part: partFile })
        return "mkdir -p " + dlDir + " " + dlTmpDir + "; printf '%s' "
             + shellQuote(j) + " > " + shellQuote(metaFile) + "; true"
    }

    // 下载命令（纯函数）。两段刻意设计：
    // ① .part 落在 dlTmpDir（tmpfs 缓存区）而不是歌曲文件夹 —— 半截 mp3 绝不进歌库；
    // ② curl 成功且文件非空才 mv 进 downloadDir，然后才写 ok: ——
    //    「ok: 出现 ⇔ 完整文件已在歌曲文件夹里」是 dlRecover 判定的基石。
    // 开头先 HEAD 一次拿 Content-Length 写进 st（total: 行），轮询侧据此算百分比；
    // 拿不到就没有 total: 行，UI 只显示已下载字节。
    function buildDownloadCmd(url, file, partFile, stFile) {
        return "mkdir -p " + downloadDir + " " + dlTmpDir + " " + dlDir + "; "
             + "rm -f " + shellQuote(partFile) + " " + shellQuote(stFile) + "; "
             + "t=$(LC_ALL=C curl -sIL --max-time 20 -A " + shellQuote(uaBrowser) + " " + shellQuote(url)
             + " | sed -n 's/^[Cc]ontent-[Ll]ength:[ ]*//p' | tail -1 | tr -dc '0-9'); "
             + "[ -n \"$t\" ] && printf 'total:%s' \"$t\" > " + shellQuote(stFile) + "; "
             + "if curl -sL --max-time 900 --connect-timeout 15 -A " + shellQuote(uaBrowser) + " "
             + "  -o " + shellQuote(partFile) + " " + shellQuote(url) + "; then "
             + "  if [ -s " + shellQuote(partFile) + " ]; then "
             + "    mv " + shellQuote(partFile) + " " + shellQuote(file) + "; "
             + "    printf 'ok:%s' \"$(stat -c%s " + shellQuote(file) + ")\" > " + shellQuote(stFile) + "; "
             + "  else rm -f " + shellQuote(partFile) + "; printf 'fail:下载为空' > " + shellQuote(stFile) + "; fi; "
             + "else rm -f " + shellQuote(partFile) + "; printf 'fail:网络中断' > " + shellQuote(stFile) + "; fi; true"
    }

    // 入队（probe 可直接调用，不碰 shell）。真正的「点下载」入口是 downloadSong。
    function dlEnqueue(song, file, partFile, stFile, metaFile) {
        var key = "" + (++dlSeq)
        var c = dlState; c[song.id] = "queue"; dlState = c
        dlPending[key] = { id: song.id, song: song, file: file, part: partFile,
                           st: stFile, meta: metaFile, got: 0, total: -1, msg: "" }
        var q = dlQueue.slice(); q.push(key); dlQueue = q
        refreshQueueView()
        return key
    }

    // 开始下载。取地址刻意复用 §网络层 的 apiGet —— 优选 IP、超时、轮询那套逻辑
    // 已经写好了，没必要再抄一遍；这里只负责「拿到 url 之后拉下来 + 落盘」。
    function downloadSong(song) {
        if (!song || !song.id) return
        if (typeof shell === "undefined" || !shell) { toast.show("需要 shell 支持"); return }
        if (isDownloaded(song)) { toast.show("已经下载过了"); return }
        var st = dlStatus(song)
        if (st === "queue" || st === "run") { toast.show("已在下载队列中"); return }

        var file = localPathFor(song)
        var keyN = dlSeq + 1
        var part = dlTmpDir + "/" + keyN + ".part"
        shell.startDetached(buildMetaCmd(dlDir + "/" + keyN + ".meta", song, file, part))
        dlEnqueue(song, file, part, dlDir + "/" + keyN + ".st", dlDir + "/" + keyN + ".meta")
        toast.show("已加入下载队列：" + (song.name || ""))
        dlKick()
    }

    // 队列调度：空闲就从队首取一个。串行是刻意的（见属性区注释）。
    // 注意 apiGet 是异步的：取地址期间 dlRunning 已占位，期间被取消时回调里要认得出。
    function dlKick() {
        if (dlRunning !== "") return
        if (!dlQueue.length) { refreshQueueView(); return }
        dlRunning = dlQueue.shift()
        dlQueue = dlQueue.slice()
        var e = dlPending[dlRunning]
        if (!e) { dlRunning = ""; dlKick(); return }   // 队列里混进了脏数据，跳过取下一个
        var c = dlState; c[e.id] = "run"; dlState = c
        refreshQueueView()
        var key = dlRunning
        apiGet("types=url&source=" + encodeURIComponent(e.song.source || source)
               + "&id=" + encodeURIComponent(e.song.id)
               + "&br=" + encodeURIComponent(quality), function(ok, txt) {
            if (dlPending[key] !== e) return           // 等待取地址期间被取消了
            if (!ok) { dlFinish(key, false, "取不到播放地址"); return }
            var o = null
            try { o = JSON.parse(txt) } catch (err) { o = null }
            var u = o && o.url
            if (!u) { dlFinish(key, false, "该曲无版权或需会员"); return }
            // 总大小主来源：API 的 size 字段（实测与 Content-Length 一致）；
            // 没有它才靠 buildDownloadCmd 里的 HEAD 兜底。轮询侧只在未设时采信 total: 行。
            if (o.size > 0) e.total = o.size
            shell.startDetached(buildDownloadCmd(u, e.file, e.part, e.st))
            // sidecar（歌词 + 封面）在这里就发起，**不等 mp3 下完** ——
            // 两者都只依赖"这首歌是谁"，与音频流互不相干；而串行队列下音频要等
            // 前面几首下完，歌词封面却能早早落盘。用户下完一首歌时按播放已经有词有图。
            saveSidecars(e.song, e.file)
            if (!dlPollTimer.running) dlPollTimer.restart()
        })
    }

    function dlFinish(key, ok, msg) {
        var e = dlPending[key]
        if (!e) return
        delete dlPending[key]
        var c = dlState; c[e.id] = ok ? "ok" : "fail"; dlState = c
        // ★ 自动登记 —— 这是唯一的自动登记时机。
        //   登记所需的 {id, source, name, artist} 本来就写在 .meta 里（见 buildMetaCmd），
        //   而 e.song 过了这一拍就随 dlPending 一起没了。所以必须在删 .meta 之前做，
        //   且**只在成功时**做（失败时文件还在 tmpfs 的 .part 里，根本没进歌曲文件夹）。
        if (ok && e.song && e.file) mapPut(e.file, e.song, "auto")
        // st/meta 完成使命，删掉（下次冷启动 dlRecover 才不会误认）。
        // 字段已经搬进登记表，删掉它不影响匹配 —— 列表仍然以文件夹扫描为准。
        if (typeof shell !== "undefined" && shell)
            shell.startDetached("rm -f " + shellQuote(e.st) + " " + shellQuote(e.meta) + " "
                              + shellQuote(e.part) + "; true")
        toast.show((ok ? "下载完成：" : "下载失败：") + msg)
        if (dlRunning === key) { dlRunning = ""; dlKick() }   // 交棒给队首
        refreshQueueView()
        if (!Object.keys(dlPending).length) refreshLocal()
    }

    // 解析一次轮询的输出（纯函数，探针可直测）。
    // ⚠️ 必须逐行扫描而不是按「第 0 行=状态、第 1 行=大小」定位 ——
    // st 是否带尾部换行决定了中间会不会多出空行（踩过：total:%s\n 让 got 恒 0、进度恒 0%）。
    function parseDlDump(dump) {
        var parts = String(dump || "").split(new RegExp(dlMarkL + "(\\d+)" + dlMarkR))
        var res = []
        for (var j = 1; j + 1 < parts.length; j += 2) {
            var lines = String(parts[j + 1] || "").split("\n")
            var st = "", sz = "-"
            for (var li = 0; li < lines.length; li++) {
                var v = String(lines[li] || "").trim()
                if (!v) continue
                if (v.indexOf("ok:") === 0 || v.indexOf("fail") === 0 || v.indexOf("total:") === 0) st = v
                else sz = v                                    // 已下载字节，或 "-"
            }
            res.push({ key: parts[j], st: st, sz: sz })
        }
        return res
    }

    // 轮询正在下载的任务。一次 shell 调用把所有任务的状态 + 已下载字节读回来
    // （和 apiPoll 同一个思路：设备弱，别一个文件一次 exec）。
    function dlPoll() {
        var keys = Object.keys(dlPending)
        if (!keys.length) { dlPollTimer.stop(); refreshLocal(); return }

        var cmd = ""
        for (var i = 0; i < keys.length; i++) {
            var e = dlPending[keys[i]]
            cmd += "echo '" + dlMarkL + keys[i] + dlMarkR + "'; "
                 + "cat " + e.st + " 2>/dev/null; echo; "
                 + "stat -c%s " + shellQuote(e.part) + " 2>/dev/null || echo -; "
        }
        var dump = ""
        try { dump = String(shell.exec(cmd)) } catch (err) { dump = "" }

        var list = parseDlDump(dump)
        for (var j = 0; j < list.length; j++) {
            var e2 = dlPending[list[j].key]
            if (!e2) continue
            var st = list[j].st, sz = list[j].sz
            if (st.indexOf("ok:") === 0) {
                e2.got = parseInt(st.substring(3), 10) || 0
                dlFinish(list[j].key, true, e2.song.name || "")
                // ⚠️ 这里**刻意不再**存歌词/封面 —— 已在 dlKick 取到地址时就发起了。
                //   在两处都发会让 sidecar 走两遍 API（幂等只挡"已落盘"，挡不住"在飞"）。
            } else if (st.indexOf("fail") === 0) {
                dlFinish(list[j].key, false, st.substring(5) || "未知原因")
            } else {
                // st 里只写了 total: 行（还在下载中）；ok:/fail: 会整体覆盖它。
                // 只在 total 未设时采信 —— API 的 size 优先（见 dlKick），别被 HEAD 顶掉。
                if (e2.total <= 0 && st.indexOf("total:") === 0)
                    e2.total = parseInt(st.substring(6), 10) || -1
                e2.got = (sz === "-") ? 0 : (parseInt(sz, 10) || 0)
            }
        }
        refreshQueueView()
    }

    // 取消。排队中的直接摘掉；下载中的要先杀 curl。
    // ⚠️ pkill -f 的 pattern 首字符套 []：裸路径会让 pgrep/pkill 匹配到
    // 「我们自己这条刚 fork 出来的 sh -c 命令行」——经典自匹配陷阱。
    function dlCancel(id) {
        var key = ""
        if (dlRunning !== "" && dlPending[dlRunning] && dlPending[dlRunning].id === id) {
            key = dlRunning
        } else {
            for (var i = 0; i < dlQueue.length; i++) {
                var k = dlQueue[i]
                if (dlPending[k] && dlPending[k].id === id) {
                    key = k
                    dlQueue.splice(i, 1); dlQueue = dlQueue.slice()
                    break
                }
            }
        }
        if (!key) return
        var e = dlPending[key]
        delete dlPending[key]
        var c = dlState; if (c[id]) { delete c[id]; dlState = c }
        if (typeof shell !== "undefined" && shell) {
            var bp = "[" + e.part.charAt(0) + "]" + e.part.substring(1)
            shell.startDetached("pkill -f " + shellQuote(bp) + " 2>/dev/null; rm -f "
                                + shellQuote(e.part) + " " + shellQuote(e.st) + " "
                                + shellQuote(e.meta) + "; true")
        }
        if (dlRunning === key) { dlRunning = ""; dlKick() }
        refreshQueueView()
        toast.show("已取消下载")
    }

    // 冷启动恢复：插件页关掉后下载还在后台跑（startDetached + 轮询刻意不停的那套设计）。
    // 重开时扫 dlDir：.meta 记了歌是谁/最终路径/缓存 part 路径、.st 记了 total/ok/fail。
    //   ok:       → 完整文件已 mv 进歌曲文件夹（下载命令保证），只需清残件
    //   fail:     → 清 part + 残件
    //   无结果：
    //     终稿已在（mv 完成但 ok: 没来得及写）→ 当成功处理，只清残件
    //     curl 活着 → 认领：接回队列视图继续看进度
    //     其余（孤儿）→ 清掉缓存 part + 残件，标 fail
    // 判活 pgrep -f 的 pattern 同样要套 []（理由同 dlCancel）。
    function dlRecover() {
        if (typeof shell === "undefined" || !shell) return
        var cmd = "for m in " + dlDir + "/*.meta; do [ -e \"$m\" ] || continue; "
                + "echo '" + dlMarkL + "M" + dlMarkR + "'; echo \"$m\"; cat \"$m\"; echo; "
                + "cat \"${m%.meta}.st\" 2>/dev/null; echo; "
                + "p=$(sed -n 's/.*\"part\":\"\\([^\"]*\\)\".*/\\1/p' \"$m\"); [ -n \"$p\" ] || p=$(sed -n 's/.*\"file\":\"\\([^\"]*\\)\".*/\\1/p' \"$m\").part; "
                + "stat -c%s \"$p\" 2>/dev/null || echo '-'; "
                + "f=$(sed -n 's/.*\"file\":\"\\([^\"]*\\)\".*/\\1/p' \"$m\"); "
                + "if [ -s \"$f\" ]; then echo FOK; else echo FNO; fi; "
                + "if pgrep -f \"[/]${p#/}\" >/dev/null 2>&1; then echo RUN; else echo DEAD; fi; "
                + "done; true"
        var dump = ""
        try { dump = String(shell.exec(cmd)) } catch (err) { dump = "" }
        var blocks = dump.split(dlMarkL + "M" + dlMarkR)
        for (var i = 1; i < blocks.length; i++) {
            var lines = String(blocks[i] || "").split("\n")
            var metaPath = String(lines[0] || "").trim()
            var meta = null
            try { meta = JSON.parse(String(lines[1] || "").trim()) } catch (e0) { meta = null }
            if (!meta || !meta.id || !meta.file || metaPath.indexOf(dlDir) !== 0) continue
            var song = { id: meta.id, source: meta.source, name: meta.name,
                         artist: meta.artist, lyric_id: meta.lyric_id, pic_id: meta.pic_id }
            var stTxt  = String(lines[2] || "").trim()
            var psz    = String(lines[3] || "").trim()
            var finOk  = String(lines[4] || "").trim() === "FOK"
            var alive  = String(lines[5] || "").trim() === "RUN"
            var part   = String(meta.part || (meta.file + ".part"))
            var clean  = "rm -f " + shellQuote(metaPath) + " "
                       + shellQuote(metaPath.replace(/\.meta$/, ".st")) + " "
                       + shellQuote(part) + "; true"
            if (stTxt.indexOf("ok:") === 0 || finOk) {
                // 完整文件已在歌曲文件夹 —— 列表靠扫描自然出现，清掉任务残件即可。
                // ⚠️ 还要补 sidecar：这条路的下载是**插件页关着时**跑的，
                //    那时 dlKick 早就随页面一起销毁了，从没发起过歌词/封面下载。
                //    不在这儿补 ⇒ "关页面时下的歌"永远没封面，"开着页面下的有"。
                saveSidecars(song, meta.file)
                shell.startDetached(clean)
            } else if (stTxt.indexOf("fail") === 0) {
                shell.startDetached(clean)
            } else if (alive && psz !== "-" && parseInt(psz, 10) > 0) {
                // 认领：curl 还活着，接回队列（冷启动时 dlRunning 必为空，直接占位）
                var stPath = metaPath.replace(/\.meta$/, ".st")
                var key = "" + (++dlSeq)
                dlPending[key] = { id: meta.id, song: song, file: meta.file, part: part,
                                   st: stPath, meta: metaPath,
                                   got: parseInt(psz, 10) || 0,
                                   total: (stTxt.indexOf("total:") === 0) ? (parseInt(stTxt.substring(6), 10) || -1) : -1,
                                   msg: "" }
                if (dlRunning === "") { dlRunning = key; var c = dlState; c[meta.id] = "run"; dlState = c }
                else { var q = dlQueue.slice(); q.push(key); dlQueue = q; var c2 = dlState; c2[meta.id] = "queue"; dlState = c2 }
                // 同上：这条链路的 dlKick 已经在上一次进程里跑完了，sidecar 得在这补。
                // 认领的可能是多首（队列里排着的），逐个发 —— saveSidecars 幂等，
                // 且它们各自独立失败，不影响任何一个的进度显示。
                saveSidecars(song, meta.file)
                if (!dlPollTimer.running) dlPollTimer.restart()
            } else {
                // 孤儿：curl 已死且没写结果。给个 fail 态（图标变 !），残件清掉
                var c3 = dlState; c3[meta.id] = "fail"; dlState = c3
                shell.startDetached(clean)
            }
        }
        refreshQueueView()
    }

    // ============================================================
    // sidecar：随歌下载歌词（.lrc）与封面（.jpg/.png）
    // ============================================================
    // 三个刻意的决定：
    //
    // ① **在 dlKick 取到播放地址时就发起，不等 mp3 下完**（见那里的调用点）。
    //    两者只依赖"这首歌是谁"，与音频流无关；而队列是串行的，音频得排前面几首，
    //    等它下完再补歌词封面 ⇒ 用户下完最后一首按下播放，前面那几首仍然没词没图。
    //
    // ② **幂等：已存在就跳过**。sidecar 可能被发起两次（冷启动 dlRecover 认领后
    //    又走一遍，或用户在"下载中"时重开插件页），重复写没坏处但白耗一次 API + 一次
    //    落盘。判存在只需一次极短的 test -s（不是 stat 全量扫描）。
    //
    // ③ **失败一律静默**：封面/歌词是附属品，拿不到绝不能影响 mp3 本身的下載结果。
    //    所以这两个函数不碰 dlState、不 toast、不写 .st —— 唯一的对外痕迹是
    //    refreshLocal 之后 localList 上多出来的 img / hasLrc 字段。
    function saveSidecars(song, file) {
        if (!dlSidecar) return
        if (!song || !file) return
        saveLocalLrc(song, file)
        saveLocalCover(song, file)
    }

    // 歌词存成同名 .lrc —— 离线时不至于没词可看。
    function saveLocalLrc(song, file) {
        var lrc = localLrcFor(file)
        if (localFileExists(lrc)) return
        apiGet("types=lyric&source=" + encodeURIComponent(song.source || source)
               + "&id=" + encodeURIComponent(song.lyric_id || song.id), function(ok, txt) {
            if (!ok) return
            var o = null
            try { o = JSON.parse(txt) } catch (e) { return }
            if (!o || !o.lyric) return               // 没词就不写空文件：空的 .lrc 会让"有歌词"这个判断变成假阳性
            var merged = String(o.lyric || "")
            if (o.tlyric) merged = merged + "\n" + String(o.tlyric)
            if (typeof shell === "undefined" || !shell) return
            shell.startDetached("printf '%s' " + shellQuote(merged) + " > " + shellQuote(lrc) + "; true")
            // 立刻重扫，让本地页的"有歌词"标记马上亮 —— 否则要等下次进页面才对
            scheduleLocalRescan()
        })
    }

    // 封面存成同名 .jpg/.png。两段：先向 API 要图床 URL，再 curl 落盘。
    // ⚠️ 图床 URL 不在 API 域名下（实测 p2.music.126.net），**不能走 apiGet 的 IP 优选** ——
    //    那是给 music-api.gdstudio.xyz 用的 --resolve，对别的域名会直接让 TLS 校验失败。
    //    所以这里老老实实用裸 curl（DNS 走设备默认 resolver）。
    function saveLocalCover(song, file) {
        if (!song.pic_id) return                   // 本地条目没有 pic_id（未登记）→ 没有图可下
        if (localImgFor(file) && localFileExists(localImgFor(file))) return
        apiGet("types=pic&source=" + encodeURIComponent(song.source || source)
               + "&id=" + encodeURIComponent(song.pic_id) + "&size=500", function(ok, txt) {
            if (!ok) return
            var o = null
            try { o = JSON.parse(txt) } catch (e) { return }
            if (!o || !o.url) return
            if (typeof shell === "undefined" || !shell) return
            shell.startDetached(buildCoverCmd(o.url, file))
            scheduleLocalRescan()
        })
    }

    // 封面下载命令（纯函数，探针可直测）。与 buildDownloadCmd 同构的三点：
    //   .part 先落 tmpfs → [ -s ] 非空校验 → 才 mv 进歌曲文件夹。
    // ⚠️ 扩展名由 URL 推断（imgExtForUrl），**不能写死 .jpg**：图床有的给 png。
    // ⚠️ 额外的守卫：`--max-time 40` 比音频的 900 短得多 —— 封面 60KB 上下，
    //    磨一分钟就是异常，不该占着后台进程。
    function buildCoverCmd(url, mp3File) {
        var ext = imgExtForUrl(url)
        var dst = sidecarBase(mp3File) + ext
        var part = dlTmpDir + "/cover" + ext + ".part"
        return "mkdir -p " + dlTmpDir + " " + downloadDir + "; "
             + "rm -f " + shellQuote(part) + "; "
             + "if curl -sL --max-time 40 --connect-timeout 15 -A " + shellQuote(uaBrowser) + " "
             + "  -o " + shellQuote(part) + " " + shellQuote(url) + "; then "
             + "  if [ -s " + shellQuote(part) + " ]; then "
             + "    mv " + shellQuote(part) + " " + shellQuote(dst) + "; "
             + "  else rm -f " + shellQuote(part) + "; fi; "
             + "else rm -f " + shellQuote(part) + "; fi; true"
    }

    // 单个文件的存在性判定（同步 exec，5s 上限内一条 test 远够）。
    // ⚠️ 刻意用 `test -s`（非空）而不是 `test -e`：空文件是"上次下崩了"的残留，
    //    判成"已存在"就会永远不再重下。
    function localFileExists(p) {
        if (!p) return false
        if (typeof shell === "undefined" || !shell) return false
        var out = ""
        try { out = String(shell.exec("test -s " + shellQuote(p) + " && echo Y || echo N")) } catch (e) { out = "" }
        return out.indexOf("Y") >= 0
    }

    // sidecar 是异步落盘的（apiGet → curl），回来时列表早就渲染完了 ⇒ 不能直接
    // refreshLocal（会打断正在滚的列表）。合并到一个短延时上再扫一次：
    // 连续下五首就是五次重扫，设备上分毫秒内跑完，可以接受。
    function scheduleLocalRescan() {
        if (typeof sidecarRescanTimer === "undefined") return
        if (sidecarRescanTimer.running) sidecarRescanTimer.restart()
        else sidecarRescanTimer.start()
    }

    // 扫描下载文件夹（纯函数，探针可直测）。每行 = "size|文件名"。
    // 按**第一个** | 切分：前段是纯数字（stat 的输出），文件名里就算带 | 也不会错位。
    // 歌名/歌手从文件名反推（「歌名-歌手.mp3」，见 localNameFor）；推断不出就显示整个名字。
    function parseLocalScan(dump) {
        var arr = []
        var lines = String(dump || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var v = String(lines[i] || "").trim()
            if (v.indexOf(localMark) !== 0) continue
            var body = v.substring(localMark.length)
            var p = body.indexOf("|")
            if (p < 0) continue
            var size = parseInt(body.substring(0, p), 10) || 0
            var fn   = body.substring(p + 1)
            if (!fn || !/\.mp3$/i.test(fn)) continue
            var base = fn.replace(/\.[^.]+$/, "")
            var dash = base.indexOf("-")
            arr.push({
                file: downloadDir + "/" + fn, size: size,
                name:  (dash > 0) ? base.substring(0, dash) : base,
                artist:(dash > 0) ? base.substring(dash + 1) : "",
                id: downloadDir + "/" + fn          // 没有登记表，文件路径就是唯一标识
            })
        }
        return arr
    }

    function buildScanCmd() {
        // ⚠️ `|` 必须待在引号内 —— 裸写会被 /bin/sh 当成**管道符**：
        //    `echo X|$f` 等价于 `echo X | $f`，即把 echo 的输出喂给一个名叫
        //    「歌曲名.mp3」的命令（必然 not found）。stdout 因此全空，而 exec()
        //    只读 stdout、stderr 被丢掉、exit code 也算成功 ⇒ **静默扫出 0 首**，
        //    本地页永远显示"还没有下载的歌"。
        //    设备实测（2026-10-02）原写法 5 行全是 "not found + Broken pipe"。
        //    写法用 shell 变量 gm 保底：分隔符经单引号传入，展开进双引号里，
        //    既不拆词也不会被二次解释。
        //
        // 第二段循环扫 sidecar 封面（.jpg/.png），用**另一个标记**输出文件名全名。
        // 刻意不把封面塞进 mp3 那一行：@@GDMUS@@ 的 "size|文件名" 格式被
        // probe/scancmd-e2e.sh 等按行数/按第一根 | 断言，动它会连带一堆探针。
        return "(cd " + downloadDir + " 2>/dev/null && gm=" + shellQuote(localMark)
             + "; sm=" + shellQuote(sidecarMark) + "; lm=" + shellQuote(lrcMark) + "; "
             + "for f in *.mp3; do [ -e \"$f\" ] || continue; "
             + "echo \"$gm$(stat -c%s \"$f\")|$f\"; done; "
             + "for g in *.jpg *.png; do [ -e \"$g\" ] || continue; "
             + "echo \"$sm$g\"; done; "
             + "for l in *.lrc; do [ -e \"$l\" ] || continue; "
             + "echo \"$lm$l\"; done); true"
    }

    // 本地列表 = 直接扫文件夹，不做任何插件侧登记 —— 用户用文件管理器加/删歌，
    // 下次进本地页就是最新状态，不存在「索引悬空条目」这种东西。
    function refreshLocal() {
        if (typeof shell === "undefined" || !shell) return
        var dump = ""
        try { dump = String(shell.exec(buildScanCmd())) } catch (e) { dump = "" }
        sidecarImgs = parseSidecarScan(dump)
        sidecarLrcs = parseSidecarLrcScan(dump)
        localList = parseLocalScan(dump)
        gcFileMap()        // 先清悬空登记，再装饰 —— 顺序反了会把刚删掉的条目又贴上去
        decorateLocal()
        updateLocalStat()
    }

    // 从同一次扫描输出里挑出封面行 → { "歌名-歌手": "/userdisk/.../歌名-歌手.jpg", ... }（纯函数）。
    // ⛔ 与 parseLocalScan **分开**而不是合进去：后者是纯列表解析（探针按行断言它），
    //    这里要返回一个对象供 O(1) 查表。合成一个函数会让"扫到几首歌"与"有几张封面"
    //    两种断言互相干扰。
    // 只认白名单扩展名 ⇒ 万一用户在文件夹里放了张 .webp，扫描不会把它当封面。
    function parseSidecarScan(dump) {
        var out = {}
        var lines = String(dump || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var v = String(lines[i] || "").trim()
            if (v.indexOf(sidecarMark) !== 0) continue
            var fn = v.substring(sidecarMark.length).trim()
            if (!fn) continue
            var low = fn.toLowerCase()
            var okExt = false
            for (var e = 0; e < sidecarImgExts.length; e++)
                if (low.length > sidecarImgExts[e].length
                    && low.slice(-sidecarImgExts[e].length) === sidecarImgExts[e]) { okExt = true; break }
            if (!okExt) continue
            // ⚠️ key 必须是**含目录的完整 base**（与 sidecarBase(file) 逐字符相同），
            //   不是"去掉目录的文件名"。两者差一级目录 ⇒ 查表永远 miss ⇒
            //   封面下载了却永远不显示，而所有单测（各自喂各自的 key）都是绿的。
            //   这个 bug 就是被 probe/sidecar.sh 的 B 组断言抓到的。
            out[downloadDir + "/" + fn.replace(/\.[^.]+$/, "")] = downloadDir + "/" + fn
        }
        return out
    }

    // 歌词侧车登记：{ "歌名-歌手": "/…/歌名-歌手.lrc" }。
    // ⚠️ 只认**非空**这件事由下载侧保证（写 lrc 前先判 API 有没有词），
    //    扫描侧就不再看大小了 —— 一次 stat 换不来多少准确性，却要多一条命令。
    function parseSidecarLrcScan(dump) {
        var out = {}
        var lines = String(dump || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var v = String(lines[i] || "").trim()
            if (v.indexOf(lrcMark) !== 0) continue
            var fn = v.substring(lrcMark.length).trim()
            if (!fn || fn.slice(-4).toLowerCase() !== ".lrc") continue
            out[downloadDir + "/" + fn.replace(/\.[^.]+$/, "")] = downloadDir + "/" + fn
        }
        return out
    }

    // 把登记信息贴到每条本地记录上，供本地页显示 ✓ 和**真名**（真名比从文件名反推准）。
    // 刻意放在这里而不是 parseLocalScan 里：后者要保持**纯函数**，探针直接断言它的输出。
    // 只影响显示，不参与匹配判定 —— 判定始终走 findLocal（那里自己与 localList 求交）。
    function decorateLocal() {
        var src = localList, out = []
        for (var i = 0; i < src.length; i++) {
            var r = src[i], o = {}
            for (var k in r) o[k] = r[k]           // 手写浅拷贝（QML 引擎未必有 Object.assign）
            var e = fileMap[r.file]
            o.matched = !!e
            // 本地封面（若有）—— 播放页与本地页显示都走这个字段，不再联网取。
            // ⛔ 不要改成"没有就填一个猜测路径"：那会让 Image 去加载一个不存在的文件，
            //   表现为"封面位置留了个灰块"，比没有封面更糟。
            o.img = sidecarImgs[sidecarBase(r.file)] || ""
            o.hasLrc = !!sidecarLrcs[sidecarBase(r.file)]
            if (e) {
                if (e.name)   o.name   = e.name
                if (e.artist) o.artist = e.artist
                o.mapMode = e.m || ""
            }
            out.push(o)
        }
        localList = out
    }

    function updateLocalStat() {
        var total = 0
        for (var i = 0; i < localList.length; i++) total += (localList[i].size || 0)
        var mb = total / (1024 * 1024)
        localStat = localList.length + " 首 · "
                  + (mb >= 1 ? (mb.toFixed(1) + " MB") : (Math.round(total / 1024) + " KB"))
    }

    function sizeText(n) {
        var b = Number(n) || 0
        var mb = b / (1024 * 1024)
        return mb >= 1 ? (mb.toFixed(1) + " MB") : (Math.round(b / 1024) + " KB")
    }

    // 播本地曲目：给队列塞一个带 file 的对象即可 ——
    // lua 看到 file 就直接 loadfile，不再去取流，所以离线也能播。
    function playLocal(i) {
        var rec = localList[i]
        if (!rec) return
        // 扫描记录没有 source/网络 id —— 但 lua 看到 file 就直接 loadfile，
        // 网络字段根本用不上；id 用文件路径兜底（保持队列条目形状完整）。
        var song = { id: rec.id, name: rec.name, artist: rec.artist, file: rec.file }
        // 已登记的歌（插件下载时自动登记 / 手动匹配）补上网络字段 ⇒
        //   · 封面能按 pic_id 联网取（否则本地条目没有 pic_id，播放页就没封面）
        //   · 歌词仍读同名 .lrc（fetchLyric 里 `if (song.file)` 那一支）
        var e = mapEntryOf(rec)
        if (e) {
            song.id     = e.id
            song.source = e.source
            if (e.name)     song.name     = e.name       // 用真名，而不是从文件名反推的
            if (e.artist)   song.artist   = e.artist
            if (e.pic_id)   song.pic_id   = e.pic_id
            if (e.lyric_id) song.lyric_id = e.lyric_id
        }
        queue = [song]
        page = "player"
        startAt(0)
    }

    function deleteLocal(i) {
        var rec = localList[i]
        if (!rec) return
        if (typeof shell === "undefined" || !shell) return
        // 三件一起删：mp3 + 同名 .lrc + 同名封面。
        // ⚠️ 封面有两种可能扩展名（.jpg / .png，由图床 URL 推断），**都要删** ——
        //    只删一种的话，另一半会变成永远没人认领的孤儿文件躺在歌单目录里。
        //    用户看不出那是什么，也不敢删（怕弄坏什么），目录越用越脏。
        var rm = "rm -f " + shellQuote(rec.file) + " " + shellQuote(localLrcFor(rec.file))
        for (var e = 0; e < sidecarImgExts.length; e++)
            rm += " " + shellQuote(sidecarBase(rec.file) + sidecarImgExts[e])
        shell.startDetached(rm + "; true")
        // 显式清登记：rm 是 startDetached（异步），紧接着的 refreshLocal 很可能在 rm
        // 落地之前就扫完了 —— 那一拍 gcFileMap 看到的文件还在，就清不掉这一条。
        mapRemove(rec.file)
        refreshLocal()
        toast.show("已删除：" + rec.name)
    }

    // 读本地 .lrc。**返回是否真的取到了词** —— fetchLyric 靠它决定要不要联网兜底。
    // ⚠️ 返回值必须 `!!` 收敛：`txt.length ? true : false` 之类在 QML 里容易被写成
    //    非布尔（下面第一行就是要害），而调用方是 `if (fetchLocalLyric(...)) return`
    //    —— 逻辑上没错，但风格上与 §5.9「bool 属性要收敛」保持一致。
    function fetchLocalLyric(file) {
        if (typeof shell === "undefined" || !shell) return false
        var txt = ""
        try { txt = String(shell.exec("cat " + shellQuote(localLrcFor(file)) + " 2>/dev/null")) }
        catch (e) { txt = "" }
        if (!txt.length) { lyricLines = []; lyricIndex = -1; return false }
        lyricLines = parseLrc(txt)
        lyricIndex = -1
        updateLyricIndex()
        return true
    }

    function fetchLyric(song) {
        if (!song) return
        if (song.file) {
            // 本地歌曲：读同名 .lrc。
            // ⚠️ 读不到时**不直接放弃** —— 继续往下走联网兜底。这个分支很常见：
            // 用户手动拷进文件夹的 mp3、只有文件没有 .lrc 的老歌、sidecar 下载失败过。
            // 早先这里直接 return，于是这些歌永远一行词都没有，而联网其实能拿到。
            if (fetchLocalLyric(song.file)) return
        }
        if (!loadExtra) return                        // 开关只掐联网那半
        if (!song.lyric_id && !song.id) return        // 本地条目且未登记 → 没有联网的钥匙
        var qs = "types=lyric&source=" + encodeURIComponent(song.source || source)
                 + "&id=" + encodeURIComponent(song.lyric_id || song.id)
        apiGet(qs, function(ok, txt) {
            if (!ok) return
            var o = null
            try { o = JSON.parse(txt) } catch (e) { return }
            if (!o) return
            var merged = String(o.lyric || "")
            if (o.tlyric) merged = merged + "\n" + String(o.tlyric)
            if (currentSong && song.id !== currentSong.id) return   // 已切歌，丢弃
            lyricLines = parseLrc(merged)
            lyricIndex = -1
            updateLyricIndex()
        })
    }

    // 取封面。**先本地、后联网**：
    //   本地命中（下载时一起存下的 .jpg/.png）⇒ 直接给 file:// 路径，零网络往返；
    //   否则才按 pic_id 联网向 API 要图床 URL。
    // ⚠️ 本地判定用 sidecarImgs（来自 refreshLocal 的那次扫描），**不做 test -f** ——
    //    fetchCover 在每次切歌时都会调，一次同步 exec 会在主线程上白等几十毫秒；
    //    而 sidecarImgs 已经是"扫过且存在"的结论，直接查表即可。
    //    刚下载完还没重扫的那一拍会退回联网，属可接受的一次多余请求。
    // ⚠️ 本地命中时**不要**再看 loadExtra：那个开关管的是"要不要联网"，
    //    读一个已经在硬盘上的文件不耗流量，关掉它不该让本地封面消失。
    // 切歌时拉歌词与封面。**loadExtra 只管联网那半，本地那半无条件执行**：
    //   · 本地：读磁盘上已经有的 .lrc / .jpg —— 零流量、零延迟，没有理由被开关关掉；
    //   · 联网：向 API 要图床 URL / 歌词文本，受 loadExtra 控制（用户可能就是想省流量）。
    // ⚠️ 别写成 `if (loadExtra) { fetchCover(); fetchLyric() }` 的老形式 ——
    //    那会让"关掉加载歌词封面"连**已下载歌曲的本地封面**一起关掉，
    //    而它其实就在硬盘上、不花用户一分钱。开关的作用域必须精确到"联网"两个字，
    //    所以判据在 fetchCover / fetchLyric 各自的联网分支里，不在这里。
    function loadExtras(song) {
        if (!song) return
        fetchLyric(song)   // 内部：有 file 直接读本地 .lrc；否则联网（受 loadExtra 管）
        fetchCover(song)   // 内部：sidecarImgs 命中就用 file://；否则联网（受 loadExtra 管）
    }

    function fetchCover(song) {
        if (!song) return
        if (song.file) {
            var local = sidecarImgs[sidecarBase(song.file)] || ""
            if (local.length) { coverUrl = "file://" + local; return }
        }
        if (!song.pic_id) return
        if (!loadExtra) return                        // 开关只掐联网那半（本地分支在上面已 return）
        var qs = "types=pic&source=" + encodeURIComponent(song.source || source)
                 + "&id=" + encodeURIComponent(song.pic_id) + "&size=500"
        apiGet(qs, function(ok, txt) {
            if (!ok) return
            var o = null
            try { o = JSON.parse(txt) } catch (e) { return }
            if (!o || !o.url) return
            if (currentSong && song.id !== currentSong.id) return
            coverUrl = o.url
        })
    }

    // ============================================================
    // 设置持久化
    // ============================================================
    function db() {
        return LocalStorage.openDatabaseSync("gdmusic", "1.0", "GD Music", 100000)
    }

    function loadSettings() {
        try {
            var d = db()
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                function get(k, def) {
                    var rs = tx.executeSql("SELECT value FROM kv WHERE key=?", [k])
                    return rs.rows.length ? rs.rows.item(0).value : def
                }
                source         = get("source", source)
                // 老版本可能存着已被 API 下线的音源（实测 kuwo / tencent 现在都返回
                // "Value of `source` is not supported."）。不回落的话每次开机都固定失败，
                // 而且看不出是音源的锅 —— 用户只会觉得"这个插件搜不了歌"。
                if (!isValidSource(source)) {
                    console.warn("音源 " + source + " 已不在可用列表，回落 netease")
                    source = "netease"
                }
                quality        = get("quality", quality)
                autoNext       = get("autoNext", "1") === "1"
                usePreferredIp = get("usePrefIp", "1") === "1"
                cfIpText       = get("cfIps", cfIpText)
                bestIp         = get("bestIp", "")
                apiBase        = get("apiBase", "")
                loadExtra      = get("loadExtra", "1") === "1"
                dlSidecar      = get("dlSidecar", "1") === "1"
                sysMedia       = get("sysMedia", "1") === "1"
                holdOnStop     = get("holdOnStop", "0") === "1"
                preferLocal    = get("preferLocal", "1") === "1"
                // 文件登记表。解析失败按空表处理 —— 宁可丢匹配（退化成「精确路径匹配」，
                // 插件自己下的文件照样命中），也不能让一条坏 JSON 把整个 loadSettings
                // 连坐掉（那会连音源、优选 IP 都读不出来，症状看起来完全无关）。
                try {
                    var fm = JSON.parse(get("filemap", "{}"))
                    fileMap = (fm && typeof fm === "object" && !(fm instanceof Array)) ? fm : {}
                } catch (e2) {
                    fileMap = {}
                    console.warn("filemap 解析失败，按空表处理")
                }
                // 歌单。同样交给 parsePlaylists 兜底：坏数据只丢自己、不连坐设置。
                playlists = parsePlaylists(get("playlists", "[]"))
                // 网易云登录态（cookie / uid / 昵称）。
                ncCookie = get("ncookie", "")
                ncUid    = get("ncuid", "")
                ncNick   = get("ncnick", "")
            })
        } catch (e) { console.warn("loadSettings", e) }
    }

    function saveSettings() {
        try {
            var d = db()
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                function put(k, v) { tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", [k, String(v)]) }
                put("source", source)
                put("quality", quality)
                put("autoNext", autoNext ? "1" : "0")
                put("usePrefIp", usePreferredIp ? "1" : "0")
                put("cfIps", cfIpText)
                put("bestIp", bestIp)
                put("apiBase", apiBase)
                put("loadExtra", loadExtra ? "1" : "0")
                put("dlSidecar", dlSidecar ? "1" : "0")
                put("sysMedia", sysMedia ? "1" : "0")
                put("holdOnStop", holdOnStop ? "1" : "0")
                put("preferLocal", preferLocal ? "1" : "0")
            })
        } catch (e) { console.warn("saveSettings", e) }
    }

    // 登记表单独落盘（不并进 saveSettings）：每次下载完成都要写一次，
    // 没必要顺带把全部设置重写一遍。失败静默降级 —— 匹配丢了只是退化成
    // 「按文件名精确匹配」，不该因为一次写库失败就打断下载完成的提示。
    function saveFileMap() {
        try {
            var d = db()
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)",
                              ["filemap", JSON.stringify(fileMap)])
            })
        } catch (e) { console.warn("saveFileMap", e) }
    }

    // 歌单也单独落盘（理由同 saveFileMap）：增删歌比改设置频繁，
    // 没必要每次顺带把全部设置重写一遍。失败静默降级 —— 丢一次编辑不该打断操作，
    // 用户的下一次操作会再写一次。
    function savePlaylists() {
        try {
            var d = db()
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)",
                              ["playlists", JSON.stringify(playlists)])
            })
        } catch (e) { console.warn("savePlaylists", e) }
    }

    // 网易云登录态单独落盘（cookie 是长期凭证，登录成功后写一次即可）。
    function ncSaveCookie() {
        try {
            var d = db()
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", ["ncookie", ncCookie])
                tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", ["ncuid", ncUid])
                tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", ["ncnick", ncNick])
            })
        } catch (e) { console.warn("ncSaveCookie", e) }
    }

    // 「恢复默认」只重置**设置**，刻意不动歌单与文件登记表 ——
    // 那是用户攒下来的内容资产（歌单是手工整理的结果、登记表是匹配好的对应关系）。
    // 跟着"音源改错了想重置"一起被清掉，是不可接受的。
    function resetAll() {
        source = "netease"; quality = "320"; autoNext = true
        usePreferredIp = true; bestIp = ""
        cfIpText = "104.18.0.1,104.17.0.1,104.19.0.1,104.20.0.1,104.16.0.1,104.25.0.1,104.26.0.1,104.27.0.1,172.66.0.1,162.159.140.1"
        apiBase = ""; loadExtra = true; dlSidecar = true; sysMedia = true; holdOnStop = false; preferLocal = true
        saveSettings()
        MediaBridge.setEnabled(sysMedia)
        MediaBridge.setHoldOnStop(holdOnStop)
        toast.show("已恢复默认设置")
    }

    // ============================================================
    // 设置页交互
    // ============================================================
    function cycleSource() {
        var i = 0
        for (var k = 0; k < sources.length; k++) if (sources[k].id === source) i = k
        source = sources[(i + 1) % sources.length].id
        saveSettings()
        toast.show("音源：" + sourceLabel())
    }

    function setSource(id) {
        // 只接受列表内的 id。切源入口只有搜索页那个 Repeater，本来就只给列表内的值，
        // 但挡一道脏值能让"以后把别的音源加回来"时不必再担心存档里混进不认识的值。
        if (!isValidSource(id)) return
        source = id
        saveSettings()
        toast.show("音源：" + sourceLabel())
    }

    function cycleQuality() {
        var i = qualityList.indexOf(quality)
        quality = qualityList[(i + 1) % qualityList.length]
        saveSettings()
        toast.show("音质：" + qualityLabel())
    }

    function toggleAutoNext() { autoNext = !autoNext; saveSettings(); toast.show(autoNext ? "自动连播：开" : "自动连播：关") }
    function toggleLoadExtra() { loadExtra = !loadExtra; saveSettings(); toast.show(loadExtra ? "歌词封面：开" : "歌词封面：关") }
    // 「下载时存歌词封面」：只影响**今后**的下载，不回头补已下的歌。
    // 刻意不给"补齐全部"的按钮 —— 那意味着扫全目录、逐首发两次 API，
    // 在串行队列下会跑很久，且用户多半只想让以后新下的歌干净。
    function toggleDlSidecar() {
        dlSidecar = !dlSidecar
        saveSettings()
        toast.show(dlSidecar ? "下载附带歌词封面：开" : "下载附带歌词封面：关（只下 mp3）")
    }
    // 「已下载优先」：本地命中的歌直接播文件，不再取流（详见 resolveEntry 的注释）
    function togglePreferLocal() {
        preferLocal = !preferLocal
        saveSettings()
        toast.show(preferLocal ? "已下载优先：开（已下载的播本地，不耗流量）"
                               : "已下载优先：关（一律走网络音源）")
    }
    function toggleSysMedia() {
        sysMedia = !sysMedia
        saveSettings()
        MediaBridge.setEnabled(sysMedia)
        toast.show(sysMedia ? "系统媒体控制：开" : "系统媒体控制：关")
    }
    // 「停止后保留控制条」：面板按停止后卡片是否留着（详见 MediaBridge.holdOnStop）
    function toggleHoldOnStop() {
        holdOnStop = !holdOnStop
        saveSettings()
        MediaBridge.setHoldOnStop(holdOnStop)
        toast.show(holdOnStop ? "停播后保留控制条：开（面板卡片留着，可续播）"
                              : "停播后保留控制条：关（面板回落设置视图）")
    }
    function togglePreferredIp() { usePreferredIp = !usePreferredIp; saveSettings(); toast.show(usePreferredIp ? "网络优化：开" : "网络优化：关") }

    function editCfIps() {
        keyboard.open(cfIpText)
        editTarget = "cfIps"
    }

    function editApiBase() {
        keyboard.open(apiBase)
        editTarget = "apiBase"
    }

    property string editTarget: ""

    function openKeyboard() {
        // 宿主 YInputPage 是覆盖整屏的独立页，历史浮层留着也看不见 —— 收起来，
        // 免得关掉输入框后一个陈旧浮层还挂在那儿挡着列表。
        historyOpen = false
        keyboard.open(keyword)
        editTarget = "keyword"
    }

    function onKeyboardAccepted(content) {
        var t = editTarget
        editTarget = ""
        if (t === "cfIps") {
            cfIpText = content.trim()
            saveSettings()
            toast.show("优选 IP 已更新")
        } else if (t === "apiBase") {
            apiBase = content.trim()
            saveSettings()
            toast.show(apiBase.length ? "已切换为自定义中转" : "已恢复直连官方 API")
        } else if (t === "match") {
            // 匹配页的搜索词：改完不自动搜（用户可能还要接着改），
            // 由他自己点「搜索」—— 匹配是"看着结果确认"的操作，别抢着发起请求。
            matchQuery = content.trim()
        } else if (t === "plName") {
            // 新建歌单的名字。空名字不在这里拦 —— 交给 createPlaylist 统一报 E_NAME，
            // 免得"什么算空"在两处各有一份判断（带上前后空格时两边很容易不一致）。
            var res = createPlaylist(content, plNewType)
            if (!res.ok) { toast.show(plErrText(res.err)); plNewSong = null; return }
            var msg = "已创建：" + cleanPlaylistName(content) + "（"
                    + playlistTypeText(plNewType) + "）"
            // 从「加入歌单」页新建的：把这首歌一并放进去。
            // 加不进去（比如中途文件被删了）不算失败 —— 歌单已经建好了，
            // 把原因附在提示里，别让用户以为歌单也没建成。
            var fromPick = !!plNewSong
            if (fromPick) {
                var r2 = addSongToPlaylist(res.id, plNewSong)
                if (r2.ok) msg = "已创建并加入：" + cleanPlaylistName(content) + "（"
                                + playlistTypeText(plNewType) + "）"
                else       msg += "（" + plErrText(r2.err) + "）"
            }
            plNewSong = null
            toast.show(msg)
            if (fromPick) closeAddPick()
        } else if (t === "plRename") {
            // 重命名歌单。目标 id 在 beginRenamePlaylist 弹键盘前就已存进 plRenameId。
            var rid = plRenameId
            plRenameId = ""
            var rres = renamePlaylist(rid, content)
            if (!rres.ok) { toast.show(plErrText(rres.err)); return }
            toast.show("已重命名：" + cleanPlaylistName(content))
        } else {
            keyword = content.trim()
            if (keyword.length) doSearch()
        }
    }

    // ============================================================
    // 导航
    // ============================================================
    // 🔴 设置页的"来处"必须**单独记一份**，不能复用 backPage（backPage 是加歌页在用）。
    //    踩过的坑：openLogin 里写 `backPage = "settings"` —— 于是从设置页进登录页再返回，
    //    backPage 已被污染成 "settings"，之后在设置页点返回 ⇒ goBack() 把自己又赋给
    //    自己 ⇒ **永远卡在设置页出不去**（用户原话："还没法退出设置界面"）。
    //    症状特别迷惑：返回箭头看得见、点得着、也没报错，只是页面纹丝不动。
    property string settingsBackPage: ""
    function openSettings() { settingsBackPage = page; page = "settings" }
    // 分派式返回：登录页回设置页，其余回"进设置前的那个页"。
    function goBack() {
        if (page === "login") { page = "settings"; return }
        page = settingsBackPage.length ? settingsBackPage : "playlists"
    }
    // 网易云账号页。从设置页进入；返回回到设置页（**不再动 backPage**）。
    function openLogin() { page = "login" }
    function goSearch() { page = "search" }
    // 下拉面板的音乐卡片被点开时，由 MediaBridge 调回来（页面还活着的情况）
    function openPlayer() { page = "player" }
    // 给子页面用的提示接口 —— 子文件里访问不到 main.qml 的 `toast` id
    // （QML 的 id 作用域是单文件内），所以由 controller 转发。
    function toastMsg(msg) { toast.show(msg) }
    // 进本地页顺带刷一次 —— 列表是扫文件夹得出的，文件管理器里加/删的歌立刻可见
    function goLocal() { page = "local"; refreshLocal() }
    // 歌单页与搜索页/本地页是平级的第三个根页面，所以不做 backPage 记录（返回 = 退出插件）。
    function goPlaylists() { page = "playlists" }
    // 进详情页。⚠️ 同时把 backPage 设成歌单页 —— 详情页的返回箭头才会回到列表，
    // 而不是回到"上个页面"（那可能正是用户刚点进来的地方，看起来像返回没反应）。
    function openPlaylist(id) {
        if (!playlistById(id)) { toast.show("歌单不存在"); return }
        plCurId = id
        backPage = "playlists"
        page = "playlist"
    }
    // 关详情页。清掉 plCurId，否则下次从别处进歌单页时 plView 还是旧歌单的数据。
    function closePlaylistDetail() { plCurId = ""; page = "playlists" }

    // ============================================================
    // 手动匹配（本地页 → 匹配页）
    // ============================================================
    // 给「公式覆盖不到」的文件补一个网易云身份：被改过名的、别的工具下的。
    // 搜索词**预填**成从文件名反推的「歌名 歌手」（parseLocalScan 已经算好了），
    // 所以多数情况不用打字：点一下搜、再点一条结果即可。
    function openMatch(i) {
        var rec = localList[i]
        if (!rec) return
        matchRec = rec
        matchQuery = ((rec.name || "") + " " + (rec.artist || "")).trim()
        matchResults = []
        matchBusy = false
        backPage = "local"
        page = "match"
    }

    function closeMatch() {
        matchRec = null
        matchResults = []
        matchBusy = false
        page = "local"
    }

    function editMatchQuery() {
        keyboard.open(matchQuery)
        editTarget = "match"
    }

    function doMatchSearch() {
        var q = String(matchQuery || "").trim()
        if (!q.length) { toast.show("请先输入歌名"); editMatchQuery(); return }
        matchBusy = true
        matchResults = []
        // 复用搜索那套 apiGet：优选 IP / 超时 / 轮询都在里面，没必要再写一遍。
        // 刻意用当前音源（和搜索页一致）—— 匹配出来的是哪个源，就绑哪个源。
        apiGet("types=search&source=" + source + "&name=" + encodeURIComponent(q)
               + "&count=30&pages=1", function(ok, txt) {
            matchBusy = false
            if (!ok) { toast.show("搜索失败，请到设置里测试连通性"); return }
            var arr = null
            try { arr = JSON.parse(txt) } catch (e) { arr = null }
            matchResults = (arr && arr.length) ? arr : []
            if (!matchResults.length) toast.show("没有找到结果")
        })
    }

    // 绑定：把选中的搜索结果写进登记表，回本地页。
    function bindMatch(idx) {
        var s = matchResults[idx]
        if (!s || !matchRec) return
        mapPut(matchRec.file, s, "manual")
        var nm = s.name || ""
        closeMatch()
        refreshLocal()          // 重新装饰：徽标与真名立刻反映出来
        toast.show("已匹配：" + nm)
    }

    function clearMatch() {
        if (!matchRec) return
        mapRemove(matchRec.file)
        closeMatch()
        refreshLocal()
        toast.show("已清除匹配")
    }
    // 停播 + 真正杀掉播放器进程（下次开播会重新拉起）。
    // 与 stopPlayback 的区别：stopPlayback 只停下播放，播放器仍然常驻。
    function restartMpv() {
        killMpv()
        pollTimer.stop()
        playing = false
        paused = true
        timePos = 0
        duration = 0
        statusText = ""
        toast.show("播放器已重置")
    }

    // 根页面（搜索页）的返回箭头 = 请求关闭插件（见顶部 signal 说明）。
    // 其它页面的返回箭头仍在各页内做「回上一页」。
    function exitPlugin() { root.backButtonClicked() }

    // ============================================================
    // 系统媒体接口探测（全只读）
    // ============================================================
    // 判断原厂那批上下文属性是否真的到达了插件的 QML 上下文，
    // 以及 `mediaPlayerManager` 暴露了哪些可读属性 / 可调用槽。
    // 结论写到 /tmp/gdmusic/sysmedia.txt（adb 可直接读），设置页也显示一行。
    function probeSystemMedia() {
        var L = []
        var probes = ["mediaPlayerManager", "mediaManager", "soundCenter", "qmlGlobal",
                      "musicPlayer", "YEnum", "YMediaEntity", "shell", "pluginManager",
                      "mediaSession"]
        for (var i = 0; i < probes.length; i++) {
            // typeof 对未声明标识符是安全的（不会抛），所以这行在 qmlscene 下也成立
            var ok = false
            switch (probes[i]) {
            case "mediaPlayerManager": ok = (typeof mediaPlayerManager !== "undefined"); break
            case "mediaManager":       ok = (typeof mediaManager       !== "undefined"); break
            case "soundCenter":        ok = (typeof soundCenter        !== "undefined"); break
            case "qmlGlobal":          ok = (typeof qmlGlobal          !== "undefined"); break
            case "musicPlayer":        ok = (typeof musicPlayer        !== "undefined"); break
            case "YEnum":              ok = (typeof YEnum              !== "undefined"); break
            case "YMediaEntity":       ok = (typeof YMediaEntity       !== "undefined"); break
            case "shell":              ok = (typeof shell              !== "undefined"); break
            case "pluginManager":      ok = (typeof pluginManager      !== "undefined"); break
            case "mediaSession":       ok = (typeof mediaSession       !== "undefined"); break
            }
            L.push(probes[i] + "=" + (ok ? "yes" : "no"))
        }

        if (typeof mediaPlayerManager !== "undefined" && mediaPlayerManager) {
            var m = mediaPlayerManager
            var props = ["playState", "playerMode", "title", "hasLrc", "duration",
                         "currentPos", "currentSentenceId", "playingMediaId"]
            var snap = []
            for (var j = 0; j < props.length; j++) {
                var v = "-"
                try { v = m[props[j]] } catch (e) { v = "ERR" }
                snap.push(props[j] + ":" + String(v).substring(0, 32))
            }
            L.push("snapshot " + snap.join(" "))
            var fns = ["onClickedPlay", "onClickedPause", "onClickedNext", "onClickedPrev",
                       "playAudio", "setTitle", "setMainLrc", "onResetPlayer", "getPlayingMediaLocalFile"]
            var fs = []
            for (var k = 0; k < fns.length; k++) {
                var isFn = false
                try { isFn = (typeof m[fns[k]] === "function") } catch (e2) { isFn = false }
                fs.push(fns[k] + (isFn ? "+" : "-"))
            }
            L.push("methods " + fs.join(" "))
        }

        if (typeof YEnum !== "undefined") {
            var pv = "?"
            try { pv = YEnum.PLAYING } catch (e3) { pv = "ERR" }
            L.push("YEnum.PLAYING=" + pv)
        }

        var txt = L.join("\n")
        sysMediaProbe = L.join(" | ")
        // 「官方会话」= 宿主 mediaSession（本插件真正在用的通道）；
        // 「原厂」= mediaPlayerManager（词典笔自带的播放器单例，只读参考）
        sysMediaState = ((typeof mediaSession       !== "undefined") ? "官方会话✓" : "官方会话✗")
                      + ((typeof mediaPlayerManager !== "undefined") ? " 原厂✓" : " 原厂✗")
        console.log("GD_SYSMEDIA " + L.join(" ; "))
        if (typeof shell !== "undefined" && shell) {
            shell.startDetached("mkdir -p " + stateDir + "; printf '%s' "
                                + shellQuote(txt + "\n") + " > " + sysMediaFile + "; true")
        }
        return txt
    }

    function onProbeSysMedia() {
        probeSystemMedia()
        toast.show("系统媒体接口：" + sysMediaState)
    }

    // ============================================================
    // 生命周期
    // ============================================================
    Component.onCompleted: {
        loadSettings()
        loadHistory()
        // 媒体会话桥：把宿主对象传进去（singleton 的上下文不一定继承 root context，
        // 传引用就没有这个悬念）。attach 之后它自己轮询 now.json 上报状态。
        MediaBridge.attach(root, {
            "session": (typeof mediaSession !== "undefined") ? mediaSession : null,
            "shell":   (typeof shell        !== "undefined") ? shell        : null,
            "global":  (typeof qmlGlobal    !== "undefined") ? qmlGlobal    : null,
            "enabled": sysMedia,
            "holdOnStop": holdOnStop
        })
        reconcile()          // 可能是「回到仍在后台播放的播放器」，不是冷启动
        refreshLocal()       // 扫下载文件夹（列表不做本地登记，文件夹就是唯一真源）
        dlRecover()          // 认领关插件期间还在后台跑的下载（.meta/.st/.part，见函数注释）
        probeSystemMedia()   // 探一次系统媒体接口（只读），结果落 /tmp/gdmusic/sysmedia.txt
        // 「打开插件页就抓一张」的自检口：哨兵 /tmp/penmods_shot_boot 存在才抓。
        // 用途是**一次性验证 grabToImage 在这台设备上到底能不能出图**（历史上
        // 所有外部截屏路都失败了，这一条从没试过）—— 抓得到就等于打开了「远程
        // 看屏幕」这条路；抓不到会写 /tmp/penmods_shot.log 说明原因。
        // 平时哨兵不存在 ⇒ 零开销，也不留任何文件。
        if (typeof shell !== "undefined" && shell
            && String(shell.exec("test -f /tmp/penmods_shot_boot && echo Y || echo N")).trim().charAt(0) === "Y") {
            shotPollTimer.restart()
            grabShot()
        }
        // 冷启动且手上没有搜索结果时，直接把历史摊开 ——
        // 否则「历史搜索」要用户先发现那个小按钮才用得上。
        if (searchHistory.length && !results.length) historyOpen = true
    }

    // 销毁时**刻意不动播放器**：
    // 播放由 mpv 里的 lua 负责，关掉插件页只是关掉遥控器，音乐继续放。
    // （要真正停下，播放页有停止按钮，设置页有「重启播放器」。）
    //
    // 媒体会话同理**不在这里 end()** —— 音乐还在放，面板上的卡片和按钮就该继续可用。
    // 监听器活在 MediaBridge（singleton，归 engine）里，不随这个页面消失。
    // 真正的交还时机：保留期超时、停止态再按一次停止、播放器真的被外部杀掉。
    // （停播本身**不交还** —— 一交还面板上的卡片就消失了，详见 MediaBridge。）
    Component.onDestruction: {
        MediaBridge.detach(root)
        pollTimer.stop()
        apiPollTimer.stop()
        // dlPollTimer 刻意不停：下载是在后台 shell 里跑的，插件页关掉照样继续，
        // 重进插件时 dlPending 还在，定时器会自己接回去。
    }

    // 轮询 lua 写出的 now.json。
    // 比直接问 mpv 更省（一次 cat），而且拿到的正是常驻播放器的权威状态 ——
    // 插件关着的时候 lua 照样在写，所以重进插件能无缝接回。
    Timer {
        id: pollTimer
        interval: 1000
        repeat: true
        running: false
        property int fails: 0

        onTriggered: {
            // 这里必须有 typeof 兜底：少这一条判断，每触发一次就是一条
            // ReferenceError，而设备的日志是写 flash 的（spdlog → stdout → /userdata/applog）。
            // 拿不到 shell 就把轮询停掉 —— 继续跑下去只是在刷错误。
            if (typeof shell === "undefined" || !shell) { pollTimer.stop(); return }
            shell.execAsync("cat " + nowFile + " 2>/dev/null", function(res) {
                var out = (res && res.stdout) ? String(res.stdout).trim() : ""
                if (out.length === 0 || out.charAt(0) !== "{") {
                    pollTimer.fails++
                    if (pollTimer.fails === 10 && root.playing) {
                        root.statusText = "播放器无响应，可到设置里重启播放器"
                    }
                    return
                }
                pollTimer.fails = 0
                var obj = null
                try { obj = JSON.parse(out) } catch (e) { obj = null }
                if (obj) root.applyNow(obj)
            })
        }
    }

    // 远程截图哨兵轮询。running 绑 root.visible：插件页不在前台时不跑，
    // 所以平时零开销（也就没有"调试功能拖累日常使用"的顾虑）。
    Timer {
        id: shotPollTimer
        interval: 700
        repeat: true
        running: root.visible
        onTriggered: {
            if (typeof shell === "undefined" || !shell) { shotPollTimer.stop(); return }
            if (root.shotBusy) return
            shell.execAsync("test -f " + root.shotReq + " && echo Y || echo N", function (res) {
                var out = (res && res.stdout) ? String(res.stdout).trim() : ""
                if (out.charAt(0) === "Y") {
                    // 先删哨兵再抓：grabToImage 是异步的，不先删会在回调返回前
                    // 再次命中，导致连着抓十几张一样的图。
                    shell.exec("rm -f " + root.shotReq)
                    root.grabShot()
                }
            })
        }
    }

    Components.Toast { id: toast; parent: root }

    Components.VirtualKeyboardInput {
        id: keyboard
        parent: root
        onAccepted: root.onKeyboardAccepted(content)
        // 用户按返回取消输入。这里只需清掉"待加入的那首歌"——
        // 页面不主动切：他可能只是打错字想重来（留在选类型那一步，或返回键另选歌单）。
        onDismissed: root.plNewSong = null
    }

    Pages.SearchPage {
        id: searchPage
        visible: root.page === "search"
        controller: root
    }

    Pages.PlayerPage {
        id: playerPage
        visible: root.page === "player"
        controller: root
    }

    Pages.SettingsPage {
        id: settingsPage
        visible: root.page === "settings"
        controller: root
    }

    Pages.LocalPage {
        id: localPage
        visible: root.page === "local"
        controller: root
    }

    // 歌单列表页（顶部第三 tab）。放在本地页之后：这几个页面都是全实例化、靠 visible
    // 切换，z 顺序 = 声明顺序，所以详情页必须声明在列表页之后才能盖住它。
    Pages.PlaylistPage {
        id: playlistPage
        visible: root.page === "playlists"
        controller: root
    }

    Pages.PlaylistDetailPage {
        id: playlistDetailPage
        visible: root.page === "playlist"
        controller: root
    }

    // 手动匹配页（本地页行右侧的 ✓/? 徽标进入）。放在 LocalPage 之后 ——
    // 四个页面是全实例化、靠 visible 切换的，z 顺序 = 声明顺序，后者盖前者。
    Pages.MatchPage {
        id: matchPage
        visible: root.page === "match"
        controller: root
    }

    // 「加入歌单」页（播放页的 ＋、以及三个列表的长按进入）。
    // 声明在最后 = 压在所有页面之上；但它并不与别的页同时可见（靠 page 互斥）。
    Pages.AddToPlaylistPage {
        id: addPickPage
        visible: root.page === "addpick"
        controller: root
    }

    // 网易云账号页（登录 + 歌单同步）。声明在最后，压过设置页。
    Pages.LoginPage {
        id: loginPage
        visible: root.page === "login"
        controller: root
    }
}
