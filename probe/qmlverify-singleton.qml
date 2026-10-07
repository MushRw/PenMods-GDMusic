import QtQuick 2.12
// 独立验证 MediaBridge singleton 能否加载（task-8 核心目标）。
// 刻意**不**通过 main.qml，直接 import 插件目录 —— 这样测的就是 singleton 本身。
// 若 singleton 加载失败，本文件会直接报 "Type MediaBridge unavailable" 且整个组件不创建。
import "file:///userdisk/PenMods/plugins/gdmusic/qml"

Item {
    id: root
    width: 10
    height: 10

    property int pass: 0
    property int bad: 0
    // 夹具自检计数：用来证明检查器真的能报 FAIL（否则满屏 PASS 不可信）
    property int rawFail: 0

    function ok(c, label) {
        if (c) { pass++; console.log("QV PASS " + label) }
        else   { bad++;  console.log("QV FAIL " + label) }
    }
    function eq(a, b, label) {
        ok(a === b, label + "  [得到 " + JSON.stringify(a) + "，期望 " + JSON.stringify(b) + "]")
    }

    // 假 session：只需是真 QObject（Connections 的 target 声明为 QObject*）
    QtObject {
        id: fakeSession
        property bool active: false
        property int playState: -1
        property double position: -1
        property double duration: -1
        property string title: ""
        property string artist: ""
        property string cover: ""
        property string mainLyric: ""
        property string transLyric: ""
        function begin(id) { active = true; return true }
        function end() { active = false }
        function setLyrics(m, t) { mainLyric = m || ""; transLyric = t || "" }
    }

    Component.onCompleted: {
        // ---- 夹具自检：检查器必须能检测到假条件 ----
        function rawCheck(c) { if (!c) root.rawFail++ }
        rawCheck(false)
        ok(root.rawFail === 1, "夹具自检 rawCheck(false) 计到 1（证明 PASS 不是恒真）")

        // ---- A. singleton 本体能解析 ----
        ok(typeof MediaBridge !== "undefined", "A1 MediaBridge 可解析（非 undefined）")
        eq(typeof MediaBridge, "object", "A2 typeof MediaBridge")

        // ---- B. 关键只读常量 ----
        eq(MediaBridge.pluginId, "com.gdmusic.player", "B1 pluginId")
        eq(MediaBridge.psStopped, 0, "B2 psStopped")
        eq(MediaBridge.psPlaying, 1, "B3 psPlaying")
        eq(MediaBridge.psPaused, 2, "B4 psPaused")
        eq(MediaBridge.mpvSock, "/tmp/gdmusic.sock", "B5 mpvSock")
        eq(MediaBridge.stateDir, "/tmp/gdmusic", "B6 stateDir")
        eq(MediaBridge.nowFile, "/tmp/gdmusic/now.json", "B7 nowFile")
        eq(MediaBridge.luaScript, "/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua", "B8 luaScript")
        eq(MediaBridge.holdMs, 180000, "B9 holdMs=3min")

        // ---- C. 公开方法齐备 ----
        var fns = ["attach", "detach", "setEnabled", "setHoldOnStop", "poll", "onNow",
                   "apply", "stopText", "notifyFailure", "isFailure", "lyricAt", "lyricText",
                   "release", "autoRelease", "holdSession", "cancelHold", "holdExpired",
                   "killMpv", "buildEnsurePlayerCmd", "ensurePlayer", "mpvRun", "sendMsg",
                   "resumeAt", "onPlayRequested", "onPauseRequested", "onToggleRequested",
                   "onNextRequested", "onPrevRequested", "requestStop", "onStopRequested",
                   "onSeekRequested", "onOpenRequested", "onSessionRevoked",
                   "setLyrics", "setCover", "syncTimer", "kick", "q", "log"]
        var missing = []
        for (var i = 0; i < fns.length; i++)
            if (typeof MediaBridge[fns[i]] !== "function") missing.push(fns[i])
        eq(missing.length, 0, "C1 " + fns.length + " 个公开方法全部为 function（缺：" + JSON.stringify(missing) + "）")

        // ---- D. 默认属性值 ----
        eq(MediaBridge.enabled, true, "D1 enabled 默认 true")
        eq(MediaBridge.owns, false, "D2 owns 默认 false")
        eq(MediaBridge.holdOnStop, false, "D3 holdOnStop 默认 false")
        eq(MediaBridge.status, "未启用", "D4 status 默认")
        eq(MediaBridge.mpvAlive, true, "D5 mpvAlive 默认 true")
        ok(MediaBridge.lyricLines && MediaBridge.lyricLines.length === 0, "D6 lyricLines 默认空数组")

        // ---- E. stopText 四态（真引擎）----
        // shell=null ⇒ MediaBridge 不会发任何 shell 命令（log/ensurePlayer/killMpv 全早退）
        MediaBridge.attach(null, { "session": fakeSession, "shell": null, "global": null,
                                   "enabled": true, "holdOnStop": false })
        ok(MediaBridge.session === fakeSession, "E0 attach 注入 session 成功")

        MediaBridge.lastReason = ""
        eq(MediaBridge.stopText({ reason: "user", text: "" }), "已停止", "E1 stopText(user)")
        MediaBridge.lastReason = ""
        eq(MediaBridge.stopText({ reason: "fail", text: "" }), "取不到播放地址", "E2 stopText(fail) 空 text 回落")
        MediaBridge.lastReason = ""
        eq(MediaBridge.stopText({ reason: "fail", text: "本地文件已丢失" }), "本地文件已丢失", "E3 stopText(fail) 用 o.text")
        MediaBridge.lastReason = ""
        eq(MediaBridge.stopText({ reason: "end", text: "" }), "播放结束", "E4 stopText(end)")
        MediaBridge.lastReason = ""
        eq(MediaBridge.stopText({ reason: "", text: "" }), "未在播放", "E5 stopText(无 reason)")
        MediaBridge.lastReason = ""
        eq(MediaBridge.stopText({ reason: "fail", text: "" }), "取不到播放地址", "E6 fail 优先于 end/user")
        eq(MediaBridge.isFailure(), true, "E7 isFailure() 在 fail 后为 true")

        // ---- F. 相对 import 连坐验证：实例化 components/Toast.qml ----
        // Toast.qml 里写的是 `import ".."`（相对它自己所在目录 = 插件 qml 目录）。
        // 它引用 Theme.radius / Theme.line / Theme.text —— 若 singleton 机制或相对
        // import 有问题，这一步会创建失败。这是「整个插件打不开」那条链的等效复现。
        var comp = Qt.createComponent("file:///userdisk/PenMods/plugins/gdmusic/qml/components/Toast.qml")
        eq(comp.status, Component.Ready, "F1 Toast.qml 组件 Ready（错误：" + comp.errorString() + "）")
        var toastObj = comp.createObject(root)
        ok(toastObj !== null, "F2 Toast.qml 实例化成功（证明 import \"..\" + Theme singleton 可用）")
        if (toastObj) {
            eq(toastObj.radius, Theme.radius, "F3 Toast 通过相对 import 拿到 Theme.radius")
            toastObj.destroy()
        }

        // ---- G. Theme singleton 也在（qmldir 第一个声明项）----
        eq(typeof Theme, "object", "G1 Theme 可解析")
        // ⚠️ Theme.danger 声明成 color ⇒ QML 返回的是 color 值对象，不是字符串。
        //    必须 String() 归一化后再比（第一版夹具直接 === 字符串，误报了一条 FAIL）。
        eq(String(Theme.danger).toLowerCase(), "#e5605c",
           "G2 Theme.danger 值（MediaBridge 字面量取自它）")
        eq(Theme.radius, 5, "G3 Theme.radius")

        // ---- H. 惰性实例化：singleton 不会自己起轮询 ----
        // MediaBridge 只在别处访问时才创建；且 shell=null 时 syncTimer 应把 timer 停掉
        eq(MediaBridge.bridgeTimer.running, false, "H1 shell=null ⇒ bridgeTimer 不跑（无 shell 副作用）")

        console.log("QV RESULT pass=" + root.pass + " bad=" + root.bad)
        Qt.quit(root.bad > 0 ? 1 : 0)
    }
}
