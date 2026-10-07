import QtQuick 2.12

// 播放页几何探针（A1 布局）—— 断言四个区域**不重叠、不越界**，并量出歌词真实宽度。
//
// 为什么必须单独测：320×170 上，封面 72 + 歌词 + 底部播控 116 挤在 320 里，
// 谁压到谁**在源码里完全看不出来** —— 只有把坐标真的算出来才知道。
// 本项目已踩过同类坑：geom-queue.qml 记着「加 ▶ 时实测只剩 1px 间隙，肉眼就是粘住了」。
//
// ⚠️ 分步跨帧：凡是量几何，改完状态必须让出一帧再读（否则 Row 还没重排，读到旧值）。
Item {
    id: root
    width: 320
    height: 170

    property int bad: 0
    property int pass: 0
    property int step: 0
    property var pageObj: null

    // 找到 PlayerPage 的实例。
    // 判据用「有 showInfo 属性」而不是类名字符串 —— QML 里 typeof/toString 在
    // 不同 Qt 版本下格式不同（"PlayerPage_QMLTYPE_12" 之类），靠字符串匹配很脆。
    function findPage(rootItem, obj) {
        if (!obj) return null
        // 有 showInfo 且不是 main.qml 根（根没有这个属性，所以这一条就够）
        if (obj.showInfo !== undefined && obj.infoRows !== undefined) return obj
        for (var i = 0; i < obj.children.length; i++) {
            var r = findPage(rootItem, obj.children[i])
            if (r) return r
        }
        return null
    }

    function ok(cond, label) {
        if (cond) { pass++; console.log("  OK   " + label) }
        else      { bad++; console.log("  BAD  " + label) }
    }

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

    // 🔴 必须找**当前可见**的那个实例，不能拿第一个匹配。
    //    为什么：TitleBar.qml 被 10 个页面各实例化一次，而三个动作键声明在 TitleBar 里
    //    ⇒ 整棵树里有 10 个同名 gdPlayerDownloadBtn（9 个在隐藏页面里）。
    //    findByName 返回树里第一个 —— 实测是隐藏页面的，visible=false、x=0，
    //    于是探针报出「三键重叠在 x=0」这种**假 bug**（真实 UI 没问题）。
    //    这类"探针自己看错了对象"和本项目踩过的「夹具太宽松」是同一类病：
    //    测量工具必须先确认自己量的是不是目标对象。
    function findVisibleByName(obj, name) {
        if (!obj) return null
        for (var i = 0; i < obj.children.length; i++) {
            var c = obj.children[i]
            if (c.objectName === name && c.visible) return c
            var r = findVisibleByName(c, name)
            if (r) return r
        }
        return null
    }

    // 把对象在 root 坐标系下的矩形取出来（用"可见实例"版本）
    function rectOf(root, it, name) {
        var o = findVisibleByName(it, name)
        if (!o) return null
        var p = o.mapToItem(root, 0, 0)
        return { x: p.x, y: p.y, w: o.width, h: o.height,
                 r: p.x + o.width, b: p.y + o.height }
    }

    function overlap(a, b) {
        if (!a || !b) return 0
        var ox = Math.min(a.r, b.r) - Math.max(a.x, b.x)
        var oy = Math.min(a.b, b.b) - Math.max(a.y, b.y)
        return (ox > 0 && oy > 0) ? Math.min(ox, oy) : 0
    }

    Loader {
        id: ld
        source: "file:///tmp/gd-ui/main.qml"
        onStatusChanged: {
            if (status === Loader.Error) { console.log("UI LOAD-ERROR"); Qt.quit(); return }
            if (status !== Loader.Ready) return
            root.step = 1
            tick.start()
        }
    }

    Timer {
        id: tick
        interval: 120
        repeat: true
        running: false
        onTriggered: {
            var it = ld.item
            if (!it) return
            if (root.step === 1) {
                // 造点内容，让歌词/封面都进入"有内容"状态（否则量的是空态）
                it.page = "player"
                it.currentSong = { id: "1", source: "netease", name: "夜曲", artist: "周杰伦" }
                it.lyricLines = [{ time: 0, text: "一群嗜血的蚂蚁 被腐肉所吸引" },
                                 { time: 5, text: "我面无表情 看孤独的风景" }]
                it.lyricIndex = 0
                it.duration = 225
                it.timePos = 72
                root.step = 2
                return
            }
            if (root.step === 2) {
                console.log("=== 播放页几何（A1 第二轮：封面缩小 + 标题移到封面下）===")
                var left  = rectOf(root, it, "gdPlayerLeft")
                var cover = rectOf(root, it, "gdPlayerCover")
                var sname = rectOf(root, it, "gdPlayerSongName")
                var sart  = rectOf(root, it, "gdPlayerSongArtist")
                var mid   = rectOf(root, it, "gdPlayerMiddle")
                var ctrl  = rectOf(root, it, "gdPlayerControls")
                var prog  = rectOf(root, it, "gdPlayerProgress")
                var lyr   = rectOf(root, it, "gdPlayerLyricBox")
                var pbar  = rectOf(root, it, "gdPlayerProgBar")

                function show(n, r) {
                    if (!r) { console.log("  MISSING " + n); return }
                    console.log("  " + n + ": x=" + Math.round(r.x) + " y=" + Math.round(r.y)
                                + " w=" + Math.round(r.w) + " h=" + Math.round(r.h)
                                + " right=" + Math.round(r.r) + " bottom=" + Math.round(r.b))
                }
                show("leftCol ", left)
                show("cover   ", cover)
                show("songName", sname)
                show("artist  ", sart)
                show("middle  ", mid)
                show("lyricBox", lyr)
                show("progBar ", pbar)
                show("progress", prog)
                show("controls", ctrl)

                ok(!!cover && !!mid && !!ctrl && !!prog && !!sname,
                   "五个关键区域都存在（objectName 齐全）")

                // 1) 封面 56×56（本轮缩小）
                if (cover) {
                    console.log("  ★ 封面尺寸 = " + Math.round(cover.w) + "×" + Math.round(cover.h))
                    ok(Math.abs(cover.w - 56) < 0.5 && Math.abs(cover.h - 56) < 0.5,
                       "封面是 56×56（实测 " + Math.round(cover.w) + "×" + Math.round(cover.h) + "）")
                }

                // 2) 两行标题在封面**正下方**且与左列同宽（水平范围对齐左列，不是对齐封面）
                //    ⚠️ 2026-10-07 D+E 改动后左列(68)比封面(56)宽 ⇒ 标题对齐的是**左列**，
                //       封面在左列里居中。所以这里断言"标题与左列同宽"，不再是"与封面同宽"。
                if (sname && left && sart) {
                    ok(sname.y >= cover.b - 0.5,
                       "歌名在封面下方（歌名 y=" + Math.round(sname.y)
                       + " 封面 bottom=" + Math.round(cover.b) + "）")
                    ok(sart.y >= sname.b - 0.5,
                       "歌手在歌名下方（歌手 y=" + Math.round(sart.y)
                       + " 歌名 bottom=" + Math.round(sname.b) + "）")
                    ok(Math.abs(sname.x - left.x) < 0.5
                       && Math.abs((sname.x + sname.w) - (left.x + left.w)) < 0.5,
                       "标题与左列同宽（标题 " + Math.round(sname.x) + ".."
                       + Math.round(sname.x + sname.w) + " 左列 " + Math.round(left.x)
                       + ".." + Math.round(left.x + left.w) + "）")
                    // 封面在左列里水平居中
                    var coverMid = cover.x + cover.w / 2
                    var leftMid = left.x + left.w / 2
                    ok(Math.abs(coverMid - leftMid) < 0.5,
                       "封面在左列里居中（封面中线 " + coverMid.toFixed(1)
                       + " 左列中线 " + leftMid.toFixed(1) + "）")
                }

                // 3) 左列（封面+标题）与歌词列不重叠
                ok(overlap(left, mid) === 0,
                   "左列 与 歌词列 不重叠（重叠 " + overlap(left, mid).toFixed(1) + "px）")

                // 4) 歌词列与底部条不重叠（否则歌词被播控压住）
                ok(overlap(mid, prog) === 0,
                   "歌词列 与 底部条 不重叠（重叠 " + overlap(mid, prog).toFixed(1) + "px）")

                // 5) 底部条内部：进度条与播控不重叠
                ok(overlap(pbar, ctrl) === 0,
                   "进度条 与 播控 不重叠（重叠 " + overlap(pbar, ctrl).toFixed(1) + "px）")

                // 6) 全部在屏幕内
                var all = [left, cover, sname, sart, mid, ctrl, prog, lyr, pbar]
                var over = false
                for (var i = 0; i < all.length; i++) {
                    var r = all[i]
                    if (!r) continue
                    if (r.x < -0.5 || r.y < -0.5 || r.r > 320.5 || r.b > 170.5) {
                        over = true
                        console.log("  OUT OF SCREEN: " + JSON.stringify(r))
                    }
                }
                ok(!over, "所有区域都在 320×170 屏幕内")

                // 7) 歌词框高度（本轮的核心收益：标题让位后歌词变高）
                if (lyr) {
                    console.log("  ★ 歌词框 = " + Math.round(lyr.w) + "×" + Math.round(lyr.h)
                                + "（上轮 224×71）")
                    ok(lyr.h >= 95,
                       "歌词框高 ≥ 95（实测 " + Math.round(lyr.h) + "，标题让位后应接近 102）")
                    ok(lyr.w >= 190,
                       "歌词框宽 ≥ 190（实测 " + Math.round(lyr.w) + "）")
                }
                if (pbar) {
                    console.log("  ★ 进度条宽 = " + Math.round(pbar.w) + "px")
                    ok(pbar.w >= 150, "进度条宽 ≥ 150px（实测 " + Math.round(pbar.w) + "）")
                }

                // 8) 顶栏三个动作键存在、不重叠、在顶栏内
                var dl = rectOf(root, it, "gdPlayerDownloadBtn")
                var ad = rectOf(root, it, "gdPlayerAddBtn")
                var qb = rectOf(root, it, "gdPlayerQueueBtn")
                show("dlBtn   ", dl)
                show("addBtn  ", ad)
                show("queueBtn", qb)
                var rbtns = rectOf(root, it, "gdRightBtns")
                show("rightBtns", rbtns)
                ok(!!dl && !!ad && !!qb, "顶栏 下载/加歌单/队列 三键都存在")
                var barOver = false
                ;[dl, ad, qb].forEach(function (r) {
                    if (r && (r.x < -0.5 || r.r > 320.5 || r.y < -0.5 || r.b > 32.5)) barOver = true
                })
                ok(!barOver, "三个动作键都在顶栏内（y<32、x 在屏幕内）")
                ok(overlap(dl, ad) === 0 && overlap(ad, qb) === 0,
                   "顶栏三键互不重叠")
                var title = findVisibleByName(it, "gdPlayerTitleText")
                if (title) {
                    var tr = rectOf(root, it, "gdPlayerTitleText")
                    var rl = rectOf(root, it, "gdRightBtns")
                    ok(overlap(tr, rl) === 0,
                       "标题 与 右侧按钮组 不重叠（重叠 " + overlap(tr, rl).toFixed(1) + "px）")
                }

                console.log("")
                console.log("  RESULT pass=" + pass + " bad=" + bad)
                // 不在这里 Qt.quit —— 还有第三步：长歌名（2 行）不能溢出
                root.step = 3
                return
            }

            if (root.step === 3) {
                // ---- 长歌名（歌名会占满 2 行）：左列不能因此溢出内容区 ----
                // 为什么必须单独测：歌名是 `maximumLineCount: 2` 的 Text，
                //   它的 height 会随内容在 14↔28 之间变，而左列是 verticalCenter 锚定的
                //   ⇒ 长歌名会把左列整体撑高、上下各溢出 7px。
                //   源码里完全看不出这一点（要算高度预算才发现），所以用几何断言钉住。
                console.log("")
                console.log("=== 长歌名（2 行）溢出检查 ===")
                it.currentSong = { id: "9", source: "netease",
                                   name: "这是一个非常非常长的歌名用来测试两行换行是否会把左列撑溢出",
                                   artist: "很多歌手A,很多歌手B" }
                it.lyricLines = []
                root.step = 4
                return
            }

            if (root.step === 4) {
                var left2  = rectOf(root, it, "gdPlayerLeft")
                var cover2 = rectOf(root, it, "gdPlayerCover")
                var name2  = rectOf(root, it, "gdPlayerSongName")
                var art2   = rectOf(root, it, "gdPlayerSongArtist")
                var mid2   = rectOf(root, it, "gdPlayerMiddle")
                function show2(n, r) {
                    if (!r) { console.log("  MISSING " + n); return }
                    console.log("  " + n + ": y=" + Math.round(r.y) + " h=" + Math.round(r.h)
                                + " bottom=" + Math.round(r.b))
                }
                show2("cover2 ", cover2)
                show2("name2  ", name2)
                show2("artist2", art2)
                show2("leftCol2", left2)

                if (name2) {
                    console.log("  ★ 长歌名占 " + Math.round(name2.h) + "px（单行约 12 / 两行约 24）")
                    ok(name2.h > 12, "长歌名确实换成了 2 行（实测高 " + Math.round(name2.h) + "px）")
                }
                if (left2) {
                    // 内容区是 y=32..134。左列必须在其中（允许 0.5 容差）
                    ok(left2.y >= 31.5 && left2.b <= 134.5,
                       "长歌名时左列仍在内容区内（y=" + Math.round(left2.y)
                       + " bottom=" + Math.round(left2.b) + "，内容区 32..134）")
                    ok(left2.y >= -0.5 && left2.b <= 170.5,
                       "长歌名时左列不越出屏幕（bottom=" + Math.round(left2.b) + "）")
                }
                ok(overlap(left2, mid2) === 0,
                   "长歌名时 左列 与 歌词列 仍不重叠")
                if (art2) {
                    ok(art2.b <= 170.5, "歌手行不被挤到屏幕外（bottom=" + Math.round(art2.b) + "）")
                }

                // 9) 时间文字**贴着**进度条上沿（2026-10-07 用户反馈"时间有点靠上"）
                //    判据：时间的 bottom 与进度条的 top 之间只留 1~3px。
                //    旧写法把时间锚到这一条的最顶端，与进度条之间空出一大块 ⇒ "飘着"。
                var posT = rectOf(root, it, "gdPlayerPosText")
                var durT = rectOf(root, it, "gdPlayerDurText")
                if (posT && pbar) {
                    var gap1 = pbar.y - (posT.y + posT.h)
                    console.log("  ★ 时间与进度条的间距 = " + gap1.toFixed(1) + "px（旧版约 13px）")
                    ok(gap1 >= 0 && gap1 <= 3,
                       "时间贴着进度条上沿（间距 " + gap1.toFixed(1) + "px，期望 0~3）")
                }
                if (durT && pbar) {
                    var gap2 = pbar.y - (durT.y + durT.h)
                    ok(gap2 >= 0 && gap2 <= 3,
                       "右侧时间也贴着进度条（间距 " + gap2.toFixed(1) + "px）")
                }
                if (posT && durT) {
                    // 两个时间在同一行（否则看着歪）
                    ok(Math.abs(posT.y - durT.y) < 1.5,
                       "左右两个时间在同一水平线（y=" + Math.round(posT.y)
                       + " vs " + Math.round(durT.y) + "）")
                }

                // 10) 信息浮层默认关闭，且铺满整屏（否则顶栏/播控会露在浮层外，点它们会误触）
                // 🔴 `it` 是 **main.qml 的根**（controller），而 showInfo 在 **PlayerPage** 上。
                //    直接写 it.showInfo 会报 "Cannot assign to non-existent property"——
                //    第一版就是这么错的。必须顺着页面树找到 PlayerPage 实例。
                var pp = findPage(root, it)
                ok(pp !== null, "找到 PlayerPage 实例")
                if (!pp) { tick.stop(); Qt.quit(); return }
                ok(pp.showInfo === false, "信息浮层默认关闭")
                pp.showInfo = true
                root.pageObj = pp
                root.step = 5
                return
            }

            if (root.step === 5) {
                console.log("")
                console.log("=== 信息浮层几何 ===")
                var it2 = ld.item
                var ov  = rectOf(root, it2, "gdPlayerInfoOverlay")
                var bc  = rectOf(root, it2, "gdPlayerBigCover")
                var ic  = rectOf(root, it2, "gdPlayerInfoCol")
                var ca  = rectOf(root, it2, "gdPlayerInfoClose")
                function show5(n, r) {
                    if (!r) { console.log("  MISSING " + n); return }
                    console.log("  " + n + ": x=" + Math.round(r.x) + " y=" + Math.round(r.y)
                                + " w=" + Math.round(r.w) + " h=" + Math.round(r.h))
                }
                show5("overlay ", ov)
                show5("bigCover", bc)
                show5("infoCol ", ic)
                show5("close   ", ca)

                ok(!!ov && !!bc && !!ic && !!ca, "浮层四个关键节点都存在")
                if (ov) {
                    ok(Math.abs(ov.x) < 0.5 && Math.abs(ov.y) < 0.5
                       && Math.abs(ov.w - 320) < 0.5 && Math.abs(ov.h - 170) < 0.5,
                       "浮层铺满整屏 320×170（实测 " + Math.round(ov.w) + "×" + Math.round(ov.h) + "）")
                }
                // 封面在左、信息在右
                if (bc && ic) {
                    ok(bc.x + bc.w <= ic.x + 0.5,
                       "大封面在左、信息在右（封面 right=" + Math.round(bc.x + bc.w)
                       + " 信息 left=" + Math.round(ic.x) + "）")
                    ok(overlap(bc, ic) === 0,
                       "大封面与信息列不重叠（重叠 " + overlap(bc, ic).toFixed(1) + "px）")
                    ok(ic.x + ic.w <= 320.5, "信息列不越出右边界（right="
                       + Math.round(ic.x + ic.w) + "）")
                }
                // 关闭热区必须覆盖整屏，且在**最上层**（能盖住封面/信息）
                if (ca) {
                    ok(Math.abs(ca.w - 320) < 0.5 && Math.abs(ca.h - 170) < 0.5,
                       "关闭热区铺满整屏（实测 " + Math.round(ca.w) + "×" + Math.round(ca.h) + "）")
                }
                // 信息数据行非空（真的取了 controller 的数据）
                // ⚠️ infoRows 是 PlayerPage 上的函数 ⇒ 必须用 root.pageObj 调，不能用 it
                var rows = root.pageObj ? root.pageObj.infoRows() : []
                console.log("  ★ infoRows 返回 " + rows.length + " 行: "
                            + rows.map(function (r) { return r.k }).join("/"))
                ok(rows.length >= 3, "infoRows 至少返回 3 行（实测 " + rows.length + "）")

                // 关闭后浮层真的隐藏（用户要求"点一下任意地方回到正常播放页"）
                root.pageObj.showInfo = false
                root.step = 6
                return
            }

            if (root.step === 6) {
                var it3 = ld.item
                var ov2 = rectOf(root, it3, "gdPlayerInfoOverlay")
                // 隐藏后 rectOf（只找 visible 的）应返回 null —— 这正是"看不见了"的证据
                ok(ov2 === null,
                   "关闭后浮层不可见（rectOf 只找可见实例，返回 " + (ov2 ? "仍可见" : "null") + "）")

                console.log("")
                console.log("  RESULT-OVERLAY pass=" + pass + " bad=" + bad)
                tick.stop()
                Qt.quit()
                return
            }
        }
    }

    Component.onCompleted: tick.start()
}
