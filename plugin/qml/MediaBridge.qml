// qmldir 里声明成 singleton，这里就必须有 pragma Singleton（与 Theme.qml 一致）；
// 少了它整个插件会加载失败：qmldir defines type as singleton, but no pragma Singleton found
pragma Singleton
import QtQuick 2.12

// ============================================================================
// MediaBridge —— 把 GD音乐接上宿主的官方媒体会话（mediaSession）
//
// ⚠️ 本文件**刻意不 import 宿主的 QML 包**（`com.github.penuniverse`）。
// 原因：qmldir 里的 singleton 一旦加载失败，**所有 `import "."` 的文件都会连坐**
// （实测 qmlscene：Toast.qml / TitleBar.qml 都报 `Type MediaBridge unavailable`）
// ⇒ 整个插件打不开。所以这里只用 QtQuick，枚举用下面的常量（见 PlayState 注释）。
// 这样它也能在 qmlscene 里被完整预检，不留「设备上才知道能不能加载」的悬念。
//
// 上游在 18af402 给插件系统补了这条通道（PenMods 的 src/media/MediaSession）：
// 插件把自己在放的内容上报给宿主，下拉快捷面板就会出现音乐卡片，并且卡片上的
// 上一首 / 播放暂停 / 下一首 / 停止能回调给插件。相关 issue：Lyrecoul/PenMods#8。
//
// ----------------------------------------------------------------------------
// 为什么必须做成 QML singleton，而不是 main.qml 里的一个普通对象：
//
//   插件页由宿主的 YDynamicPageStack 装载，**退出时会被 destroy**
//   （commons/YDynamicPageStack.qml 的 _safeDestroy，注释里写明是「无缓存版本」）。
//   而 GD音乐是「后台播放」——真正在放的是 mpv 里的 gdnext.lua，插件页只是遥控器。
//   如果把媒体会话的监听挂在页面里，关掉插件页之后就会出现最难受的状态：
//   面板显示着歌名和进度、按钮却是死的（因为监听器随页面一起没了）。
//
//   QML singleton 的实例归 engine 所有 —— 本插件早就在用同一个机制
//   （qmldir 里的 `singleton Theme`），所以它能活得比页面久。
//
// ----------------------------------------------------------------------------
// 它也刻意**不依赖页面**：自己轮询 now.json、自己给 mpv 发命令。
// 页面只负责喂进来「只有它会去取的东西」：歌词数组、封面地址。
//
// 也不依赖任何 context property：session / shell / qmlGlobal 全部由页面在
// attach() 时传进来 —— singleton 的 QML 上下文能否继承 root context 是不确定的，
// 传引用就没有这个悬念。
//
// 状态来源 = lua 写的 /tmp/gdmusic/now.json（字段见 gdnext.lua 的 write_now）：
//   status(playing|paused|loading|stopped|idle)  pos(秒)  dur(秒)  index(1基)
//   name  artist  ts(unix 秒)  reason
//
// 停播（面板的 ✕ / 插件页的停止按钮）会**当场回收播放器进程**，但**保留会话**：
// 面板上的音乐卡片留着（歌名在、进度归零），▶ 随时能把歌接回来 —— 那时由
// ensurePlayer 冷启动播放器（约 1~2 秒）。详见 holdSession / requestStop。
//
// 诊断日志 /tmp/gdmusic/mediabridge.log（tmpfs，不写 flash）：
//   attach / claim / ctrl xxx / hold / hb(每 30 拍一次心跳) —— 心跳就是
//   「关掉插件页之后 bridge 还活着」的证据。
// ============================================================================
QtObject {
    id: bridge

    readonly property string pluginId:  "com.gdmusic.player"

    // 与宿主 src/media/MediaSession.h 的 `enum PlayState { Stopped=0, Playing=1, Paused=2 }`
    // 一致。这几个值同时是 PluginSDK.h 里 C ABI 的 PLUGIN_MEDIA_* 取值。
    // 之所以不写 `MediaSession.Playing`：那需要 import 宿主的 QML 包，理由见文件头。
    // （名字用驼峰小写：QML 不允许属性名以大写字母开头。）
    readonly property int psStopped: 0
    readonly property int psPlaying: 1
    readonly property int psPaused:  2
    readonly property string pluginDir: "/userdisk/PenMods/plugins/gdmusic"
    readonly property string ipcScript: pluginDir + "/bin/gdipc.pl"
    readonly property string luaScript: pluginDir + "/bin/gdnext.lua"
    readonly property string mpvSock:   "/tmp/gdmusic.sock"
    readonly property string stateDir:  "/tmp/gdmusic"
    readonly property string queueFile: stateDir + "/queue.json"
    readonly property string nowFile:   stateDir + "/now.json"
    readonly property string logFile:   stateDir + "/mediabridge.log"

    // 播放器本体与唤醒锁。**停播会把播放器进程回收**（见 holdSession / killMpv），
    // 而那时插件页很可能已经关了（用户只是从面板按了 ▶）—— 所以桥必须自己有能力
    // 把它冷启动回来（见 ensurePlayer）。这三项与 main.qml 的 mpvBin / luaScript /
    // wakeLockFile 一一对应，改一处要一起改。
    readonly property string mpvBin:       "/userdisk/mpv/mpv"
    readonly property string wakeLockFile: "/tmp/audio_wakelocks/gdmusic.lock"

    // --- 由页面注入的宿主对象 ---
    property var session:   null   // mediaSession（context property）
    property var shellRef:  null   // shell（context property）
    property var globalRef: null   // qmlGlobal（context property，可选）
    property var page:      null   // 当前打开的插件页；关掉后为 null

    // --- 状态 ---
    property bool   enabled: true  // 设置页开关；false = 完全不碰系统媒体
    property bool   owns:    false // 是否已持有官方会话
    property string status:  "未启用"
    property var    lyricLines: [] // 页面喂进来的 [{time, text}]
    property string cover:  ""
    property int    lastIndex: -1  // now.json 的 index（1 基）
    property double lastPos:   -1
    property double revokedUntil: 0
    property int    tick: 0
    property string lastStatus: ""
    property bool   logStarted: false

    // --- 停播后的「保留期」（可选，**默认关**）---
    // **默认（holdOnStop=false）**：停播 → 停播 + 回收播放器 + 交还会话。宿主的音乐
    //   卡片随之消失、面板回落设置视图 —— 与原厂播放器的 ✕ 语义一致（「按了停止就
    //   不再显示音乐」）。也不用担心「以后又自己播起来」：播放器进程当场被 pkill 掉。
    // **打开开关（holdOnStop=true）**：停播但**不交还会话** —— 卡片留在面板上（歌名在、
    //   进度归零），▶ 随时能接回。这个选项为什么存在、以及为什么它成立：
    //   宿主 qml/components/YQuickMusicPlayer.qml 用 `mediaSession.active` 决定卡片是否
    //   可见（YQuickSettingLayer 的 pluginMusicAvailable）⇒ 一旦 end() 卡片立刻消失、
    //   面板回落，「停播后还想从面板续播」就做不到了，只能重开插件。
    //   ⚠️ 宿主侧的事实（读过 src/media/MediaSession.cpp 确认，不是猜的）：
    //     `setPlayState(Stopped)` **不会**结束会话 —— 它只 syncPositionTimer() 再
    //     emit playStateChanged()，完全不碰 mActive。只有 end() / 被别的插件 begin()
    //     抢占 / 插件被卸载才会让 active 变 false。所以「按 ✕ 面板会不会关」：
    //     原厂播放器那边是**宿主判据**决定的（hostMusicAvailable 要求
    //     playState !== STOPPED），插件会话下**由插件自己说了算**。
    // ⇒ 两种模式共有：**播放器进程都是停播当场回收**（holdSession 里的 killMpv）——
    //   它不过是几 MB 常驻加一个无主的 IPC socket，而下次开播靠 ensurePlayer() 冷启动
    //   回来（1~2 秒）。保留期留下的是**会话**，不是进程。
    // ⇒ 保留期到点（holdMs）交还会话；停止态再按一次 ✕ = 立刻收工（不等超时）。
    property bool   holdOnStop: false         // 设置项注入；默认关 = 停播即交还（原厂语义）
    readonly property int holdMs: 3 * 60 * 1000
    property double holdUntil: 0              // 仅用于日志
    property bool   mpvAlive: true            // 上一拍 poll 时 IPC socket 在不在

    // ========================================================================
    // 基础工具
    // ========================================================================
    function q(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    function stamp() {
        var d = new Date()
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(d.getHours()) + ":" + p2(d.getMinutes()) + ":" + p2(d.getSeconds())
    }

    function log(msg) {
        if (!shellRef) return
        shellRef.startDetached("mkdir -p " + stateDir + "; printf '%s\\n' "
                               + q(stamp() + " " + msg) + " >> " + logFile + "; true")
    }

    // ========================================================================
    // 页面登记
    // ========================================================================
    function attach(pageObj, opts) {
        page = pageObj
        var o = opts || {}
        session   = o.session   || null
        shellRef  = o.shell     || null
        globalRef = o.global    || null
        enabled   = (o.enabled === undefined) ? true : !!o.enabled
        if (o.holdOnStop !== undefined) holdOnStop = !!o.holdOnStop

        if (!logStarted) {
            logStarted = true
            // 首次登记时截断日志，避免无限增长
            if (shellRef)
                shellRef.startDetached("mkdir -p " + stateDir + "; printf '%s\\n' "
                                       + q(stamp() + " === MediaBridge init ===") + " > " + logFile + "; true")
        }
        log("attach session=" + (session ? "yes" : "NO")
            + " shell=" + (shellRef ? "yes" : "NO")
            + " global=" + (globalRef ? "yes" : "NO")
            + " enabled=" + enabled)
        syncTimer()
        kick()
    }

    function detach(pageObj) {
        if (page === pageObj) page = null
        log("detach owns=" + owns + " (页面销毁；后台播放继续，会话保留)")
        syncTimer()
    }

    function setEnabled(v) {
        enabled = !!v
        if (!enabled) release()
        syncTimer()
        log("enabled=" + enabled)
    }

    // 设置页的「停止后保留控制条」开关。关掉时如果当前正处在停止态，立刻交还
    // （正在播/暂停的话不动它 —— onNow 会在真停下时走 release 分支）。
    function setHoldOnStop(v) {
        holdOnStop = !!v
        if (!holdOnStop) {
            cancelHold("设置关闭")
            if (owns && (lastStatus === "stopped" || lastStatus === "idle" || lastStatus === ""))
                release()
        }
        log("holdOnStop=" + holdOnStop)
    }

    function setStatusText(t) { status = String(t) }

    // ========================================================================
    // 轮询
    // ========================================================================
    // 只在「插件页开着」或「已持有会话」时跑：页面关掉且没有会话 = 没什么可同步的，
    // 不必每秒 fork 一个 cat。
    function syncTimer() {
        var want = enabled && (page !== null || owns)
        if (want !== bridgeTimer.running) {
            bridgeTimer.running = want
            if (want) bridgeTimer.restart()
        }
    }

    function kick() {
        if (!enabled) return
        if (!bridgeTimer.running) bridgeTimer.running = true
        poll()
    }

    function poll() {
        if (!enabled || !shellRef) { bridgeTimer.running = false; return }
        // 一次 execAsync 同时取两样东西：now.json 的内容 + IPC socket 还在不在。
        // 后半段很关键 —— 保留期（hold）里 lua 已经不再写 now.json，所以
        // 「ts 过期」不能用了，只能靠 socket 判断播放器是否还活着，
        // 否则 mpv 被 OOM 杀掉之后卡片会一直挂到超时。
        // 前半段用 -f 区分「文件不存在」（→ 明确输出 NOFILE）与「命令整体失败」
        // （→ stdout 为空），两者对桥的意义完全不同，见下面的解析注释。
        shellRef.execAsync("if [ -f " + nowFile + " ]; then cat " + nowFile
            + "; else printf 'NOFILE'; fi; printf '\\n@@\\n'; "
            + "if [ -S " + mpvSock + " ]; then printf 'S\\n'; else printf 'D\\n'; fi",
            function(res) {
                var raw = (res && res.stdout) ? String(res.stdout) : ""
                // 🔴 命令整体没回来（ShellExecutor 偶发失败 / 被拒绝）⇒ 这一拍**什么都不判定**，
                //    保持上一次的状态。否则空 stdout 会被当成「没在放」而把会话交还
                //    ⇒ 面板卡片会毫无理由地消失一下再回来。
                //    正常输出一定含分隔符，所以拿它当「这一拍有效」的判据。
                if (raw.indexOf("@@") < 0) return
                var parts = raw.split("@@")
                var out = String(parts[0] || "").trim()
                var o = null
                if (out.length && out.charAt(0) === "{") {
                    try { o = JSON.parse(out) } catch (e) { o = null }
                }
                // 🔴 解析 socket 存活标志时**必须先 trim**。
                // 命令输出形如 `<换行>@@<换行>S<换行>`，所以 parts[1] = "\nS\n"，
                // 直接 charAt(0) 只会拿到换行符 ⇒ 永远判成「播放器不在」
                // ⇒ onNow 分支①（!mpvAlive → release）每拍都触发
                // ⇒ 会话 claim/release 死循环、面板卡片闪烁或干脆不出现。
                // （分隔符用 printf '\n@@\n' 而不是 '-'，是为了不让 busybox 把
                //   以 '-' 开头的参数当选项 —— 代价就是这个前导换行。）
                var alive = (parts.length < 2)
                    ? bridge.mpvAlive                        // 分隔符后半段也缺：沿用上一拍
                    : (String(parts[1]).trim().charAt(0) === "S")
                bridge.onNow(o, alive)
            })
    }

    function onNow(o, alive) {
        tick++
        mpvAlive = (alive === undefined) ? true : !!alive
        if (tick % 30 === 0)
            log("hb tick=" + tick + " owns=" + owns + " status=" + lastStatus
                + " hold=" + (holdTimer.running ? "y" : "n")
                + " mpv=" + (mpvAlive ? "y" : "n"))

        if (!session) { status = "宿主无 mediaSession"; return }

        var st = o ? String(o.status || "") : ""

        // ① 播放器已经不在（IPC socket 没了）⇒ 会话没有意义，交还。
        //    保留期里 lua 不再写 now.json，所以「ts 过期」这条判据失效，
        //    只能靠 socket —— 否则 mpv 被 OOM 杀掉后卡片会一直挂到超时。
        //    ⚠️ 例外：**保留期里 socket 不在是预期状态** —— 那是我们在 holdSession
        //    里主动回收的（停播就回收，不留进程）。这时绝不能交还会话，否则卡片当场
        //    消失，又回到「停播后只能重开插件才能再播」；用户按 ▶ 时由 resumeAt →
        //    ensurePlayer 冷启动回来即可。
        if (owns && !mpvAlive && !holdTimer.running) {
            status = "播放器已退出"
            release()
            return
        }

        // ② 没在放（人为停播 / 队列播完 / mpv 刚起来）：
        //    **刻意不交还会话** —— 会话一交还，宿主的音乐卡片就消失、面板回落，
        //    用户会发现「停播后再也没法从面板继续播，只能重开插件」。
        //    改成进入保留期：卡片留着、▶ 随时接回，holdMs 到点才真正释放。
        if (!o || st === "" || st === "stopped" || st === "idle") {
            lastStatus = (o && st) ? st : "stopped"
            if (st === "idle") status = "播放器空闲"
            else if (st === "stopped") status = "已停止 · 可再次播放"
            else status = "未在播放"
            if (owns && !holdTimer.running) holdSession()
            syncTimer()   // 没会话也没页面 ⇒ 停掉每秒轮询（自举失败时靠这句收尾）
            return
        }

        // ③ 声称在放、但 now.json 超过 8 秒没更新 ⇒ 播放器实际已经不响应了。
        if (typeof o.ts === "number" && (Date.now() / 1000 - o.ts) > 8) {
            status = "状态过期"
            if (owns) autoRelease("stale")
            return
        }

        cancelHold("恢复播放")   // 真的在放了，保留期结束
        lastStatus = st

        // 有内容在放 → 确保持有会话
        if (!owns) {
            if (Date.now() < revokedUntil) return
            if (!session.begin || !session.begin(pluginId)) {
                status = "会话被占用"
                log("begin FAILED (被其它插件占用？)")
                return
            }
            owns = true
            log("claim ok: " + pluginId)
            syncTimer()
        }

        // 正在播放时把 timer 拉起来（后台路径：页面已关、只有会话在跑）
        if (!bridgeTimer.running) bridgeTimer.running = true

        apply(o)
    }

    function apply(o) {
        var st  = String(o.status || "")
        var idx = parseInt(o.index, 10)
        if (isNaN(idx)) idx = 0
        var pos = (typeof o.pos === "number" && o.pos >= 0) ? o.pos : 0
        var dur = (typeof o.dur === "number" && o.dur > 0) ? o.dur : 0

        var title = String(o.name || "")
        if (session.title !== title) session.title = title
        var artist = String(o.artist || "")
        if (session.artist !== artist) session.artist = artist
        var dms = Math.round(dur * 1000)
        if (session.duration !== dms) session.duration = dms
        if (cover && session.cover !== cover) session.cover = cover

        var ps = (st === "paused") ? psPaused : psPlaying
        if (session.playState !== ps) session.playState = ps

        // 进度：会话激活且处于播放态时宿主自己按 500ms 推进，插件只在
        // 「换歌 / 跳转」时校正 —— 每拍都写会和宿主的定时器互相打架（进度条抖）。
        var cur = session.position / 1000.0
        if (idx !== lastIndex || Math.abs(cur - pos) > 1.5)
            session.position = Math.round(pos * 1000)
        lastIndex = idx
        lastPos = pos

        // 歌词：数组由页面喂进来，当前行在这里按 pos 自己推 ——
        // 这样即使页面已经销毁，歌词行也还在往前走。
        var line = lyricAt(pos)
        if (session.mainLyric !== line) session.setLyrics(line, "")

        status = (st === "paused") ? "已暂停" : "播放中"
    }

    function lyricAt(pos) {
        if (!lyricLines || !lyricLines.length) return ""
        var idx = -1
        for (var i = 0; i < lyricLines.length; i++) {
            if (lyricLines[i].time <= pos + 0.2) idx = i
            else break
        }
        return (idx >= 0) ? String(lyricLines[idx].text || "") : ""
    }

    function release() {
        cancelHold("release")
        if (owns && session && session.end) session.end()
        if (owns) log("release")
        owns = false
        status = "未在播放"
        syncTimer()
    }

    function autoRelease(why) {
        if (!owns) return
        log("auto-release: " + why)
        release()
    }

    // ========================================================================
    // 停播后的「保留期」
    // ========================================================================
    // 停播但**不交还会话** —— 宿主的音乐卡片留在面板上（它只看 mediaSession.active），
    // 于是 ▶ / 下一首 / 上一首 都还在，点下去由 resumeAt() 把歌接回来。
    // 这是「按了停止就只能重开插件才能再播」那个问题的正解。
    function holdSession() {
        if (!owns) return
        if (!holdOnStop) { release(); killMpv(); return }
        holdUntil = Date.now() + holdMs
        holdTimer.restart()
        if (session) {
            // 只清「正在放」的痕迹；歌名/歌手**留着**，让用户知道刚停下的是哪首。
            if (session.playState !== psStopped) session.playState = psStopped
            if (session.position  !== 0) session.position = 0
            if (session.duration  !== 0) session.duration = 0
            if (session.mainLyric !== "") session.setLyrics("", "")
        }
        lastStatus = "stopped"
        status = "已停止 · 可再次播放"
        // 🔴 停播就**当场回收播放器进程** —— 不设等待期、不留常驻进程。
        //    暂停/idle 的 mpv 仍然占几 MB + 一个无主的 IPC socket；而「下次开播」
        //    靠 ensurePlayer() 冷启动就够了（约 1~2 秒）。保留期留下的是**会话**
        //    （面板上的卡片和 ▶），不是进程。
        killMpv()
        syncTimer()
        log("hold：保留会话 " + Math.round(holdMs / 1000) + "s + 已回收播放器（卡片留着，▶ 可接回）")
    }

    function cancelHold(reason) {
        if (!holdTimer.running) { holdUntil = 0; return }
        holdTimer.stop()
        holdUntil = 0
        log("hold 结束" + (reason ? ": " + reason : ""))
    }

    function holdExpired() {
        log("hold 超时 -> 交还会话（播放器在停播当时就已回收）")
        holdUntil = 0
        release()
        killMpv()   // 幂等兜底：万一这期间又被谁拉起来了
    }

    // 真正杀掉常驻播放器（**停播当场** / 保留期到点兜底 / 停止态再按一次 ✕）。
    // ⚠️ 与 main.qml 的 killMpv 同源（那边服务设置页的「重启播放器」），改一处要一起改。
    //   · 命令里的 [i]nput 括号写法是为了不让 pkill 匹配到执行它自己的那个 sh；
    //   · 必须连 socket 一起删：mpv 被 SIGKILL 时不清理自己的 IPC socket，留下僵尸
    //     文件会让下一次 ensurePlayer 误判「播放器还在」而不去重启它；
    //   · 唤醒锁/状态文件兜底删掉：正常路径由 lua 的 shutdown 自己清理。
    function killMpv() {
        if (!shellRef) { mpvAlive = false; return }
        shellRef.exec("LC_ALL=C pkill -f '[i]nput-ipc-server=" + mpvSock + "' 2>/dev/null; "
                      + "rm -f " + mpvSock + " " + stateDir + "/probe.txt "
                      + wakeLockFile + " " + nowFile + "; true")
        mpvAlive = false
    }

    // ========================================================================
    // 面板 → 播放器
    // ========================================================================
    // 幂等拉起常驻播放器：socket 活着 = 后台还有播放器，**绝不能重启它**，
    // 否则正在放的歌会断。
    // 桥自己也必须有一份 —— 因为停播会回收播放器进程，而那时插件页很可能已经关了
    // （用户只是从面板按了 ▶），没有页面可以帮忙拉起来。
    // ⚠️ 与 main.qml 的 buildEnsurePlayerCmd 同源，改一处要一起改。
    function buildEnsurePlayerCmd() {
        return "alive=0; "
             + "if [ -S " + mpvSock + " ]; then "
             + "LC_ALL=C " + q(ipcScript) + " " + q(mpvSock) + " pid > " + stateDir + "/probe.txt 2>/dev/null; "
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

    function ensurePlayer() {
        if (!shellRef) return
        shellRef.startDetached(buildEnsurePlayerCmd())
    }

    function mpvRun(args) {
        if (!shellRef) return
        var cmd = "LC_ALL=C " + q(ipcScript) + " " + q(mpvSock) + " cmd"
        for (var i = 0; i < args.length; i++) cmd += " " + q(args[i])
        shellRef.exec(cmd)
    }

    // 与 main.qml 的 buildScriptMsgCmd 同一手法：先等 socket 就绪再发，
    // 否则紧跟着冷启动 mpv 发出的命令会丢。
    function sendMsg(name) {
        if (!shellRef) return
        shellRef.startDetached("i=0; while [ $i -lt 60 ]; do "
            + "if [ -S " + mpvSock + " ]; then "
            + "LC_ALL=C " + q(ipcScript) + " " + q(mpvSock) + " cmd script-message " + name
            + " >/dev/null 2>&1; break; "
            + "fi; i=$((i+1)); sleep 0.25; done; true")
    }

    // 面板上的「播放」可能是在 lua 已经 stop（index=-1、conf=nil）、**甚至播放器进程
    // 已被回收**之后按下的。那时唯一能接回来的入口是 gd-load —— 它播的是 queue.json
    // 里的 index 字段，而后台用面板切过歌之后这个字段已经过期 ⇒ 先把当前下标写回去，
    // 再确保播放器在（ensurePlayer），最后发 gd-load。
    function resumeAt(idx) {
        if (!shellRef) return
        if (idx === undefined || idx === null) idx = lastIndex
        idx = parseInt(idx, 10)
        if (isNaN(idx)) idx = 0
        shellRef.execAsync("cat " + queueFile + " 2>/dev/null", function(res) {
            var out = (res && res.stdout) ? String(res.stdout).trim() : ""
            var obj = null
            try { obj = JSON.parse(out) } catch (e) { obj = null }
            if (!obj || !obj.list || !obj.list.length) {
                log("resume: queue.json 不可用，无法接回")
                if (owns) holdSession()   // 续上保留期，别让卡片卡在死状态
                return
            }
            // 兜底：lastIndex 可能还没建立（主程序重启后 bridge 是全新的），
            // 或调用方传了个不可用的下标 —— 退回 queue.json 自己记的下标，再不行就第 1 首。
            if (idx < 1) idx = parseInt(obj.index, 10)
            if (isNaN(idx) || idx < 1) idx = 1
            if (idx > obj.list.length) idx = obj.list.length
            obj.index = idx
            var json = JSON.stringify(obj)
            shellRef.startDetached("mkdir -p " + stateDir + "; printf '%s' " + q(json) + " > " + queueFile + "; true")
            // 停播时播放器已被回收 ⇒ 先把它拉回来（幂等：socket 还活着就跳过），
            // 再用 sendMsg 的「等 socket 就绪」循环把 gd-load 发进去 —— 否则命令会丢。
            // 冷启动到能收命令通常 1~2 秒，用户按 ▶ 后会感觉到这么一点等待。
            ensurePlayer()
            sendMsg("gd-load")
            log("resume at " + idx)
            kick()
        })
    }

    function onPlayRequested() {
        log("ctrl play status=" + lastStatus)
        if (lastStatus === "paused") { mpvRun(["set_property", "pause", "false"]); return }
        resumeAt(lastIndex)
    }

    function onPauseRequested() {
        log("ctrl pause")
        mpvRun(["set_property", "pause", "true"])
    }

    function onToggleRequested() {
        log("ctrl toggle status=" + lastStatus)
        if (lastStatus === "playing" || lastStatus === "loading")
            mpvRun(["set_property", "pause", "true"])
        else if (lastStatus === "paused")
            mpvRun(["set_property", "pause", "false"])
        else
            resumeAt(lastIndex)
    }

    function onNextRequested() {
        log("ctrl next status=" + lastStatus)
        if (lastStatus === "stopped" || lastStatus === "idle" || lastStatus === "")
            resumeAt(lastIndex + 1)
        else
            sendMsg("gd-next")
        kick()
    }

    function onPrevRequested() {
        log("ctrl prev status=" + lastStatus)
        if (lastStatus === "stopped" || lastStatus === "idle" || lastStatus === "")
            resumeAt((lastIndex > 1) ? lastIndex - 1 : 1)
        else
            sendMsg("gd-prev")
        kick()
    }

    // 停止的语义分两拍（面板的 ✕ 与插件页的停止按钮都走这里）：
    //   第 1 下（正在播/暂停）→ 停播 + **当场回收播放器进程**，但**保留会话**：
    //                          面板上的卡片留着（歌名在、进度归零），▶ 能接回。
    //   第 2 下（已在停止态）→ 彻底收工：交还会话（卡片消失、面板回落设置视图）。
    function requestStop() {
        log("stop requested status=" + lastStatus + " owns=" + owns)
        sendMsg("gd-stop")
        // 没有会话（例如「系统媒体控制」开关关着）也要回收播放器 ——
        // 用户按的是停止，播放和播放器就该一起停下。
        if (!owns) { killMpv(); return }
        if (lastStatus === "stopped" || lastStatus === "idle" || lastStatus === "") {
            log("停止态再按一次 -> 交还会话")
            cancelHold("手动收工")
            release()
            killMpv()
            return
        }
        holdSession()
    }

    function onStopRequested() {
        requestStop()
    }

    function onSeekRequested(ms) {
        var v = Math.max(0, Number(ms))
        log("ctrl seek " + Math.round(v))
        mpvRun(["seek", String(v / 1000.0), "absolute"])
        if (session) session.position = Math.round(v)
    }

    function onOpenRequested() {
        log("ctrl open pageAlive=" + (page ? "yes" : "no"))
        if (page && page.openPlayer) { page.openPlayer(); return }
        // 插件页不在（音乐在后台放）。宿主没有「按插件 id 打开页面」的公开入口，
        // 只能给一句提示 —— 总比点下去毫无反应强。
        try {
            if (globalRef && globalRef.showToast)
                globalRef.showToast("GD音乐正在后台播放，打开插件可查看")
        } catch (e) {
            log("open feedback failed: " + e)
        }
    }

    function onSessionRevoked() {
        // 别的插件接管了会话。按官方文档「应停止播放」，但**不要**在这里调 end()：
        // 宿主的 MediaSession::end() 没有属主校验，会把新属主的会话一起关掉。
        // 这里只停自己的播放 + 进入冷却，避免两个插件互相抢。
        log("revoked -> 停止本地播放 + 回收播放器")
        sendMsg("gd-stop")
        cancelHold("被接管")
        owns = false
        // 会话已经归别人 ⇒ 我们这边再没有任何入口能把这首歌放起来（面板显示的是对方的
        // 内容），播放器留着就只是个无人回收的常驻进程；直接收掉，用户下次打开插件页
        // 开播时会由 ensurePlayer 冷启动回来。
        killMpv()
        revokedUntil = Date.now() + 15000
        status = "被其它插件接管"
        syncTimer()
    }

    // ========================================================================
    // 页面喂进来的数据
    // ========================================================================
    function setLyrics(lines) {
        lyricLines = (lines && lines.length) ? lines.slice(0) : []
        if (owns && session) {
            var line = lyricAt(lastPos > 0 ? lastPos : 0)
            if (session.mainLyric !== line) session.setLyrics(line, "")
        }
    }

    function setCover(url) {
        cover = String(url || "")
        if (owns && session && session.cover !== cover) session.cover = cover
    }

    // ========================================================================
    // ⚠️ QtObject **没有**默认属性 —— 子对象必须写成属性，不能直接裸写在花括号里
    // （否则报 "Cannot assign to non-existent default property"）。
    // ========================================================================
    // ⚠️ 一个已知的平台限制（别试图在这里做「启动即接管」）
    // ========================================================================
    // QML singleton 是**惰性实例化**的：只有别处真的访问了 `MediaBridge` 才会创建。
    // 而插件 QML 只有在**用户打开插件页**时才被宿主加载（plugin 目录扫描只读
    // metadata.json，不碰 QML）。所以：
    //   · 宿主被 guardian 重拉 / 升级重启时，mpv 还在后台放歌，但本地没有
    //     MediaBridge 实例 ⇒ 面板上不会出现卡片，直到用户打开一次插件页
    //     （attach 会立刻 kick 一次并把会话接回来）。
    //   · 想做到「重启后自动接管」需要宿主在启动时预加载插件 QML —— 那是宿主侧的事。
    // 这里曾试过在 Component.onCompleted 里自举，实测**不会被触发**，故删除。

    property Timer bridgeTimer: Timer {
        interval: 1000
        repeat: true
        running: false
        onTriggered: bridge.poll()
    }

    // 保留期计时器：停播后 holdMs 之内面板卡片一直留着；到点才真正交还会话 + 杀 mpv。
    // repeat:false + 在「真的重新放起来」时被 cancelHold() 取消（见 onNow ③）。
    property Timer holdTimer: Timer {
        interval: bridge.holdMs
        repeat: false
        running: false
        onTriggered: bridge.holdExpired()
    }

    property Connections sessionLinks: Connections {
        target: bridge.session
        ignoreUnknownSignals: true

        function onPlayRequested()      { bridge.onPlayRequested() }
        function onPauseRequested()     { bridge.onPauseRequested() }
        function onToggleRequested()    { bridge.onToggleRequested() }
        function onNextRequested()      { bridge.onNextRequested() }
        function onPrevRequested()      { bridge.onPrevRequested() }
        function onStopRequested()      { bridge.onStopRequested() }
        function onSeekRequested(ms)    { bridge.onSeekRequested(ms) }
        function onOpenRequested()      { bridge.onOpenRequested() }
        function onSessionRevoked()     { bridge.onSessionRevoked() }
    }
}
