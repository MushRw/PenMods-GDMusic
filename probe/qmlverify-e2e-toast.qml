import QtQuick 2.12
import "file:///userdisk/PenMods/plugins/gdmusic/qml"

// ============================================================================
// 🔴 端到端实证：设备上部署的 MediaBridge（b10e8b6 旧版，单实参）在
//    「qmlGlobal 是**信号**（YGlobal::showToast 的真实形态）」时，
//    失败提示到底会不会到用户眼前？
//
// 已由 SG 探针实测：QML 信号少传实参 **同样** 抛 "Insufficient arguments"
//   （signal showToast(string,color) 用 1 个实参调用 ⇒ Error: Insufficient arguments，
//     处理器调用次数=0）
// ⇒ 旧版 notifyFailure 的 `globalRef.showToast(msg)` 会抛异常，
//   被它自己的 try/catch 静默吞掉 ⇒ **toast 不弹、用户什么都看不到**。
//
// 本探针把这条链路在真机上完整跑通并断言：
//   · 旧版：handler 调用 0 次，MediaBridge 的 catch 记下 "toast failed"
//   · 修复版：handler 调用 1 次，颜色正确
// ============================================================================
Item {
    id: root
    width: 10
    height: 10

    property int pass: 0
    property int bad: 0
    property int rawFail: 0
    function ok(c, label) {
        if (c) { pass++; console.log("E2E PASS " + label) }
        else   { bad++;  console.log("E2E FAIL " + label) }
    }

    // 忠实复刻 YGlobal：showToast 是**信号**，参数名与 moc 表一致(qsMsg/clrBg)
    QtObject {
        id: fakeQmlGlobal
        property int toastCount: 0
        property var colors: []
        property var msgs: []
        signal showToast(string qsMsg, color clrBg)
        onShowToast: {
            fakeQmlGlobal.toastCount++
            fakeQmlGlobal.msgs = fakeQmlGlobal.msgs.concat([String(qsMsg)])
            fakeQmlGlobal.colors = fakeQmlGlobal.colors.concat([String(clrBg)])
        }
        function reset() { toastCount = 0; colors = []; msgs = [] }
    }

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

    // 记录 MediaBridge 日志里出现的 "toast failed"（= 异常被 catch 吞掉的铁证）
    QtObject {
        id: fakeShell
        property var logs: []
        function startDetached(c) { fakeShell.logs = fakeShell.logs.concat([String(c)]) }
        function exec(c) { fakeShell.logs = fakeShell.logs.concat([String(c)]) }
        function execAsync(c, cb) { fakeShell.logs = fakeShell.logs.concat([String(c)]) }
        function toastFailed() {
            for (var i = 0; i < logs.length; i++)
                if (logs[i].indexOf("toast failed") >= 0) return true
            return false
        }
        function clear() { logs = [] }
    }

    Component.onCompleted: {
        function rawCheck(c) { if (!c) root.rawFail++ }
        rawCheck(false)
        ok(root.rawFail === 1, "夹具自检 rawCheck(false) 计到 1（PASS 非恒真）")

        // 夹具自检：真实 QML 信号少传实参必须抛错（否则本探针没有判别力）
        var selfThrew = false
        try { fakeQmlGlobal.showToast("单实参") } catch (e) { selfThrew = true }
        ok(selfThrew && fakeQmlGlobal.toastCount === 0,
           "夹具自检 真实信号单实参抛错且处理器未调用（toastCount=" + fakeQmlGlobal.toastCount + "）")
        fakeQmlGlobal.reset()

        // ---- 接线 ----
        MediaBridge.attach(null, { "session": fakeSession, "shell": fakeShell,
                                   "global": fakeQmlGlobal, "enabled": true, "holdOnStop": false })
        fakeShell.clear()
        MediaBridge.lastReason = ""

        // 让桥持有会话
        MediaBridge.onNow({ status: "playing", index: 1, pos: 1, dur: 100,
                            name: "A", artist: "B", ts: Date.now() / 1000 }, true)
        ok(MediaBridge.owns === true, "前置 桥已持有会话")

        // ---- 触发真实失败路径 ----
        fakeQmlGlobal.reset()
        MediaBridge.onNow({ status: "stopped", index: -1, pos: 0, dur: 0,
                            reason: "fail", text: "取不到播放地址",
                            ts: Date.now() / 1000 }, true)

        console.log("E2E RESULT toast 弹出次数=" + fakeQmlGlobal.toastCount
                    + " 消息=" + JSON.stringify(fakeQmlGlobal.msgs)
                    + " 颜色=" + JSON.stringify(fakeQmlGlobal.colors)
                    + " shell 里有 'toast failed'=" + fakeShell.toastFailed())

        ok(fakeQmlGlobal.toastCount >= 1,
           "用户能看到失败提示（toast 实际弹出 " + fakeQmlGlobal.toastCount + " 次）")
        ok(!fakeShell.toastFailed(),
           "没有出现 'toast failed'（异常未被吞掉）")

        console.log("E2E SUMMARY toastCount=" + fakeQmlGlobal.toastCount
                    + " toastFailedLogged=" + fakeShell.toastFailed())
        console.log("E2E RESULT pass=" + root.pass + " bad=" + root.bad)
        Qt.quit(root.bad > 0 ? 1 : 0)
    }
}
