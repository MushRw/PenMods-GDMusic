import QtQuick 2.12

// 几何自检：320×170 的屏幕上，新加的「历史」按钮和浮层到底摆在哪、有没有出界。
// 设备截不了图（mmap /dev/fb0 会 panic，mpv 又没图片编码器），
// 所以只能把实际坐标打出来看 —— 这是唯一能拿到的"看得见"的证据。
Item {
    id: host
    width: 320
    height: 170

    function find(o, name) {
        if (!o) return null
        if (o.objectName === name) return o
        var kids = o.children
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var r = find(kids[i], name)
            if (r) return r
        }
        return null
    }

    function dump(tag, o) {
        if (!o) { console.log("GEO " + tag + "=NOT-FOUND"); return false }
        // 转成 root 坐标系：mapFromItem 需要同源 item，这里都用 main.qml 的根做参照
        var p = o.mapToItem(host, 0, 0)
        var over = (p.x < 0) || (p.y < 0)
                 || (p.x + o.width > 320.5) || (p.y + o.height > 170.5)
        console.log("GEO " + tag + " x=" + p.x.toFixed(1) + " y=" + p.y.toFixed(1)
                    + " w=" + o.width.toFixed(1) + " h=" + o.height.toFixed(1)
                    + " vis=" + o.visible + " over=" + over)
        return !over
    }

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onStatusChanged: {
            if (status === Loader.Error) { console.log("GEO LOAD-ERROR"); Qt.quit(); return }
            if (status !== Loader.Ready) return

            var r = ld.item
            var okAll = true

            console.log("GEO root w=" + r.width + " h=" + r.height)

            // 关闭时先量一次（浮层应不可见）
            r.historyOpen = false
            okAll = dump("btnHistory", find(r, "gdBtnHistory")) && okAll
            okAll = dump("inputBox",   find(r, "gdInputBox"))   && okAll
            okAll = dump("btnGo",      find(r, "gdBtnGo"))      && okAll

            // 塞几条历史，再打开浮层量一次
            r.searchHistory = ["稻香", "晴天", "七里香", "夜空中最亮的星",
                               "起风了", "花海", "一路向北"]
            r.historyOpen = true
            okAll = dump("popup",      find(r, "gdHistoryPopup")) && okAll
            okAll = dump("popupList",  find(r, "gdHistoryList"))  && okAll

            var pop = find(r, "gdHistoryPopup")
            var lst = find(r, "gdHistoryList")
            if (pop && lst) {
                console.log("GEO popupFits=" + (lst.y + lst.height <= pop.height + 0.5))
                // 7 条 × 24 已超过可用高度，必须被 Math.min 截住并交给 ListView 滚动
                console.log("GEO listScrollable=" + (lst.contentHeight > lst.height)
                            + " contentH=" + lst.contentHeight.toFixed(1))
            }

            // 只有 1 条时浮层应当矮下去，而不是撑满整屏
            r.searchHistory = ["稻香"]
            okAll = dump("popup1", find(r, "gdHistoryPopup")) && okAll

            // 顶部并列标签：搜索页与本地页共用同一条 TitleBar，
            // 标签必须落在返回键(右侧 32)与设置键(左侧 288)之间，否则会互相盖住点击
            var tab = find(r, "gdTabRow")
            if (tab) {
                var tp = tab.mapToItem(host, 0, 0)
                console.log("GEO tabRow x=" + tp.x.toFixed(1) + " w=" + tab.width.toFixed(1)
                            + " clearLeft=" + (tp.x > 32) + " clearRight="
                            + (tp.x + tab.width < 288))
            } else console.log("GEO tabRow=NOT-FOUND")

            console.log("GEO ALL-IN-BOUNDS=" + okAll)
            Qt.quit()
        }
    }
}
