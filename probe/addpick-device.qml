import QtQuick 2.12

// 在**真机**上验证「加歌入口」—— 播放页的 ＋、三处行长按、以及「加入歌单」页。
//
// 与 probe/addpick.sh（读源码）互补：那边只能证明"接线写对了"，这里用真 QML 引擎
// 跑真代码，验证四件静态检查碰不到的事：
//   ① AddToPlaylistPage 能不能真的被解析并实例化（本地没有 Qt，这是唯一的权威检查）
//   ② ★ 加完一首歌后，徽标会不会从「加入」变成「已在」—— addPickEntries 那层值重建
//      就是为它设计的。写错了会出现「歌单里已经有这首、界面还写着『加入』」，
//      再点一下只会得到一句 E_DUP，用户完全不知道发生了什么。
//   ③ addTargetOf 的双形态补全：已下载的在线歌必须同时带 id 与 file，
//      否则它只能进在线歌单，离线歌单永远收不到东西。
//   ④ MouseArea.pressAndHoldInterval 的**运行时**值 > 0：默认取自 QStyleHints，
//      平台返回 -1 时长按静默失效，而源码里看不出任何问题。
//
// ⚠️ 长按的**实际触发**在这里测不到：qmlscene 离屏渲染，QML 层也没有合成鼠标事件的
//    API（Connections + target 那套验变更通知的写法在 QML 里同样不可靠）。
//    所以长按只验证到"配置就绪"，真机上手指试一下才算数 —— 播放页的 ＋ 是兜底入口。
//
// 用法（设备上）：
//   adb push probe/addpick-device.qml /tmp/
//   adb shell "cd /userdisk/PenMods/plugins/gdmusic/qml && HOME=/tmp \
//              QT_QPA_PLATFORM=offscreen timeout 90 /usr/bin/qmlscene /tmp/addpick-device.qml"
//   跑完必须 grep "Unable to assign" / "TypeError" / "ReferenceError"，要求零输出。
Item {
    id: root
    width: 320
    height: 170

    property int pass: 0
    property int bad: 0
    property var app: null
    property string plOnline: ""
    property string plLocal: ""
    // 假造的"已下载"文件。名字里带 unlikely，撞不上真实下载目录里的任何歌，
    // 而 findLocal 的命中靠 localPathFor 的同名公式 —— 名字一致就必然命中。
    readonly property string fakeFile: "/userdisk/Music/GDMusic/probe-假歌-测试人.mp3"
    readonly property var onlineSong: ({ id: "1997293311", source: "netease",
                                          name: "probe-假歌", artist: "测试人" })
    // 纯在线歌：名字与假文件对不上 ⇒ 载体补不到 file ⇒ 只能进在线歌单
    readonly property var pureOnline: ({ id: "3363090011", source: "netease",
                                          name: "绝不命中的一首", artist: "某人" })

    function ok(cond, label) {
        if (cond) { pass++; console.log("  OK   " + label) }
        else      { bad++;  console.log("  BAD  " + label) }
    }

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
    // 同名 objectName 在真机上不止一处（搜索页/本地页/详情页的整行点击区都叫 gdRowTapArea）
    function findAllByName(item, name, acc) {
        if (!item) return acc
        if (item.objectName === name) acc.push(item)
        var ch = item.children || []
        for (var i = 0; i < ch.length; i++) findAllByName(ch[i], name, acc)
        return acc
    }
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
    function listCount(pageRoot, name) {
        var l = findByName(pageRoot, name)
        return l ? l.count : -1
    }
    // 逐行读徽标文字：返回 ["加入","已在"] 这样的数组
    function badgesOf(pageRoot, listName) {
        var list = findByName(pageRoot, listName)
        if (!list) return []
        var out = []
        for (var i = 0; i < list.count; i++) {
            var d = list.itemAtIndex(i)
            var b = d ? findByName(d, "gdAddPickBadge") : null
            out.push(b ? textOf(b) : "(无徽标)")
        }
        return out
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
                console.log("--- 1. 造数据：两个歌单 + 一条假装的已下载记录 ---")
                it.playlists = []
                var a = it.createPlaylist("在线测试", "online")
                var b = it.createPlaylist("离线测试", "local")
                ok(!!(a && a.ok) && !!(b && b.ok), "1a 两个歌单建好")
                root.plOnline = a ? a.id : ""
                root.plLocal = b ? b.id : ""

                // localList 就是磁盘真源。直接覆盖成一条造的记录，
                // 才有"确实已下载 ⇒ 载体能补出 file"这个前提。
                it.localList = [{ file: root.fakeFile, size: 5000000,
                                  name: "probe-假歌", artist: "测试人" }]
                ok(it.localList.length === 1, "1b 假下载记录已就位")
                ok(it.localRecOf(root.onlineSong) !== null,
                   "1c ★ localRecOf 命中这条记录（双形态补全的前提）")
                root.stage = 1

            } else if (root.stage === 1) {
                console.log("--- 2. 打开加歌页：双形态补全 ---")
                ok(it.page === "playlists" || it.page === "search", "2a 起点页（实际 " + it.page + "）")
                it.goLocal()                    // 模拟"从本地页长按进来"
                it.openAddPick(root.onlineSong)
                ok(it.page === "addpick", "2b 已切到加歌页（实际 " + it.page + "）")
                ok(it.backPage === "local", "2c backPage 记的是来处（实际 " + it.backPage + "）")

                var t = it.addPickSong
                ok(!!t, "2d 载体非空")
                // ❗双形态：在线歌单要 id、离线歌单要 file，两个都必须在
                ok(t && String(t.id) === "1997293311", "2e 载体带上了在线身份 id")
                ok(t && t.file === root.fakeFile,
                   "2f ★ 载体补出了本地文件 file（没有它就加不进离线歌单）")
                ok(t && Number(t.size) === 5000000, "2g 载体带上了文件大小")

                // 关掉"已下载优先"也不能影响加歌 —— 否则用户一关开关，离线歌单就永远是空的
                it.preferLocal = false
                ok(it.localRecOf(root.onlineSong) !== null,
                   "2h ★ 关掉『已下载优先』后 localRecOf 仍能找到文件")
                it.preferLocal = true
                root.stage = 2

            } else if (root.stage === 2) {
                console.log("--- 3. list 态：两个歌单都应可加 ---")
                ok(root.listCount(it, "gdAddPickList") === 2,
                   "3a 列表渲染出 2 行（实际 " + root.listCount(it, "gdAddPickList") + "）")
                var b1 = root.badgesOf(it, "gdAddPickList")
                ok(b1.join("/") === "加入/加入", "3b 两个徽标都是「加入」（实际 " + b1.join("/") + "）")
                ok(it.addPickStat === "2 个歌单 · 2 个可加入", "3c 统计：" + it.addPickStat)

                var tag = findByName(it, "gdAddPickShapeTag")
                ok(!!tag && root.textOf(tag) === "在线 · 已下载",
                   "3d 形态标签显示「在线 · 已下载」（实际 " + (tag ? root.textOf(tag) : "-") + "）")

                // 徽标不能被整行点击区压住（否则永远点不到"加入"）
                var list = findByName(it, "gdAddPickList")
                var dlgt = list ? list.itemAtIndex(0) : null
                ok(!!dlgt, "3e 第一行已创建")
                if (dlgt) {
                    var badge = findByName(dlgt, "gdAddPickBadge")
                    ok(!!badge, "3f 第一行有徽标")
                    if (badge) {
                        var c = badge.mapToItem(dlgt, badge.width / 2, badge.height / 2)
                        ok(root.hitIsInside(dlgt, badge, c.x, c.y),
                           "3g ★ 徽标中心上层的对象是徽标自己 → 实际命中 " + root.nameOf(dlgt.childAt(c.x, c.y)))
                    }
                    var area = findByName(dlgt, "gdAddPickRowTapArea")
                    ok(!!area && Math.abs(area.width - dlgt.width) < 0.5,
                       "3h 整行点击区仍铺满整行")
                }
                ok(!!findByName(it, "gdAddPickNewBtn"), "3i 「+ 新建歌单」在")
                ok(!!findByName(it, "gdAddPickSrcRow"), "3j 来源行在（得让人确认加的是哪首）")
                root.stage = 3

            } else if (root.stage === 3) {
                console.log("--- 4. ★ 加入之后徽标必须从「加入」变「已在」 ---")
                it.doAddPick(root.plOnline)
                ok(it.page === "local", "4a 加入后回到来处（实际 " + it.page + "）")
                ok(it.playlists[0].songs.length === 1, "4b 歌单里真的多了一首")

                it.openAddPick(root.onlineSong)
                var b2 = root.badgesOf(it, "gdAddPickList")
                ok(b2.join("/") === "已在/加入",
                   "4c ★ 徽标变成「已在/加入」（实际 " + b2.join("/") + "）—— 不变就是 addPickEntries 没重建")
                ok(it.addPickStat === "2 个歌单 · 1 个可加入", "4d 统计跟着变：" + it.addPickStat)
                root.stage = 4

            } else if (root.stage === 4) {
                console.log("--- 5. 纯在线歌：离线歌单不可加（type 态灰掉）---")
                it.openAddPick(root.pureOnline)
                var t2 = it.addPickSong
                ok(t2 && !t2.file, "5a 纯在线歌补不到 file（没命中本地）")
                ok(it.addTargetFits(t2, "online") === true,  "5b 能进在线歌单")
                ok(it.addTargetFits(t2, "local") === false,  "5c ★ 进不了离线歌单")

                var b3 = root.badgesOf(it, "gdAddPickList")
                ok(b3.join("/") === "加入/不符",
                   "5d 徽标是「加入/不符」（实际 " + b3.join("/") + "）")

                it.addPickStep = "type"
                var col = findByName(it, "gdAddPickTypeCol")
                ok(!!col && col.visible, "5e 选类型那一步已显示")
                var on = findByName(it, "gdAddPickTypeOnline")
                var off = findByName(it, "gdAddPickTypeOffline")
                ok(!!on && on.fits === true,  "5f 在线那行可选")
                ok(!!off && off.fits === false, "5g ★ 离线那行被灰掉（fits=false）")
                ok(!!findByName(it, "gdAddPickTypeBack"), "5h 有「返回选择歌单」")
                root.stage = 5

            } else if (root.stage === 5) {
                console.log("--- 6. 返回键在两态间回退，而不是直接离开 ---")
                it.closeAddPick()
                it.openAddPick(root.pureOnline)
                it.addPickStep = "type"
                var bar = findByName(it, "gdAddPickTypeBack")
                ok(!!bar, "6a 返回按钮在")
                // 直接调它上面的 MouseArea 走一遍（offscreen 下没法真的点）。
                // ⚠️ clicked 信号带一个 MouseEvent 参数，**无参调用会报
                //    "Insufficient arguments" 并在每个 timer tick 重复刷屏** ⇒ 必须传 null。
                var fired = false
                if (bar) {
                    var ch = bar.children || []
                    for (var i = 0; i < ch.length; i++)
                        if (String(ch[i]).indexOf("MouseArea") >= 0) {
                            ch[i].clicked(null); fired = true; break
                        }
                }
                ok(fired, "6b 找到返回按钮上的 MouseArea 并触发")
                ok(it.page === "addpick" && it.addPickStep === "list",
                   "6c ★ 点返回后停在 addpick/list（不是退出整页）")
                root.stage = 6

            } else if (root.stage === 6) {
                console.log("--- 7. 关闭后状态清干净（★ 这里刻意覆盖了「重复打开」）---")
                // ⚠️ stage 4/5 连续调了 openAddPick 而没先关 ⇒ 这时 backPage 若被写成
                //    "addpick"，closeAddPick 就会把 page 设回 "addpick"，
                //    表现为「怎么按返回都出不去这个页面」。
                //    真机探针里唯一能覆盖这条路径的地方就是这里，别把它"顺手修好"。
                it.closeAddPick()
                ok(it.addPickSong === null, "7a addPickSong 已清空（下次不会残留上一首）")
                ok(it.page === "local", "7b ★ 关闭后回到**最初**的来处（实际 " + it.page
                   + "）—— 停在 addpick 就是 backPage 被重复打开污染了")
                root.stage = 7

            } else if (root.stage === 7) {
                console.log("--- 8. 播放页的 ＋ 按钮 ---")
                it.currentSong = root.onlineSong
                it.openPlayer()
                ok(it.page === "player", "8a 播放页已显示")
                var ab = findByName(it, "gdPlayerAddBtn")
                ok(!!ab, "8b ★ 播放页有 ＋ 按钮（不依赖长按的兜底入口）")
                if (ab) {
                    ok(Math.abs(ab.width - 36) < 0.5 && Math.abs(ab.height - 32) < 0.5,
                       "8c ＋ 按钮尺寸 36×32（实际 " + ab.width + "×" + ab.height + "）")
                    var p = ab.mapToItem(it, ab.width, ab.height)
                    ok(p.x <= 316, "8d ＋ 按钮没超出屏幕（右边界 " + Math.round(p.x) + "）")
                    // Canvas 的 plus 分支有没有真的画（onPaint 报错会被 warning 抓到，这里兜一道）
                    ok(!!(ab.children || []).length, "8e 按钮里有 Canvas 图元")
                }
                // 点它：应该带着当前这首歌进加歌页（同样是 clicked(null)，理由见 6b）
                if (ab) {
                    var ch2 = ab.children || []
                    for (var j = 0; j < ch2.length; j++)
                        if (String(ch2[j]).indexOf("MouseArea") >= 0) { ch2[j].clicked(null); break }
                }
                ok(it.page === "addpick" && it.addPickSong && it.addPickSong.id === "1997293311",
                   "8f ★ 点 ＋ 带着当前这首歌进了加歌页")
                it.closeAddPick()
                root.stage = 8

            } else if (root.stage === 8) {
                console.log("--- 9. 三处长按的运行时配置 ---")
                // 三个列表都要有 delegate，itemArea 才会被创建
                it.results = [root.pureOnline, root.onlineSong]
                it.openPlaylist(root.plLocal)
                root.stage = 9

            } else if (root.stage === 9) {
                it.addSongToPlaylist(root.plLocal, root.pureOnline)
                it.openPlaylist(root.plLocal)
                root.stage = 10

            } else if (root.stage === 10) {
                var areas = root.findAllByName(it, "gdRowTapArea", [])
                areas = areas.concat(root.findAllByName(it, "gdPlSongTapArea", []))
                ok(areas.length >= 3,
                   "10a 三个列表的整行点击区都创建了（实际 " + areas.length + "）")
                var badIv = 0, noGuard = 0, notFired = 0
                for (var i = 0; i < areas.length; i++) {
                    var a = areas[i]
                    // pressAndHoldInterval 运行时 > 0：平台给 -1 的话长按是死代码，
                    // 而源码里看不出任何问题 —— 这条只能在真机上问引擎。
                    if (!(a.pressAndHoldInterval > 0)) badIv++
                    if (a.longFired !== false) notFired++
                    if (typeof a.clicked === "undefined") noGuard++
                }
                ok(badIv === 0,
                   "10b ★ 所有整行点击区的 pressAndHoldInterval > 0（有 " + badIv + " 个是 0/-1 ⇒ 长按静默失效）")
                ok(notFired === 0, "10c longFired 初值都是 false（有 " + notFired + " 个不是）")

                // 详情页底部提示里的"长按"文案
                ok(root.textOf(findByName(it, "gdLocalLongPressHint")) === "长按歌曲加入歌单",
                   "10d 本地页底部长按提示："
                   + root.textOf(findByName(it, "gdLocalLongPressHint")))
                root.stage = 11

            } else if (root.stage === 11) {
                // 收尾：把造的 song 加进离线歌单，确认"本地歌 + 登记表"这条路也是通的
                it.closePlaylistDetail()
                var fake = { id: "", file: root.fakeFile, name: "probe-假歌",
                             artist: "测试人", size: 5000000 }
                it.openAddPick(fake)
                ok(it.addPickSong && it.addPickSong.file === root.fakeFile,
                   "11a 本地条目作为载体时 file 原样带上")
                var bl = root.badgesOf(it, "gdAddPickList")
                ok(bl.join("/") === "不符/加入",
                   "11b 本地歌对在线歌单是「不符」、对离线歌单是「加入」（实际 " + bl.join("/") + "）")

                it.closeAddPick()
                stop()
                console.log("")
                console.log("CHECK DONE pass=" + root.pass + " bad=" + root.bad)
                Qt.quit()
            }
        }
    }
}
