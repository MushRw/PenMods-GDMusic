import QtQuick 2.12

// 在**真机**上验证「已下载优先」(preferLocal)。
// 与 probe/preferlocal.sh（node 求值源码）互补：这里加载的是**真实 main.qml**，
// 跑在真 QML 引擎上、走真属性系统 —— 能抓到"源码求值测不出"的那类问题
// （比如属性名写错、函数没暴露到对象上、queueJsonString 里其实没接上）。
//
// 用法（设备上）：
//   adb push probe/preferlocal-device.qml /tmp/
//   adb shell "cd /userdisk/PenMods/plugins/gdmusic/qml && HOME=/tmp \
//              QT_QPA_PLATFORM=offscreen timeout 40 /usr/bin/qmlscene /tmp/preferlocal-device.qml"
Item {
    width: 320
    height: 170

    property int pass: 0
    property int bad: 0

    function ok(cond, label) {
        if (cond) { pass++; console.log("  OK   " + label) }
        else      { bad++;  console.log("  BAD  " + label) }
    }

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onLoaded: {
            var it = ld.item
            if (!it) { console.log("CHECK FAIL 加载 main.qml 得到空对象"); Qt.quit(1); return }

            var D = "/userdisk/Music/GDMusic"
            var REC = { file: D + "/断气-回春丹.mp3", size: 11735293, name: "断气", artist: "回春丹" }
            // artist 是**数组** —— 这正是 GD 搜索接口返回的形状（String(["回春丹"]) == "回春丹"）
            var online = { id: "1997293311", source: "netease", name: "断气",
                           artist: ["回春丹"], pic_id: "109951173449168898", lyric_id: "1997293311" }

            console.log("--- 1. 在线条目命中本地 ---")
            it.localList = [REC]
            it.preferLocal = true
            var r = it.resolveEntry(online)
            ok(r && r.file === REC.file, "命中 → 补上 file：" + (r ? r.file : "(无)"))
            ok(r && r.pic_id === "109951173449168898", "pic_id 保留（封面不断链）")
            ok(r && r.id === "1997293311", "trackId 保留（歌词可用）")
            ok(online.file === undefined, "原对象没被改动")

            console.log("--- 2. 未命中 / 已是本地 ---")
            it.localList = []
            ok(it.resolveEntry(online).file === undefined, "未命中 → 不补 file（老实走网络）")
            var L = { file: D + "/x.mp3", name: "x" }
            ok(it.resolveEntry(L) === L, "已是本地条目 → 原样返回")

            console.log("--- 3. 半截文件不算命中 ---")
            it.localList = [{ file: REC.file, size: 1024 }]
            ok(it.resolveEntry(online).file === undefined, "1KB（下坏了）→ 不认")

            console.log("--- 4. 开关 ---")
            it.localList = [REC]
            it.preferLocal = false
            ok(it.resolveEntry(online).file === undefined, "preferLocal=false → 完全不生效")
            it.preferLocal = true

            console.log("--- 5. 接线：queueJsonString 真的换成本地了 ---")
            it.queue = [online]
            it.queueIndex = 0
            var js = it.queueJsonString(0)
            ok(js.indexOf("\"file\"") >= 0, "队列 JSON 里出现 file 字段")
            ok(js.indexOf(REC.file) >= 0, "file 正是本地文件路径")
            ok(js.indexOf("1997293311") >= 0, "trackId 仍在（封面/歌词不失效）")
            ok(js.indexOf("\"source\":\"netease\"") >= 0, "source 仍在")

            console.log("CHECK DONE pass=" + pass + " bad=" + bad)
            // ⚠️ 2026-10-05：裸 Qt.quit() == Qt.quit(0)，失败也返回 0
            //    ⇒ 退出码通道是断的。照抄 login-device.qml:126-127。
            if (bad > 0) Qt.quit(1)
            else Qt.quit(0)
        }

        onStatusChanged: {
            if (status === Loader.Error) {
                console.log("CHECK FAIL main.qml 加载失败（Loader.Error）")
                Qt.quit(1)
            }
        }
    }
}
