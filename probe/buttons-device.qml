import QtQuick 2.12

// 在**真机**上验证「按钮到底点得到点不到」。
//
// 与 probe/buttons.sh（读源码结构）互补：那边只能证明"顺序写对了"，
// 这里用真 QML 引擎的 Item.childAt(x, y) 做**行为**验证 ——
// 它返回该坐标上最上层的那个子项，正是鼠标事件会先派发到的对象。
// 于是"按钮上面是不是压着整行点击区"这件事可以直接问出来，不用靠推理。
//
// 用法（设备上）：
//   adb push probe/buttons-device.qml /tmp/
//   adb shell "cd /userdisk/PenMods/plugins/gdmusic/qml && HOME=/tmp \
//              QT_QPA_PLATFORM=offscreen timeout 60 /usr/bin/qmlscene /tmp/buttons-device.qml"
Item {
    id: root
    width: 320
    height: 170

    property int pass: 0
    property int bad: 0
    property var app: null

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

    function nameOf(item) {
        if (!item) return "(空)"
        return item.objectName ? item.objectName : "(无 objectName 的 " + item + ")"
    }

    // 命中的最上层子项，是否落在 anc 内部（它自己或它的后代）
    function hitIsInside(container, anc, x, y) {
        var it = container.childAt(x, y)
        while (it) { if (it === anc) return true; it = it.parent }
        return false
    }

    // 对一个按钮：取其中心点，问"这一点上最上层是谁"
    function probe(pageRoot, listName, btnName, label) {
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
           label + " · 按钮中心(" + Math.round(c.x) + "," + Math.round(c.y) + ") 上层的对象是按钮自己"
           + " → 实际命中 " + nameOf(hit))

        // 顺带确认按钮自己的 MouseArea 确实铺满按钮（而不是只有字形那么大）
        var ma = null
        var ch = btn.children || []
        for (var i = 0; i < ch.length; i++) {
            // ❗用 String() 判类型而不是 hasOwnProperty("pressed")：
            //    QML 里 MouseArea 是 QObject，pressed 在元对象上、不在 JS 自有属性里，
            //    hasOwnProperty 会返回 false。
            if (String(ch[i]).indexOf("MouseArea") >= 0) { ma = ch[i]; break }
        }
        ok(!!ma, label + " · 按钮内有 MouseArea")
        if (ma)
            ok(Math.abs(ma.width - btn.width) < 0.5 && Math.abs(ma.height - btn.height) < 0.5,
               label + " · MouseArea 铺满按钮 (" + Math.round(ma.width) + "x" + Math.round(ma.height)
               + " vs 按钮 " + btn.width + "x" + btn.height + ")")

        // 反向断言：修按钮不能把"点整行播放"搞坏 —— 整行点击区必须还在、还铺满整行
        var rowArea = findByName(dlgt, "gdRowTapArea")
        ok(!!rowArea, label + " · 整行点击区仍然存在（点行播放没被改坏）")
        if (rowArea)
            ok(Math.abs(rowArea.width - dlgt.width) < 0.5,
               label + " · 整行点击区仍铺满整行（" + Math.round(rowArea.width)
               + " vs " + Math.round(dlgt.width) + "）")

        // 按钮不能错误地铺满整行
        ok(!hitIsInside(dlgt, btn, 6, dlgt.height / 2),
           label + " · 行左侧空白处不落在按钮里（按钮没错误地铺满整行）")
    }

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onLoaded: {
            var it = ld.item
            if (!it) { console.log("CHECK FAIL 加载 main.qml 得到空对象"); Qt.quit(1); return }
            root.app = it

            var D = "/userdisk/Music/GDMusic"
            // 真机探针不依赖宿主扫描：直接喂两条，保证 delegate 一定会被创建。
            // 第二条刻意让 matched 缺失 —— 顺便验证不再刷 "Unable to assign [undefined] to bool"。
            it.localList = [
                { file: D + "/铁花飞-回春丹.mp3", size: 8830440,
                  name: "铁花飞", artist: "回春丹", matched: true },
                { file: D + "/未匹配示例.mp3", size: 1024,
                  name: "未匹配示例", artist: "" }
            ]
            it.results = [
                { id: "1997293311", source: "netease", name: "断气", artist: "回春丹" }
            ]
            it.page = "local"
            stageTimer.restart()
        }

        onStatusChanged: {
            if (status === Loader.Error) {
                console.log("CHECK FAIL main.qml 加载失败（Loader.Error）")
                Qt.quit(1)
            }
        }
    }

    property int stage: 0

    Timer {
        id: stageTimer
        interval: 500
        repeat: true
        onTriggered: {
            if (root.stage === 0) {
                console.log("--- 1. 本地页：? / ✓ 与 × ---")
                probe(root.app, "gdLocalList", "gdLocalMatchBtn", "本地页·匹配徽标")
                probe(root.app, "gdLocalList", "gdLocalDelBtn",   "本地页·删除键")
                root.stage = 1
                root.app.page = "search"
            } else if (root.stage === 1) {
                console.log("--- 2. 搜索页：↓ ---")
                probe(root.app, "gdResultList", "gdSearchDlBtn", "搜索页·下载键")
                root.stage = 2
            } else {
                stop()
                console.log("")
                console.log("CHECK DONE pass=" + root.pass + " bad=" + root.bad)
                // ⚠️ 2026-10-05：裸 Qt.quit() == Qt.quit(0)，失败也返回 0
                //    ⇒ 退出码通道是断的。照抄 login-device.qml:126-127。
                if (root.bad > 0) Qt.quit(1)
                else Qt.quit(0)
            }
        }
    }
}
