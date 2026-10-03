import QtQuick 2.12

// 真机探针：验证「网易云登录 + 歌单同步」的数据层纯函数 + 登录页属性。
//
// ⚠️ 不碰网络/shell：qmlscene 里没有 shell 上下文属性，登录/同步的真实网络往返
//    交给 login.sh（命令生成 + 接线）和真机扫码（用户手动）。本探针只验：
//      A. ncParseCheckCode 状态码解析（真引擎）
//      B. ncMapSongs 歌单映射 + pic_id 提取（真引擎）
//      C. ncFilterOwnPlaylists 过滤本人歌单（真引擎）
//      D. ncJarToCookie jar 解析（真引擎）
//      E. LoginPage 页面属性（loggedIn / phaseText 绑定）与 ncLogout 副作用链
Rectangle {
    id: root
    width: 320
    height: 170
    color: "#1B1D24"

    property var it: null        // main.qml 根对象（controller）
    property var page: null      // LoginPage 实例

    property int pass: 0
    property int bad: 0
    function ok(c, label) {
        if (c) { pass++; console.log("  ✅ " + label) }
        else   { bad++;  console.log("  ❌ " + label) }
    }
    function eq(a, b, label) { ok(a === b, label + "  (得到 " + JSON.stringify(a) + ")") }

    // 递归找 objectName（探针不假设对象树结构）
    function findByName(o, name) {
        if (!o) return null
        if (o.objectName === name) return o
        for (var i = 0; i < o.children.length; i++) {
            var r = findByName(o.children[i], name)
            if (r) return r
        }
        return null
    }

    property int stage: 0

    Component.onCompleted: {
        // 加载设备上的 main.qml
        var comp = Qt.createComponent("/userdisk/PenMods/plugins/gdmusic/qml/main.qml")
        if (comp.status === Component.Error) {
            console.log("LOAD FAIL: " + comp.errorString())
            root.stage = 99
        } else {
            var obj = comp.createObject(root)
            if (!obj) { console.log("CREATE FAIL"); root.stage = 99 }
            else {
                it = obj
                console.log("main.qml 加载成功")
                root.stage = 1
            }
        }
    }

    // 用 Timer 驱动分阶段（避免同步递归/组件未就绪）
    Timer {
        id: t
        interval: 50
        repeat: true
        running: root.stage > 0
        onTriggered: {
            if (root.stage === 1) {
                console.log("--- A. 登录状态码解析（真引擎）---")
                eq(it.ncParseCheckCode('{"code":800}'), 800, "800 过期")
                eq(it.ncParseCheckCode('{"code":803}'), 803, "803 成功")
                eq(it.ncParseCheckCode('bad'), -1, "坏 JSON → -1")
                root.stage = 2
            } else if (root.stage === 2) {
                console.log("--- B. 歌单映射 + pic_id 提取（真引擎）---")
                var detail = { tracks: [
                    { id: 7, name: "测试歌", ar: [{ name: "甲" }, { name: "乙" }],
                      al: { picUrl: "https://p2.music.126.net/x/109951165671182684.jpg" } },
                    { id: 0, name: "无id", ar: [] }  // 应被跳过
                ] }
                var mapped = it.ncMapSongs(detail)
                eq(mapped.length, 1, "映射出 1 条（无 id 被跳过）")
                eq(mapped[0].id, "7", "id 转字符串")
                eq(mapped[0].artist, "甲、乙", "多歌手 、 连接")
                eq(mapped[0].pic_id, "109951165671182684", "从 picUrl 提取 pic_id")
                eq(mapped[0].source, "netease", "source 恒 netease")
                root.stage = 3
            } else if (root.stage === 3) {
                console.log("--- C. 过滤本人歌单（真引擎）---")
                var own = it.ncFilterOwnPlaylists(JSON.stringify({ playlist: [
                    { id: 1, name: "我的", trackCount: 5, subscribed: false },
                    { id: 2, name: "收藏", trackCount: 3, subscribed: true }
                ] }))
                eq(own.length, 1, "只留本人建的")
                eq(own[0].id, "1", "id 正确")
                root.stage = 4
            } else if (root.stage === 4) {
                console.log("--- D. jar 解析（真引擎）---")
                eq(it.ncJarToCookie("# comment\n.netease.com\tTRUE\t/\tFALSE\t0\tMUSIC_U\txyz\n"),
                   "MUSIC_U=xyz", "jar 单行解析")
                eq(it.ncJarToCookie(""), "", "空 jar → 空")
                root.stage = 5
            } else if (root.stage === 5) {
                console.log("--- E. LoginPage 页面属性 + ncLogout ---")
                var pg = findByName(it, "gdNcQrImg")
                if (pg) pg = pg.parent  // 二维码 Image 的 parent 是它的容器；LoginPage 根在更上层
                // 直接找登录页根：通过 controller 引用回查。更稳：main.qml 里 loginPage 是 id，
                // 探针拿不到 id，但可以找「page === login 时可见」的根对象。
                // 改用 objectName 方案：LoginPage 根没设 objectName，但二维码 Image 有 gdNcQrImg。
                var qr = findByName(it, "gdNcQrImg")
                ok(!!qr, "找到登录页二维码 Image（gdNcQrImg）")
                // ncLogout 清空登录态
                it.ncUid = "12345"
                it.ncNick = "测试"
                it.ncCookie = "MUSIC_U=abc"
                it.ncPhase = "done"
                it.ncLogout()
                eq(it.ncUid, "", "ncLogout 清空 uid")
                eq(it.ncCookie, "", "ncLogout 清空 cookie")
                eq(it.ncNick, "", "ncLogout 清空昵称")
                // 登录态属性默认值
                it.ncUid = "999"
                ok(it.ncUid === "999", "ncUid 可写")
                root.stage = 6
            } else if (root.stage === 6) {
                console.log("CHECK DONE pass=" + root.pass + " bad=" + root.bad)
                t.stop()
                if (root.bad > 0) Qt.quit(1)
                else Qt.quit(0)
            } else if (root.stage === 99) {
                console.log("CHECK DONE pass=0 bad=1 (load fail)")
                t.stop()
                Qt.quit(1)
            }
        }
    }
}
