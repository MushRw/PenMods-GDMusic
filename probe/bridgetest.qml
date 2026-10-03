import QtQuick 2.12
import "qml"

// 媒体会话桥的无头自测：真引擎里把 singleton 的公开接口与状态机逐个走一遍。
// 在设备上用 qmlscene 跑：cd /tmp/qmlcheck && QT_QPA_PLATFORM=offscreen qmlscene bridgetest.qml
//
// ⚠️ 假 session 必须是**真 QObject**（下面的 QtObject）。用 JS 字面量对象会报
//    "Unable to assign QJSValue to QObject*" —— 因为 bridge 里的
//    `Connections { target: bridge.session }` 的 target 声明就是 QObject*。
//
// 假 shell 会把每条命令记进 cmds，用来断言「确实发出了该发的命令」
// （本轮的核心改动就是命令：停播要当场回收播放器，接回要先冷启动）。
Item {
    // 假 mediaSession：只实现 bridge 真正用到的那几个成员
    // （begin / end / setLyrics + 一批可写属性），够把状态机跑通。
    QtObject {
        id: fakeSession
        property bool   active: false
        property int    playState: -1
        property double position: -1
        property double duration: -1
        property string title: ""
        property string artist: ""
        property string cover: ""
        property string mainLyric: ""
        property string transLyric: ""
        property bool   hasLyrics: true
        function begin(id) { active = true; return true }
        function end() { active = false }
        function setLyrics(main, trans) { mainLyric = main || ""; transLyric = trans || "" }
    }

    // 假 shell：记录命令 + 对「读 queue.json」这类查询同步回放一个最小合法结果。
    // ⚠️ 刻意**不**回放读 now.json 的那条：否则 poll → onNow 会在测试里重入。
    QtObject {
        id: fakeShell
        property var    cmds: []
        // 非空时，对 poll 命令回放这份 stdout —— 必须写成**真实格式**：
        // `<json><换行>@@<换行>S<换行>`。少了 `@@` 后面那个前导换行就测不出
        // 「charAt(0) 拿到换行符」这个坑（线上就是这么挂的）。
        property string pollOut: ""
        function startDetached(c) { fakeShell.cmds.push(String(c)); return true }
        function exec(c)          { fakeShell.cmds.push(String(c)); return true }
        function execAsync(c, cb) {
            var cmd = String(c)
            fakeShell.cmds.push(cmd)
            if (!cb) return
            if (cmd.indexOf("queue.json") >= 0) {
                cb({ "stdout": "{\"list\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"}],\"index\":3}",
                     "stderr": "", "exitCode": 0 })
                return
            }
            if (fakeShell.pollOut !== "" && cmd.indexOf("@@") >= 0)
                cb({ "stdout": fakeShell.pollOut, "stderr": "", "exitCode": 0 })
        }
        function clear() { fakeShell.cmds = [] }
        // 从第 from 条开始，是否出现过含 needle 的命令
        function since(from, needle) {
            for (var i = from; i < fakeShell.cmds.length; i++)
                if (fakeShell.cmds[i].indexOf(needle) >= 0) return true
            return false
        }
        function count(needle) {
            var n = 0
            for (var i = 0; i < fakeShell.cmds.length; i++)
                if (fakeShell.cmds[i].indexOf(needle) >= 0) n++
            return n
        }
    }

    property int fails: 0

    function say(s) { console.log("GDTEST " + s) }
    function check(name, cond, extra) {
        if (cond) say("PASS " + name + (extra ? " (" + extra + ")" : ""))
        else { fails++; say("FAIL " + name + (extra ? " (" + extra + ")" : "")) }
    }

    Component.onCompleted: {
        try {
            // ================= 基本接口 =================
            say("T1 singleton type = " + typeof MediaBridge)
            MediaBridge.attach(null, { "session": null, "shell": null, "global": null, "enabled": false })
            say("T2 attach(enabled=false) ok, status=" + MediaBridge.status + " owns=" + MediaBridge.owns)
            // 默认值：停播即交还会话（原厂 ✕ 语义 —— 面板上的音乐卡片随之消失）
            check("T2b 默认 holdOnStop=false（停播即交还）", MediaBridge.holdOnStop === false)

            MediaBridge.setEnabled(true)
            say("T3 setEnabled(true) ok, enabled=" + MediaBridge.enabled)

            // 歌词：pos 落到某行之后才返回那一行（第 1 行在 1s 处，所以 pos=2 才对）
            MediaBridge.setLyrics([{ time: 1, text: "第一行" }, { time: 5, text: "第二行" }])
            check("T4 setLyrics/lyricAt", MediaBridge.lyricAt(2) === "第一行"
                  && MediaBridge.lyricAt(6) === "第二行" && MediaBridge.lyricAt(0.0) === "",
                  "lyricAt(0)='" + MediaBridge.lyricAt(0) + "' lyricAt(2)=" + MediaBridge.lyricAt(2))
            MediaBridge.setLyrics([])
            check("T4b setLyrics([])", MediaBridge.lyricAt(6) === "")

            MediaBridge.setCover("http://x/y.jpg")
            check("T5 setCover", MediaBridge.cover === "http://x/y.jpg")

            // shellRef=null ⇒ 不会真的发命令
            MediaBridge.onNextRequested();   MediaBridge.onPrevRequested()
            MediaBridge.onPlayRequested();   MediaBridge.onPauseRequested()
            MediaBridge.onToggleRequested(); MediaBridge.onSeekRequested(1234)
            MediaBridge.onOpenRequested();   MediaBridge.onSessionRevoked()
            say("T6 控制回调全部无异常（shellRef=null）")

            // ================= 没有 session 时不炸 =================
            MediaBridge.onNow({ status: "playing", index: 2, pos: 12.5, dur: 200,
                                name: "歌名", artist: "歌手", ts: Date.now() / 1000 }, true)
            check("T7 onNow(无 session)", MediaBridge.status === "宿主无 mediaSession", MediaBridge.status)

            // ================= 换成假 session + 假 shell，走真实状态机 =================
            fakeSession.active = false
            // ⚠️ T6 调过 onSessionRevoked()，它给了 15 秒「被接管冷却」（这个冷却本身是对的），
            //    不清掉的话下面申请会话会被直接挡回，看起来像 bug。
            MediaBridge.revokedUntil = 0
            MediaBridge.attach(null, { "session": fakeSession, "shell": fakeShell, "global": null,
                                       "enabled": true, "holdOnStop": true })
            check("T8 注入 session/shell", MediaBridge.session === fakeSession && MediaBridge.shellRef === fakeShell
                  && MediaBridge.holdOnStop === true)

            // ① 有内容在放 → 应该 begin 会话并把歌名写进去
            var now = Date.now() / 1000
            MediaBridge.onNow({ status: "playing", index: 3, pos: 5, dur: 200,
                                name: "酸橙色信笺", artist: "塞壬唱片", ts: now }, true)
            check("T9 播放中 -> 持有会话", MediaBridge.owns === true && fakeSession.active === true)
            check("T9b 上报歌名/播放态", fakeSession.title === "酸橙色信笺"
                  && fakeSession.playState === MediaBridge.psPlaying
                  && fakeSession.duration === 200000, "title=" + fakeSession.title)
            check("T9c lastIndex 已记住", MediaBridge.lastIndex === 3, "lastIndex=" + MediaBridge.lastIndex)

            // ② 停播（面板 ✕ / 插件页停止按钮）→ 本轮的两条关键语义：
            //    保留**会话**（否则卡片消失、面板连 ▶ 都没有）+ 当场回收**播放器进程**。
            var beforeStop = fakeShell.cmds.length
            MediaBridge.requestStop()
            check("T10 停播后仍持有会话（卡片不消失）",
                  MediaBridge.owns === true && fakeSession.active === true, "owns=" + MediaBridge.owns)
            check("T10b 会话外观已置停止", fakeSession.playState === MediaBridge.psStopped
                  && fakeSession.position === 0 && fakeSession.duration === 0,
                  "playState=" + fakeSession.playState)
            check("T10c 歌名保留（告诉用户刚停的是哪首）", fakeSession.title === "酸橙色信笺")
            check("T10d 保留期计时器已启动", MediaBridge.holdTimer.running === true)
            check("T10e lastStatus=stopped（决定 ▶ 走接回而不是解暂停）",
                  MediaBridge.lastStatus === "stopped", MediaBridge.lastStatus)
            check("T10f 停播**当场**回收播放器（状态位）", MediaBridge.mpvAlive === false)
            check("T10g 确实发出了 pkill 命令",
                  fakeShell.since(beforeStop, "pkill -f '[i]nput-ipc-server=/tmp/gdmusic.sock'"))
            check("T10h 回收时连 socket/唤醒锁/状态文件一起清",
                  fakeShell.since(beforeStop, "/tmp/audio_wakelocks/gdmusic.lock")
                  && fakeShell.since(beforeStop, "/tmp/gdmusic/now.json"))

            // ③ 🔴 本轮最关键的回归点：停播后播放器已经没了（socket 不在），
            //    桥**不能**因此把会话也放掉 —— 否则卡片当场消失，又回到
            //    「停播后只能重开插件才能再播」。
            MediaBridge.onNow({ status: "stopped", index: -1, pos: 0, dur: 0, ts: now }, false)
            check("T11 保留期里 socket 不在 -> 仍不交还会话", MediaBridge.owns === true
                  && fakeSession.active === true, "owns=" + MediaBridge.owns)

            // ④ 用户在面板按 ▶ → resumeAt：先冷启动播放器，再发 gd-load
            var beforePlay = fakeShell.cmds.length
            MediaBridge.onPlayRequested()
            check("T12 接回时把当前下标写回 queue.json", fakeShell.since(beforePlay, "queue.json"))
            check("T12b 接回时先冷启动播放器（幂等 nohup）",
                  fakeShell.since(beforePlay, "nohup /userdisk/mpv/mpv"))
            check("T12c 接回时发出 gd-load", fakeShell.since(beforePlay, "script-message gd-load"))

            // ⑤ 真的重新放起来 → 保留期该被取消（否则 3 分钟后会把正在放的歌掐掉）
            MediaBridge.onNow({ status: "playing", index: 3, pos: 6, dur: 200,
                                name: "酸橙色信笺", artist: "塞壬唱片", ts: Date.now() / 1000 }, true)
            check("T13 恢复播放 -> 保留期取消", MediaBridge.holdTimer.running === false)

            // ⑥ 不在保留期、播放器却没了（被外部杀掉 / OOM）→ 才交还会话
            MediaBridge.onNow({ status: "stopped", index: -1, ts: now }, false)
            check("T14 非保留期播放器消失 -> 交还会话",
                  MediaBridge.owns === false && fakeSession.active === false)

            // ⑦ 保留期超时 → 交还会话（播放器在停播当时就已回收）
            MediaBridge.onNow({ status: "playing", index: 1, pos: 1, dur: 100,
                                name: "A", artist: "B", ts: Date.now() / 1000 }, true)
            check("T15 重新持有会话", MediaBridge.owns === true && fakeSession.active === true)
            MediaBridge.requestStop()
            check("T15b 停播后进入保留期", MediaBridge.holdTimer.running === true && MediaBridge.owns === true)
            MediaBridge.holdExpired()
            check("T15c 保留期超时 -> 交还会话", MediaBridge.owns === false && fakeSession.active === false)
            check("T15d 计时器已停", MediaBridge.holdTimer.running === false)

            // ⑧ 停止态再按一次停止 = 立刻收工（不等超时）
            MediaBridge.onNow({ status: "playing", index: 1, pos: 1, dur: 100,
                                name: "A", artist: "B", ts: Date.now() / 1000 }, true)
            MediaBridge.requestStop()          // 第 1 拍：停播 + 保留
            check("T16 第 1 拍仍持有", MediaBridge.owns === true && MediaBridge.holdTimer.running === true)
            MediaBridge.requestStop()          // 第 2 拍：彻底收工
            check("T16b 第 2 拍交还会话且停掉计时器",
                  MediaBridge.owns === false && fakeSession.active === false && MediaBridge.holdTimer.running === false)

            // ⑨ 关掉「停播后保留控制条」开关 → 停播即交还（原厂语义）
            MediaBridge.setHoldOnStop(false)
            MediaBridge.onNow({ status: "playing", index: 1, pos: 1, dur: 100,
                                name: "A", artist: "B", ts: Date.now() / 1000 }, true)
            check("T17 重新持有会话", MediaBridge.owns === true && fakeSession.active === true)
            MediaBridge.requestStop()
            check("T17b 关闭开关后停播即交还", MediaBridge.owns === false && fakeSession.active === false
                  && MediaBridge.holdTimer.running === false)

            // ⑩ 冷启动命令的内容（纯函数，可直接断言）
            var cmd = MediaBridge.buildEnsurePlayerCmd()
            check("T18 冷启动命令含 mpv + idle",
                  cmd.indexOf("nohup /userdisk/mpv/mpv") >= 0 && cmd.indexOf("--idle=yes") >= 0)
            check("T18b 冷启动命令带 ipc socket 与 lua",
                  cmd.indexOf("--input-ipc-server=/tmp/gdmusic.sock") >= 0
                  && cmd.indexOf("--script=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua") >= 0)
            check("T18c 冷启动是幂等的（socket 活着就 exit 0，不会掐断在放的歌）",
                  cmd.indexOf("[ -S /tmp/gdmusic.sock ]") >= 0 && cmd.indexOf("exit 0") >= 0)

            // ⑪ 🔴 线上抓到的 bug 的回归断言：poll 的解析
            //    真实命令输出是 `<换行>@@<换行>S<换行>`。分隔符 `@@` 后面的**前导换行**
            //    如果不 trim，charAt(0) 拿到的是换行符 ⇒ mpvAlive 永远 false
            //    ⇒ onNow 分支① 每拍都 release ⇒ 会话 claim/release 死循环、面板不出卡片。
            MediaBridge.setHoldOnStop(true)
            var t19 = Date.now() / 1000
            MediaBridge.onNow({ status: "playing", index: 2, pos: 3, dur: 100,
                                name: "A", artist: "B", ts: t19 }, true)
            check("T19 重新持有会话", MediaBridge.owns === true && fakeSession.active === true)

            fakeShell.pollOut = '{"ts":' + t19 + ',"index":2,"status":"playing","pause":false,'
                + '"pos":3000,"dur":100000,"name":"A","artist":"B"}' + "\n@@\nS\n"
            MediaBridge.poll()
            check("T19b poll 解析：@@ 后的前导换行不能把 S 读成 D（线上 bug）",
                  MediaBridge.mpvAlive === true, "mpvAlive=" + MediaBridge.mpvAlive)
            check("T19c 因此不会把刚拿到的会话误放掉",
                  MediaBridge.owns === true && fakeSession.active === true)

            // 真死了（socket 不在）⇒ 该交还
            fakeShell.pollOut = '{"ts":' + t19 + ',"index":2,"status":"playing","pause":false,'
                + '"pos":3000,"dur":100000,"name":"A","artist":"B"}' + "\n@@\nD\n"
            MediaBridge.poll()
            check("T19d poll 解析：socket=D ⇒ 交还会话",
                  MediaBridge.owns === false && fakeSession.active === false
                  && MediaBridge.mpvAlive === false)

            // 命令没回来（stdout 里没有 @@）⇒ 沿用上一拍，不能误判成「播放器死了」
            MediaBridge.onNow({ status: "playing", index: 2, pos: 3, dur: 100,
                                name: "A", artist: "B", ts: Date.now() / 1000 }, true)
            check("T19e 重新持有", MediaBridge.owns === true)
            fakeShell.pollOut = "commanderror"
            MediaBridge.poll()
            check("T19f 命令没回来时不误交还", MediaBridge.owns === true
                  && MediaBridge.mpvAlive === true)
            fakeShell.pollOut = ""

            MediaBridge.detach(null)
            say("T20 detach ok")

            say(fails === 0 ? "ALL-OK" : ("HAS-FAILURES: " + fails))
        } catch (e) {
            say("FAIL(exception): " + e)
        }
    }
}
