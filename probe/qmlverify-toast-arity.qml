import QtQuick 2.12
import "file:///userdisk/PenMods/plugins/gdmusic/qml"

// ============================================================================
// showToast 实参个数 —— 用**严格夹具**在真机上实测（不是读码推断）
//
// 背景：宿主 qmlGlobal 在裸 qmlscene 里是 undefined（它是宿主注入的 context property），
//      所以无法直接调用真的 qmlGlobal。改为**注入一个受控的假 qmlGlobal**，
//      并让它对实参个数**严格挑剔**：
//
//   function showToast(msg, clr) {
//       var n = arguments.length          ← 关键：数真实传入的实参个数
//       calls.push(n)
//       if (n < 2) throw new Error("Insufficient arguments")   ← 模拟 moc 的严格行为
//   }
//
// ⚠️ 夹具为什么必须这样写：项目出过「夹具签名太宽松 ⇒ 测不出真 bug」的事故。
//    若夹具写成 `function showToast(msg)` 或只记录调用次数，那么真代码少传实参
//    它照样全绿 —— 那就等于没测。这里记 arguments.length 并按 <2 主动抛错，
//    保证「少传一个」必然让断言变红。
//
// 被测对象 = **设备上部署的那份** MediaBridge.qml（当前是 580cda0 旧版，单实参）。
// ============================================================================
Item {
    id: root
    width: 10
    height: 10

    property int pass: 0
    property int bad: 0
    property int rawFail: 0

    function ok(c, label) {
        if (c) { pass++; console.log("TO PASS " + label) }
        else   { bad++;  console.log("TO FAIL " + label) }
    }

    // ---- 严格假 qmlGlobal ----
    QtObject {
        id: fakeGlobal
        property var calls: []      // 每次调用的实参个数
        property var msgs: []       // 每次调用的第 1 个实参
        property int threwCount: 0

        // 故意声明两个形参，但用 arguments.length 严格校验
        function showToast(msg, clr) {
            var n = arguments.length
            fakeGlobal.calls = fakeGlobal.calls.concat([n])
            fakeGlobal.msgs = fakeGlobal.msgs.concat([String(msg)])
            if (n < 2) {
                fakeGlobal.threwCount++
                throw new Error("Insufficient arguments")
            }
        }
        function reset() { calls = []; msgs = []; threwCount = 0 }
        function last() { return calls.length ? calls[calls.length - 1] : -1 }
        function lastMsg() { return msgs.length ? msgs[msgs.length - 1] : "" }
    }

    // ---- 假 session：begin() 返回 true 才能让桥持有会话 ----
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
        function rawCheck(c) { if (!c) root.rawFail++ }
        rawCheck(false)
        ok(root.rawFail === 1, "夹具自检 rawCheck(false) 计到 1（PASS 非恒真）")

        // ---- 夹具自检：严格夹具必须真的对单实参抛错 ----
        fakeGlobal.reset()
        var selfThrew = false
        try { fakeGlobal.showToast("只有一条") } catch (e) { selfThrew = true }
        ok(selfThrew && fakeGlobal.last() === 1,
           "夹具自检 单实参调用被夹具判为不足并抛错（n=" + fakeGlobal.last() + "）")
        fakeGlobal.reset()
        fakeGlobal.showToast("两条", "#fff")
        ok(fakeGlobal.last() === 2 && fakeGlobal.threwCount === 0,
           "夹具自检 双实参调用通过（n=" + fakeGlobal.last() + "）")

        // ---- 接线：shell=null（不发任何 shell 命令），注入严格假 qmlGlobal ----
        MediaBridge.attach(null, { "session": fakeSession, "shell": null,
                                   "global": fakeGlobal, "enabled": true, "holdOnStop": false })

        // ================= 用例 1：直接调 notifyFailure =================
        fakeGlobal.reset()
        MediaBridge.lastReason = ""
        MediaBridge.notifyFailure("取不到播放地址")
        var n1 = fakeGlobal.last()
        console.log("TO CALL notifyFailure -> 实参个数=" + n1
                    + " msg=" + JSON.stringify(fakeGlobal.lastMsg())
                    + " 夹具抛错数=" + fakeGlobal.threwCount)
        ok(n1 === 2, "1 notifyFailure 传满 2 个实参（实测 n=" + n1 + "）")
        ok(fakeGlobal.threwCount === 0,
           "1b notifyFailure 未触发严格夹具的不足实参抛错（threw=" + fakeGlobal.threwCount + "）")

        // ================= 用例 2：真实路径 onNow(stopped/fail) → notifyFailure =================
        // 先让桥持有会话
        MediaBridge.lastReason = ""
        MediaBridge.onNow({ status: "playing", index: 1, pos: 1, dur: 100,
                            name: "A", artist: "B", ts: Date.now() / 1000 }, true)
        ok(MediaBridge.owns === true, "2 前置：桥已持有会话")
        fakeGlobal.reset()
        // 停播 + reason=fail ⇒ onNow 分② → stopText → notifyFailure
        // ⚠️ alive 必须传 true：传 false 会先命中分①（owns && !mpvAlive && !holdTimer.running
        //    → release() 并 return），根本走不到 stopText/notifyFailure。
        MediaBridge.onNow({ status: "stopped", index: -1, pos: 0, dur: 0,
                            reason: "fail", text: "取不到播放地址",
                            ts: Date.now() / 1000 }, true)
        var n2 = fakeGlobal.last()
        console.log("TO CALL onNow(stopped,fail) -> 实参个数=" + n2
                    + " msg=" + JSON.stringify(fakeGlobal.lastMsg())
                    + " 夹具抛错数=" + fakeGlobal.threwCount
                    + " 调用次数=" + fakeGlobal.calls.length)
        ok(fakeGlobal.calls.length >= 1, "2 真实路径确实到达 showToast（调用 " + fakeGlobal.calls.length + " 次）")
        ok(n2 === 2, "2b 真实路径传满 2 个实参（实测 n=" + n2 + "）")
        ok(fakeGlobal.threwCount === 0,
           "2c 真实路径未触发不足实参抛错（threw=" + fakeGlobal.threwCount + "）")

        // ================= 用例 3：onOpenRequested（第二处调用点） =================
        MediaBridge.detach(null)          // page=null ⇒ 走 toast 分支
        fakeGlobal.reset()
        MediaBridge.onOpenRequested()
        var n3 = fakeGlobal.last()
        console.log("TO CALL onOpenRequested -> 实参个数=" + n3
                    + " msg=" + JSON.stringify(fakeGlobal.lastMsg())
                    + " 夹具抛错数=" + fakeGlobal.threwCount)
        ok(n3 === 2, "3 onOpenRequested 传满 2 个实参（实测 n=" + n3 + "）")
        ok(fakeGlobal.threwCount === 0,
           "3b onOpenRequested 未触发不足实参抛错（threw=" + fakeGlobal.threwCount + "）")

        // ---- 结论行（供 grep / 机器判读） ----
        var allTwo = (n1 === 2) && (n2 === 2) && (n3 === 2)
        console.log("TO SUMMARY 三个调用点实参个数=" + JSON.stringify([n1, n2, n3])
                    + " 全部传满2=" + allTwo)
        console.log("TO CONCLUSION " + (allTwo
            ? "设备上部署的 MediaBridge 三处 showToast 调用**都传满 2 个实参**"
            : "设备上部署的 MediaBridge 存在**只传 1 个实参**的 showToast 调用 ⇒ 严格夹具下抛 Insufficient arguments"))

        console.log("TO RESULT pass=" + root.pass + " bad=" + root.bad)
        Qt.quit(root.bad > 0 ? 1 : 0)
    }
}
