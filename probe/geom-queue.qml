import QtQuick 2.12

// 顶栏几何探针：验证新增的 ▶ 按钮**不会压到**顶部的 tab 标签上。
//
// 为什么必须单独测：320×170 的屏上，tabRow 是三个 58px 标签（共 182px），
// 右上角每加一个 30px 按钮，可用区就少 34px。纯看源码**完全看不出**会不会撞上 ——
// 只有把坐标真的算出来才知道。2026-10-06 加 ▶ 时实测只剩 1px 间隙，肉眼就是"粘住了"。
//
// ⚠️ 必须**分步跨帧**跑（2026-10-06 踩坑）：第一版在同一个 onLoaded 里连着做
//    「赋值 currentSong → 立刻读 Row 宽度」，结果 Row 还没来得及按新的 visible
//    重排，读回来仍是旧值 —— 于是 ▶ 没显示的情况下也报"间隙 35px 通过"，
//    这条断言等于没测。**凡是量几何，改完状态必须让出一帧再读。**
Item {
    width: 320
    height: 170

    property int bad: 0
    property int pass: 0
    property int step: 0
    property int btnW0: 0

    function ok(cond, label) {
        if (cond) { pass++; console.log("  OK   " + label) }
        else      { bad++; console.log("  BAD  " + label) }
    }

    // QML 里没有直接的 findChild(name)，必须自己递归 children
    function findByName(obj, name) {
        if (!obj) return null
        for (var i = 0; i < obj.children.length; i++) {
            var c = obj.children[i]
            if (c.objectName === name) return c
            var r = findByName(c, name)
            if (r) return r
        }
        return null
    }

    // 标签右边界 与 按钮组左边界 之间的空隙（root 坐标系）
    function gapOf(it) {
        var tr = findByName(it, "gdTabRow")
        var bt = findByName(it, "gdRightBtns")
        if (!tr || !bt) return null
        var pR = it.mapFromItem(tr, tr.width, 0)
        var pL = it.mapFromItem(bt, 0, 0)
        return { gap: (pL.x - pR.x), tabRight: pR.x, btnLeft: pL.x,
                 tabW: tr.width, btnW: bt.width }
    }

    function run(it) {
        if (step === 0) {
            console.log("--- ① 未播放时：顶栏只有设置键 ---")
            it.page = "search"
            it.currentSong = null
            it.queue = []
            step = 1; Qt.callLater(function(){ tick(it) }); return
        }
        if (step === 1) {
            var g = gapOf(it)
            ok(!!g, "能取到 tabRow / rightBtns 的几何")
            btnW0 = 0
            if (g) {
                btnW0 = g.btnW
                console.log("     tabRow 右边界=" + g.tabRight + "  按钮组左边界="
                            + g.btnLeft + "（宽 " + g.btnW + "）")
                ok(g.btnW <= 34, "未播放时按钮组只有设置键（宽 " + g.btnW + "）")
                ok(g.gap >= 4, "间隙 " + g.gap + "px")
            }
            // ② → 让它"播过歌"，看 ▶ 是否真的出现
            it.currentSong = { id: "1", source: "netease", name: "测", artist: "试" }
            it.queue = [{ id: "1", source: "netease", name: "甲", artist: "A" },
                        { id: "2", source: "netease", name: "乙", artist: "B" }]
            it.queueIndex = 0
            step = 2; Qt.callLater(function(){ tick(it) }); return
        }
        if (step === 2) {
            console.log("--- ② 播过歌之后：应多出一个 ▶ ---")
            ok(it.hasNowPlaying === true, "hasNowPlaying 已变 true（currentSong 有值）")
            var g2 = gapOf(it)
            if (g2) {
                console.log("     tabRow 右边界=" + g2.tabRight + "  按钮组左边界="
                            + g2.btnLeft + "（宽 " + g2.btnW + "）")
                // ⭐ 这条是整套断言的前提：▶ 没真的出现，下面全是空谈
                ok(g2.btnW > btnW0,
                   "▶ 真的显示出来了（按钮组 " + btnW0 + " → " + g2.btnW + "）")
                ok(g2.gap >= 4, "加 ▶ 后标签与按钮仍有 " + g2.gap + "px 间隙")
                ok(g2.btnLeft + g2.btnW <= 320, "按钮组没被挤出屏幕右边")
                ok(g2.tabRight >= 38, "标签没被挤到返回键下面（" + g2.tabRight + " ≥ 38）")
            }
            step = 3; Qt.callLater(function(){ tick(it) }); return
        }
        if (step === 3) {
            console.log("--- ③ 队列页：能切过去且列表几何正常 ---")
            it.openQueue()
            step = 4; Qt.callLater(function(){ tick(it) }); return
        }
        if (step === 4) {
            var it2 = ld.item
            ok(it2.page === "queue", "openQueue → page=queue（真的切过去了）")
            var lv = findByName(it2, "gdQueueList")
            ok(!!lv, "队列 ListView 存在")
            if (lv) {
                ok(lv.y === 32, "列表顶边让开了 TitleBar（y=" + lv.y + "）")
                ok(lv.height === 170 - 32, "列表高度=" + lv.height + "（应 138，别溢出屏幕）")
                ok(lv.width === 320, "列表宽度=" + lv.width)
            }
            it2.goQueueBack()
            step = 5; Qt.callLater(function(){ tick(it2) }); return
        }
        if (step === 5) {
            ok(ld.item.page === "player", "队列页返回 → 回到播放页")
            console.log("--- ④ ▶ 回到播放页 ---")
            ld.item.page = "search"
            ld.item.gotoPlayer()
            ok(ld.item.page === "player", "从搜索页点 ▶ → 进播放页")
            console.log("GEOM DONE pass=" + pass + " bad=" + bad)
            Qt.quit()
        }
    }

    function tick(it) { run(it) }

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onLoaded: {
            var it = ld.item
            if (!it) { console.log("GEOM FAIL 空对象"); Qt.quit(1); return }
            // 先让它渲染一帧再开始，否则第一次量到的还是初始布局
            Qt.callLater(function(){ tick(it) })
        }
    }
}
