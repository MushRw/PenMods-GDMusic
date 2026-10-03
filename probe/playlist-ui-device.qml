import QtQuick 2.12

// 在**真机**上验证歌单列表页 + 详情页。
//
// 与 probe/playlist-ui.sh（读源码结构）互补：那边只能证明"接线写对了"，
// 这里用真 QML 引擎跑真代码，验证三件静态检查碰不到的事：
//   ① 页面能不能真的被解析并实例化（本地没有 Qt，这是唯一的权威检查）
//   ② ★ 详情页列表在"给歌单加歌"之后会不会刷新 —— plView 那层值重建就是为它设计的。
//      若写成 playlistById(id).songs，歌单对象引用没变 ⇒ 绑定不重算 ⇒
//      这里会看到 count 停在旧值（界面"数据对了但不刷新"，最难查的一类）。
//   ③ 行内按钮（▶ / ×）有没有被整行点击区压住（用 Item.childAt 直接问引擎）
//
// 用法（设备上）：
//   adb push probe/playlist-ui-device.qml /tmp/
//   adb shell "cd /userdisk/PenMods/plugins/gdmusic/qml && HOME=/tmp \
//              QT_QPA_PLATFORM=offscreen timeout 90 /usr/bin/qmlscene /tmp/playlist-ui-device.qml"
//   跑完必须 grep "Unable to assign" / "TypeError" / "ReferenceError"，要求零输出。
Item {
    id: root
    width: 320
    height: 170

    property int pass: 0
    property int bad: 0
    property var app: null
    property string plId: ""
    // 造数据用的两首歌（id 用真实的网易云 trackId，便于人工核对）
    readonly property var songA: ({ id: "1997293311", source: "netease", name: "断气", artist: "回春丹" })
    readonly property var songB: ({ id: "3363090011", source: "netease", name: "海阔天空", artist: "Beyond" })
    readonly property var songC: ({ id: "1234567890", source: "netease", name: "第三首", artist: "某人" })

    function ok(cond, label) {
        if (cond) { pass++; console.log("  OK   " + label) }
        else      { bad++;  console.log("  BAD  " + label) }
    }

    // QML 没有 findChild，只能自己递归
    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var ch = item.children || []
        for (var i = 0; i < ch.length; i++) {
            var r = findByName(ch[i], name)
            if (r) return r
        }
        return null
    }

    // 递归取第一个 Text 的文字（断言 tab 标签文案用）
    function textOf(item) {
        if (!item) return ""
        if (String(item).indexOf("QQuickText(") === 0) return String(item.text || "")
        var ch = item.children || []
        for (var i = 0; i < ch.length; i++) {
            var t = textOf(ch[i])
            if (t !== "") return t
        }
        return ""
    }

    function nameOf(item) {
        if (!item) return "(空)"
        return item.objectName ? item.objectName : "(无 objectName 的 " + item + ")"
    }

    function hitIsInside(container, anc, x, y) {
        var it = container.childAt(x, y)
        while (it) { if (it === anc) return true; it = it.parent }
        return false
    }

    // 取第一行 delegate 里的按钮，问"按钮中心点上最上层是不是它自己"
    function probeBtn(pageRoot, listName, btnName, rowAreaName, label) {
        var list = findByName(pageRoot, listName)
        ok(!!list, label + " · 找到列表 " + listName)
        if (!list) return
        var dlgt = list.itemAtIndex(0)
        ok(!!dlgt, label + " · 第一行已创建")
        if (!dlgt) return

        var btn = findByName(dlgt, btnName)
        ok(!!btn, label + " · 找到按钮 " + btnName)
        if (!btn) return

        var c = btn.mapToItem(dlgt, btn.width / 2, btn.height / 2)
        var hit = dlgt.childAt(c.x, c.y)
        ok(hitIsInside(dlgt, btn, c.x, c.y),
           label + " · 按钮中心上层的对象是按钮自己 → 实际命中 " + nameOf(hit))

        var ma = null
        var ch = btn.children || []
        for (var i = 0; i < ch.length; i++) {
            // ❗用 String() 判类型而不是 hasOwnProperty("pressed")：
            //    QML 里 MouseArea 是 QObject，pressed 在元对象上、不在 JS 自有属性里。
            if (String(ch[i]).indexOf("MouseArea") >= 0) { ma = ch[i]; break }
        }
        ok(!!ma, label + " · 按钮内有 MouseArea")
        if (ma)
            ok(Math.abs(ma.width - btn.width) < 0.5 && Math.abs(ma.height - btn.height) < 0.5,
               label + " · MouseArea 铺满按钮")

        // 反向断言：修按钮不能把"点整行"搞坏
        var rowArea = findByName(dlgt, rowAreaName)
        ok(!!rowArea, label + " · 整行点击区 " + rowAreaName + " 仍在")
        if (rowArea)
            ok(Math.abs(rowArea.width - dlgt.width) < 0.5,
               label + " · 整行点击区仍铺满整行")
        ok(!hitIsInside(dlgt, btn, 6, dlgt.height / 2),
           label + " · 行左侧空白处不落在按钮里（按钮没错误地铺满整行）")
    }

    function listCount(pageRoot, name) {
        var l = findByName(pageRoot, name)
        return l ? l.count : -1
    }

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onLoaded: {
            var it = ld.item
            if (!it) { console.log("CHECK FAIL 加载 main.qml 得到空对象"); Qt.quit(); return }
            root.app = it
            stageTimer.restart()
        }

        onStatusChanged: {
            if (status === Loader.Error) {
                console.log("CHECK FAIL main.qml 加载失败（Loader.Error）")
                Qt.quit()
            }
        }
    }

    property int stage: 0

    Timer {
        id: stageTimer
        interval: 500
        repeat: true

        onTriggered: {
            var it = root.app
            if (!it) return

            if (root.stage === 0) {
                console.log("--- 1. 造数据 + 进歌单页 ---")
                // 探针写在 qmlscene 自己的 LocalStorage 里（与插件的库不是同一份，
                // 见 filemap-device 的结论），但仍先清空，保证断言从确定状态出发。
                it.playlists = []
                var r = it.createPlaylist("测试歌单", "online")
                ok(!!(r && r.ok), "1a createPlaylist 成功")
                root.plId = r ? r.id : ""
                ok(root.plId.length > 0, "1b 拿到歌单 id: " + root.plId)

                ok(it.addSongToPlaylist(root.plId, root.songA).ok, "1c 加第一首")
                ok(it.addSongToPlaylist(root.plId, root.songB).ok, "1d 加第二首")
                // 重复加同一首必须被拒（否则列表里会出现两条一样的）
                ok(it.addSongToPlaylist(root.plId, root.songA).ok === false, "1e 重复加同一首被拒")

                it.goPlaylists()
                root.stage = 1

            } else if (root.stage === 1) {
                console.log("--- 2. 歌单列表页 ---")
                ok(it.page === "playlists", "2a 当前页是歌单页")
                ok(root.listCount(it, "gdPlaylistList") === 1, "2b 列表里有 1 个歌单（实际 "
                   + root.listCount(it, "gdPlaylistList") + "）")
                probeBtn(it, "gdPlaylistList", "gdPlPlayBtn", "gdPlRowTapArea", "歌单页·▶")

                var tag = findByName(it, "gdPlTypeTag")
                ok(!!tag && root.textOf(tag) === "在线", "2c 类型徽标显示「在线」（实际 "
                   + (tag ? root.textOf(tag) : "-") + "）")
                ok(it.plStat === "1 个歌单 · 共 2 首", "2d 底部统计：" + it.plStat)

                // tab 三个标签 + 文案
                var row = findByName(it, "gdTabRow")
                ok(!!row, "2e 找到标签行 gdTabRow")
                if (row) {
                    var rects = []
                    var ch = row.children || []
                    for (var i = 0; i < ch.length; i++)
                        if (String(ch[i]).indexOf("QQuickRectangle") === 0) rects.push(ch[i])
                    ok(rects.length === 3, "2f 标签数量为 3（实际 " + rects.length + "）")
                    var labels = rects.map(function (x) { return root.textOf(x) })
                    ok(labels.join("/") === "搜索/本地/歌单", "2g 标签文案：" + labels.join("/"))
                    // 三个标签不能压到左上角返回键 / 右上角设置键上
                    var first = rects[0], last = rects[rects.length - 1]
                    if (first && last) {
                        var fl = first.mapToItem(it, 0, 0)
                        var lr = last.mapToItem(it, last.width, 0)
                        ok(fl.x >= 36, "2h 首个标签不与返回键重叠（x=" + Math.round(fl.x) + "）")
                        ok(lr.x <= 284, "2i 末个标签不与设置键重叠（右边界=" + Math.round(lr.x) + "）")
                    }
                }
                root.stage = 2

            } else if (root.stage === 2) {
                console.log("--- 3. 进详情页 ---")
                it.openPlaylist(root.plId)
                root.stage = 3

            } else if (root.stage === 3) {
                ok(it.page === "playlist", "3a 当前页是详情页")
                ok(!!it.plView, "3b plView 非空")
                ok(it.plView && it.plView.count === 2, "3c plView.count === 2（实际 "
                   + (it.plView ? it.plView.count : "-") + "）")
                ok(root.listCount(it, "gdPlDetailList") === 2, "3d 详情页列表渲染出 2 行（实际 "
                   + root.listCount(it, "gdPlDetailList") + "）")
                ok(!!findByName(it, "gdPlPlayAllBtn"), "3e 「播放全部」按钮在")
                var pb = findByName(it, "gdPlPlayAllBtn")
                ok(pb && Math.abs(pb.width - 34) < 0.5 && Math.abs(pb.height - 24) < 0.5,
                   "3f 「播放全部」尺寸 34×24（实际 " + (pb ? pb.width + "×" + pb.height : "-") + "）")
                probeBtn(it, "gdPlDetailList", "gdPlSongDelBtn", "gdPlSongTapArea", "详情页·×")
                root.stage = 4

            } else if (root.stage === 4) {
                console.log("--- 4. ★ 详情页开着时加歌，列表必须跟着涨 ---")
                var before = root.listCount(it, "gdPlDetailList")
                it.addSongToPlaylist(root.plId, root.songC)
                var after = root.listCount(it, "gdPlDetailList")
                ok(before === 2, "4a 加歌前 2 行（实际 " + before + "）")
                // ★ 这一条就是 plView 那层"每次重建新对象"存在的理由。
                //   写错了的话列表会停在 2，而数据其实是 3 —— 界面看不出来。
                ok(after === 3, "4b 加歌后详情页列表变成 3 行（实际 " + after
                   + "）—— 不涨就是 plView 没生效")
                ok(it.plView && it.plView.count === 3, "4c plView.count 同步为 3")
                root.stage = 5

            } else if (root.stage === 5) {
                console.log("--- 5. 移除 → 列表必须跟着掉 ---")
                ok(it.removeSongAtUI(root.plId, 0) === true, "5a removeSongAtUI 返回 true")
                root.stage = 6

            } else if (root.stage === 6) {
                ok(root.listCount(it, "gdPlDetailList") === 2,
                   "5b 移除一首后剩 2 行（实际 " + root.listCount(it, "gdPlDetailList") + "）")
                it.deletePlaylist(root.plId)
                root.stage = 7

            } else if (root.stage === 7) {
                ok(root.listCount(it, "gdPlDetailList") === 0,
                   "5c 歌单被删后详情页清空（实际 " + root.listCount(it, "gdPlDetailList") + "）")
                ok(it.plView === null, "5d 歌单没了 plView 返回 null（不是抛异常）")
                it.closePlaylistDetail()
                root.stage = 8

            } else if (root.stage === 8) {
                ok(it.page === "playlists", "6a 返回键回到歌单列表")
                ok(root.listCount(it, "gdPlaylistList") === 0,
                   "6b 列表页变空（实际 " + root.listCount(it, "gdPlaylistList") + "）")
                ok(it.plStat === "0 个歌单 · 共 0 首", "6c 统计归零：" + it.plStat)
                stop()
                console.log("")
                console.log("CHECK DONE pass=" + root.pass + " bad=" + root.bad)
                Qt.quit()
            }
        }
    }
}
