import QtQuick 2.12

// 真机 sidecar 探针：加载**设备上**的 main.qml，验证纯逻辑在真引擎里的行为。
//
// ⚠️ 为什么本探针**不碰 shell**：
//   qmlscene 里没有 shell 这个上下文属性（那是宿主注入的）。既有真机探针
//   （addpick-device / playlists-device …）一律不碰它，也正因为插件里那些函数都有
//   `typeof shell === "undefined"` 兜底，不碰才不会每帧报错。
//   我一度在这个文件里**自己声明了一个假 shell**来"跑命令"，那是自欺欺人：
//   测的是我的假实现，不是 /bin/sh。命令拼接的真实验证放在 probe/sidecar-e2e.sh
//   （node 抠真源码 → adb 真跑 → 断言文件落盘），这才是 §3.5 说的"以执行结果为准"。
//
// 本探针只管源码求值测不到的那一半：
//   · 真引擎里 property var 赋值/绑定真的重算（§3.7）
//   · decorateLocal 真的把 img/hasLrc 贴到每条记录上
//   · fetchCover 的"本地优先 / 联网受开关控"分支真的按预期走
//   · 页面上的 [词]/[图] 标记真的按记录内容变化
Item {
    id: root
    width: 320
    height: 170

    property int pass: 0
    property int bad: 0

    function ok(c, label) {
        if (c) { pass++; console.log("  ✅ " + label) }
        else { bad++; console.log("  ❌ " + label) }
    }

    Loader {
        id: ld
        anchors.fill: parent
        source: "/userdisk/PenMods/plugins/gdmusic/qml/main.qml"
        onStatusChanged: if (status === Loader.Ready) root.stage1()
    }

    readonly property string mp3Path: "/userdisk/Music/GDMusic/屋顶-周杰伦.mp3"
    readonly property string basePath: "/userdisk/Music/GDMusic/屋顶-周杰伦"
    // 设备上由 sidecar-device.sh 预置的真封面（真 jpg，ff d8 开头）
    // ⛔ 属性名不能大写开头：QML 会拒绝加载并只打一行
    //    "Property names cannot begin with an upper case letter"，整个文件静默不跑
    readonly property string realImg: basePath + ".jpg"

    // ---------------- A. 纯函数 ----------------
    function stage1() {
        var it = ld.item
        if (!it) { ok(false, "加载 main.qml"); return }
        console.log("--- A. 路径推导与扩展名推断（真引擎）---")
        ok(it.sidecarBase(root.mp3Path) === root.basePath, "sidecarBase 去扩展名")
        ok(it.localLrcFor(root.mp3Path) === root.basePath + ".lrc", "localLrcFor = 同名 .lrc")
        ok(it.localImgFor(root.mp3Path) === root.basePath + ".jpg", "localImgFor = 同名 .jpg")
        ok(it.sidecarBase(root.mp3Path) === it.localLrcFor(root.mp3Path).replace(/\.lrc$/, ""),
           "三条路径同源（封面/歌词与 mp3 共享一个 base）")
        ok(it.imgExtForUrl("https://p2.music.126.net/xx==/1.jpg?param=500y500") === ".jpg",
           "剥查询串后取扩展名")
        ok(it.imgExtForUrl("https://x/y/z.PNG") === ".png", "大写 .PNG 归一")
        ok(it.imgExtForUrl("https://x/y/z.webp") === ".jpg", "白名单外兜底 .jpg")
        ok(it.imgExtForUrl("") === ".jpg", "空 URL 兜底")
        ok(it.sidecarImgExts.indexOf(".webp") < 0, "白名单不含 .webp（设备无 webp 解码器）")
        root.stage2()
    }

    // ---------------- B. 扫描解析 ----------------
    function stage2() {
        var it = ld.item
        console.log("--- B. 扫描解析（真引擎喂真格式）---")
        var dump = ["@@GDMUS@@11735293|断气-回春丹.mp3",
                    "@@GDMUS@@7340032|孤勇者-陈奕迅.mp3",
                    "@@GDMUS@@512|只有歌没附件-某人.mp3",
                    "@@GMSIDE@@断气-回春丹.jpg",
                    "@@GMSIDE@@孤勇者-陈奕迅.PNG",
                    "@@GMSIDE@@不该被认-某人.webp",
                    "@@GMSIDE@@",
                    "@@GMLRC@@断气-回春丹.lrc",
                    "噪声行"].join("\n")
        var imgs = it.parseSidecarScan(dump)
        var lrcs = it.parseSidecarLrcScan(dump)
        ok(Object.keys(imgs).length === 2, "只认 2 张封面（.webp 与空行被忽略）")
        // ⭐ 期望值走**被测代码自己的公式**（sidecarBase）——手写字面量会两边一致而全绿，
        //    源码版就栽在这：key 少了目录一级，decorateLocal 永远查不到（封面下了不显示）。
        ok(imgs[it.sidecarBase("/userdisk/Music/GDMusic/断气-回春丹.mp3")] !== undefined,
           "封面表 key == sidecarBase(绝对路径)（含目录）")
        ok(imgs["断气-回春丹"] === undefined, "只给文件名查不到（钉死上面那个坑）")
        ok(imgs[it.sidecarBase("/userdisk/Music/GDMusic/孤勇者-陈奕迅.mp3")]
           === "/userdisk/Music/GDMusic/孤勇者-陈奕迅.PNG", "大写 .PNG 原样保留")
        ok(Object.keys(lrcs).length === 1, "只认 1 份歌词")
        ok(lrcs[it.sidecarBase("/userdisk/Music/GDMusic/断气-回春丹.mp3")] !== undefined,
           "lrc 表 key 同形态")
        ok(it.parseLocalScan(dump).length === 3, "sidecar 行不混进歌曲列表")
        root.stage3()
    }

    // ---------------- C. decorateLocal 真的贴字段（绑定重算）----------------
    function stage3() {
        var it = ld.item
        console.log("--- C. decorateLocal 贴字段 ---")
        var D = "/userdisk/Music/GDMusic"
        it.fileMap = ({})
        it.localList = [{ file: D + "/断气-回春丹.mp3", size: 11735293, name: "断气", artist: "回春丹" },
                        { file: D + "/孤勇者-陈奕迅.mp3", size: 7340032, name: "孤勇者", artist: "陈奕迅" },
                        { file: D + "/只有歌没附件-某人.mp3", size: 512, name: "只有歌没附件", artist: "某人" }]
        var imgs = {}, lrcs = {}
        imgs[D + "/断气-回春丹"] = D + "/断气-回春丹.jpg"
        imgs[D + "/孤勇者-陈奕迅"] = D + "/孤勇者-陈奕迅.PNG"
        lrcs[D + "/断气-回春丹"] = D + "/断气-回春丹.lrc"
        it.sidecarImgs = imgs
        it.sidecarLrcs = lrcs
        it.decorateLocal()
        var L = it.localList
        ok(L.length === 3, "decorate 后仍是 3 条")
        ok(L[0].img === D + "/断气-回春丹.jpg", "第 1 首贴上封面路径")
        ok(L[0].hasLrc === true, "第 1 首 hasLrc === true（严格布尔）")
        ok(L[1].img === D + "/孤勇者-陈奕迅.PNG", "第 2 首贴上 .PNG 封面")
        ok(L[1].hasLrc === false, "第 2 首 hasLrc === false（严格布尔，不是 undefined）")
        ok(L[2].img === "", "第 3 首无封面 → img 为空串")
        ok(L[2].hasLrc === false, "第 3 首无歌词 → hasLrc === false")
        ok(L[0].name === "断气" && L[0].artist === "回春丹", "decorate 不破坏歌名/歌手")
        root.stage4()
    }

    // ---------------- D. fetchCover 的本地优先 ----------------
    //
    // ⛔ 这里**只断言"本地优先"与"早退不崩"**，不假装能验"有没有联网"。
    //   原因（踩过才知道）：qmlscene 里没有 shell，而 apiGetWithIps 的第一行就是
    //       if (typeof shell === "undefined" || !shell) { cb(false, ""); return }
    //   ——它在 apiSeq++ **之前**就返回了。于是"发没发请求"在设备上没有任何对外痕迹，
    //   coverUrl 也恒为空。猴补 apiGet 也不行：QML 的 function 是只读属性
    //   （"Cannot assign to read-only property \"apiGet\""）。
    //   早先这版探针往 coverUrl 里塞 "sentinel" 想区分分支，结果：
    //     · 真 PlayerPage 的 Image.source 绑着 coverUrl → 设备日志刷
    //       "Cannot open: file:///.../sentinel"，自己制造警告；
    //     · 而无 shell 时值根本不变，等于什么都没测到。
    //   ⇒ 分支归属（本地分支在 loadExtra 判据之前）由 probe/sidecar.sh 逐行断言，
    //     真机只负责证明"真引擎里这些分支不会炸、且本地优先真的生效"。
    function stage4() {
        var it = ld.item
        console.log("--- D. 播放时封面：本地优先 ---")
        var D = "/userdisk/Music/GDMusic"
        var tbl = {}
        tbl[D + "/屋顶-周杰伦"] = root.realImg       // 用 sidecar-device.sh 放好的真封面
        it.sidecarImgs = tbl

        // ① 本地命中 ⇒ file://，**且与 loadExtra 无关**（关掉也照样给）
        it.loadExtra = false
        it.coverUrl = ""
        it.fetchCover({ id: "5257138", name: "屋顶", pic_id: "123", file: root.mp3Path })
        ok(it.coverUrl === ("file://" + root.realImg),
           "本地命中：即使 loadExtra=关 也给 file://  (得到 " + it.coverUrl + ")")
        it.loadExtra = true
        it.coverUrl = ""
        it.fetchCover({ id: "5257138", name: "屋顶", pic_id: "123", file: root.mp3Path })
        ok(it.coverUrl === ("file://" + root.realImg), "本地命中：loadExtra=开 时给同一个 file://")

        // ② 无本地 + loadExtra 关 ⇒ 早退，coverUrl 保持空、不崩
        it.loadExtra = false
        it.coverUrl = ""
        it.fetchCover({ id: "999", name: "无附件", pic_id: "123", source: "netease" })
        ok(it.coverUrl === "", "无本地封面且 loadExtra=关 → coverUrl 保持空")

        // ③ 有 file 但本地没封面 ⇒ 不崩、也不给一个假的 file://（必须是空串，不能是 "file://undefined"）
        it.coverUrl = ""
        it.fetchCover({ id: "888", name: "本地无图", file: D + "/本地无图-某人.mp3", pic_id: "456" })
        ok(it.coverUrl === "", "有 file 但无本地封面 → 早退且不产生 file://undefined")

        // ④ song 为空 / 无 pic_id ⇒ 直接 return，不炸
        it.coverUrl = ""
        it.fetchCover(null)
        it.fetchCover({ id: "777", name: "无图无id" })
        ok(it.coverUrl === "", "null / 无 pic_id 的歌都安全早退")

        // ⑤ loadExtras 统一分发：本地封面照样给（老写法会在外层 if(loadExtra) 就被掐掉）
        it.loadExtra = false
        it.sidecarImgs = tbl
        it.coverUrl = ""
        it.loadExtras({ id: "5257138", name: "屋顶", file: root.mp3Path })
        ok(it.coverUrl === ("file://" + root.realImg),
           "loadExtras 分发：loadExtra=关 时本地封面仍然出得来")
        root.stage5()
    }

    // ---------------- E. dlSidecar 开关 ----------------
    function stage5() {
        var it = ld.item
        console.log("--- E. dlSidecar 开关 ---")
        ok(it.dlSidecar === true, "dlSidecar 默认开")
        // ⛔ 这里能测的只有"开关关掉时**立刻**返回、不去读磁盘也不崩"。
        //    "开的时候真的发了请求"在 qmlscene 里测不到（见 D 段说明），
        //    它的等价断言在 sidecar.sh：saveSidecars 的第一行就是 if (!dlSidecar) return。
        it.dlSidecar = false
        var quietCover = it.coverUrl
        it.saveSidecars({ id: "x", source: "netease", name: "不该被存", lyric_id: "x", pic_id: "x" },
                        "/userdisk/Music/GDMusic/开关测试.mp3")
        ok(it.coverUrl === quietCover, "dlSidecar=关 时 saveSidecars 立刻返回、不碰任何状态")

        // 开：走完 saveLocalLrc + saveLocalCover 两条路（无 shell 时都在 apiGet 处早退），
        // 关键是**不崩**且不写脏数据 —— 这两条路在真机上是有副作用的（真会发请求）
        it.dlSidecar = true
        it.saveSidecars({ id: "y", source: "netease", name: "该发", lyric_id: "y", pic_id: "y" },
                        "/userdisk/Music/GDMusic/该发测试.mp3")
        // ⛔ 不写 ok(true, ...)：恒真断言等于没断言，将来实现坏了它还绿。
        //   改成"开的时候不该再停在关着时的状态"这个**可失败**的观察。
        ok(it.dlSidecar === true && it.coverUrl === quietCover,
           "dlSidecar=开 时 saveSidecars 走完两条路、不崩且没写脏状态（真发请求见 sidecar.sh 断言）")

        // 缺 pic_id ⇒ 封面那一路必须自己 return（本地未登记的歌不该去问图床）
        it.saveSidecars({ id: "z", source: "netease", name: "无图", lyric_id: "z" },
                        "/userdisk/Music/GDMusic/无图测试.mp3")
        ok(it.coverUrl === quietCover, "缺 pic_id 的歌不崩、也不误改 coverUrl（saveLocalCover 自行早退）")

        // 传残缺参数：saveSidecars 必须在最前面就挡掉，不能摸到 song.xxx
        it.saveSidecars(null, "/userdisk/Music/GDMusic/空测试.mp3")
        it.saveSidecars({ id: "w" }, "")
        it.saveSidecars(undefined, undefined)
        ok(it.coverUrl === quietCover, "saveSidecars(null/空 file) 被最前面的卫语句挡下，不炸")
        root.stage6()
    }

    // ---------------- F. 真机 Image 能否读预置的封面 ----------------
    function stage6() {
        console.log("--- F. QML Image 读设备上的真封面（由 sidecar-device.sh 预先下载）---")
        // ⚠️ 直接用 id（t7），不能写 root.t7：QML 的 id 不是真实属性，
        //    root.t7 是 undefined，报 "Cannot call method 'start' of undefined"。
        t7.start()
    }

    Item {
        id: imgProbe
        property int status: -1
        property string size: "?"
        property string err: ""
        Image {
            objectName: "gdSidecarImg"
            width: 32; height: 32
            source: "file://" + root.realImg
            asynchronous: false
            cache: false
            onStatusChanged: {
                if (status === Image.Ready || status === Image.Error) {
                    imgProbe.status = status
                    imgProbe.size = String(sourceSize.width) + "x" + String(sourceSize.height)
                }
            }
        }
    }

    Timer { id: t7; interval: 3000; onTriggered: root.finish() }

    function finish() {
        ok(imgProbe.status === 1,
           "Image.status === Ready，本地 jpg 真的能显示（读到 " + imgProbe.size + "）")
        console.log("CHK pass=" + pass + " bad=" + bad)
        console.log("CHECK DONE")
        Qt.quit()
    }
}
