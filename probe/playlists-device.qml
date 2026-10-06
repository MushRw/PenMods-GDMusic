import QtQuick 2.12
import QtQuick.LocalStorage 2.0

// 在**真机**上验证「歌单数据层」。
//
// 与 probe/playlists.sh（node 求值源码）互补：这里加载**真实 main.qml**、跑在真 QML 引擎上，
// 专门验证主机上根本测不了的三件事：
//   ① 真属性系统的**变更通知**：写操作后 playlists 换没换成新数组。
//      这是 P2 歌单页能否刷新的前提 —— 原地改后赋同一引用时 QML 不发信号，
//      症状是「数据对了、日志干净、界面就是不刷新」，主机上完全测不出来。
//   ② LocalStorage 真落盘 / 真读回（主机上没有 SQLite 这一层）
//   ③ 真引擎里播歌单：队列确实是拷贝出来的
//
// 注意：qmlscene 下没有宿主注入的 shell ⇒ startAt 内部会走降级分支，这是**探针环境**
// 而非代码问题，所以那一步只记录、不判失败。
//
// 用法（设备上）：
//   adb push probe/playlists-device.qml /tmp/
//   adb shell "cd /userdisk/PenMods/plugins/gdmusic/qml && HOME=/tmp \
//              QT_QPA_PLATFORM=offscreen timeout 60 /usr/bin/qmlscene /tmp/playlists-device.qml"
Item {
    id: root
    width: 320
    height: 170

    property int pass: 0
    property int bad: 0

    function ok(cond, label) {
        if (cond) { pass++; console.log("  OK   " + label) }
        else      { bad++; console.log("  BAD  " + label) }
    }
    function sect(name, fn) {
        console.log("--- " + name)
        try { fn() } catch (e) { bad++; console.log("  BAD  抛异常：" + e) }
    }

    // ⭐ 用**属性绑定**盯 main.qml 的 playlists —— 这正是 P2 歌单页会用到的机制
    //（列表页绑的是 playlists，不是信号处理器），所以绑定会不会重算才是真问题。
    property int plLen: {
        var it = ld.item
        if (!it || !it.playlists) return -1
        return it.playlists.length
    }
    property string plName: {
        var it = ld.item
        if (!it || !it.playlists || !it.playlists.length) return ""
        return String(it.playlists[0].name)
    }
    property int plSongCount: {
        var it = ld.item
        if (!it || !it.playlists || !it.playlists.length) return -1
        var s = it.playlists[0].songs
        return s ? s.length : -1
    }

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onLoaded: {
            var it = ld.item
            if (!it) { console.log("CHECK FAIL 加载 main.qml 得到空对象"); Qt.quit(1); return }

            var D = "/userdisk/Music/GDMusic"
            var ONLINE  = { id: "1997293311", source: "netease", name: "断气",
                            artist: "回春丹", pic_id: "109951173449168898",
                            lyric_id: "1997293311" }
            var ONLINE2 = { id: "3439426789", source: "netease", name: "铁花飞", artist: "回春丹" }
            var LOCALA  = { file: D + "/断气-回春丹.mp3", size: 11735293,
                            name: "断气", artist: "回春丹" }

            // ---- 探针库的读写与还原 ----
            // 这是 qmlscene 的库（QtProject/QtQmlViewer），不是宿主那份；但脏数据还是别留下。
            function kvRead(key) {
                var d = LocalStorage.openDatabaseSync("gdmusic", "1.0", "GD Music", 100000)
                var v = null, has = false
                d.transaction(function(tx) {
                    tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                    var rs = tx.executeSql("SELECT value FROM kv WHERE key=?", [key])
                    if (rs.rows.length) { v = rs.rows.item(0).value; has = true }
                })
                return { v: v, has: has }
            }
            function kvWrite(key, val) {
                var d = LocalStorage.openDatabaseSync("gdmusic", "1.0", "GD Music", 100000)
                d.transaction(function(tx) {
                    tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                    if (val === null) tx.executeSql("DELETE FROM kv WHERE key=?", [key])
                    else tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", [key, String(val)])
                })
            }

            var oldPl = null, oldPlHas = false
            sect("0. LocalStorage 是否可用 / 记原值", function() {
                var r = kvRead("playlists")
                oldPl = r.v; oldPlHas = r.has
                ok(true, "能打开 gdmusic 库并读到 kv 表（原 playlists hasRow=" + oldPlHas + "）")
            })

            sect("1. 真引擎：基本操作与属性可读性", function() {
                it.playlists = []
                var r = it.createPlaylist("我的歌", "online")
                ok(r.ok && String(r.id).indexOf("pl_") === 0, "createPlaylist 返回 pl_ 开头的 id")
                ok(it.playlists.length === 1, "playlists 属性读回长度为 1（var 属性仍是真数组）")
                ok(it.playlists[0].name === "我的歌" && it.playlists[0].type === "online",
                   "歌单对象读回名字/类型正确")
                var a = it.addSongToPlaylist(r.id, ONLINE)
                ok(a.ok, "在线歌单加在线曲 → ok")
                ok(it.playlists[0].songs.length === 1, "songs 数组读回长度为 1")
                ok(it.addSongToPlaylist(r.id, LOCALA).err === "E_TYPE",
                   "在线歌单收本地曲 → E_TYPE")
                ok(it.addSongToPlaylist(r.id, ONLINE).err === "E_DUP", "重复加 → E_DUP")
                var rl = it.createPlaylist("离线", "local")
                ok(it.addSongToPlaylist(rl.id, LOCALA).ok, "离线歌单加本地曲 → ok")
                ok(it.addSongToPlaylist(rl.id, ONLINE2).err === "E_TYPE",
                   "离线歌单收在线曲 → E_TYPE")
                ok(it.renamePlaylist(rl.id, " ").err === "E_NAME", "改成空白名 → E_NAME")
                ok(it.deletePlaylist(rl.id).ok && it.playlists.length === 1, "删掉后只剩 1 个")
            })

            sect("2. ⭐ 变更通知：属性绑定会不会重算（P2 列表页刷新的前提）", function() {
                it.playlists = []
                ok(root.plLen === 0, "基线：绑定读到 0 个歌单（实际 " + root.plLen + "）")

                var r = it.createPlaylist("W", "online")
                ok(root.plLen === 1, "create → 绑定重算为 1（实际 " + root.plLen + "）")

                r = it.createPlaylist("W1", "online")
                it.addSongToPlaylist(it.playlists[0].id, ONLINE)
                ok(root.plName === "W" && root.plSongCount === 1,
                   "add → 绑定读到首单「" + root.plName + "」的 " + root.plSongCount + " 首")

                it.removeSongFromPlaylist(it.playlists[0].id, "netease:1997293311")
                ok(root.plSongCount === 0, "remove → 绑定读到 0 首（实际 " + root.plSongCount + "）")

                it.renamePlaylist(it.playlists[0].id, "W2")
                ok(root.plName === "W2", "rename → 绑定读到新名字（实际 " + root.plName + "）")

                it.deletePlaylist(it.playlists[0].id)
                ok(root.plLen === 1, "delete → 绑定读到 1（实际 " + root.plLen + "）")

                // ---- 对照实验：原地改后赋【同一引用】会怎样？ ----
                // 这一段**不判成败**，只记录现象 —— 它决定 clonePlaylists 是必需还是多余。
                it.playlists = []
                var same = it.playlists
                same.push({ id: "pl_probe", name: "同一引用", type: "online", created: 0, songs: [] })
                it.playlists = same
                console.log("  参考  赋【同一引用】后，绑定读到 " + root.plLen + " 个 ⇒ "
                            + (root.plLen === 1
                               ? "QML 仍会重算，clonePlaylists 非必需（但无害，保留作防御）"
                               : "QML 不重算 ⇒ clonePlaylists 是**必需**的，否则 P2 歌单页不刷新"))
                it.playlists = []
            })

            sect("3. LocalStorage 真落盘 / 真读回", function() {
                it.playlists = []
                var r1 = it.createPlaylist("落盘A", "online")
                it.addSongToPlaylist(r1.id, ONLINE)
                var r2 = it.createPlaylist("落盘B", "local")
                it.addSongToPlaylist(r2.id, LOCALA)
                it.playlists = []                 // 清掉内存里的，只留库里的
                it.loadSettings()                 // 从库读回
                ok(it.playlists.length === 2, "2 个歌单都读回来了（实际 " + it.playlists.length + "）")
                var pa = it.playlistById(r1.id), pb = it.playlistById(r2.id)
                ok(pa !== null, "在线歌单按 id 能查到（id 没在往返中丢失）")
                ok(pb !== null, "离线歌单按 id 能查到")
                ok(pa && pa.name === "落盘A" && pa.type === "online", "在线歌单名字/类型读回正确")
                ok(pa && pa.songs.length === 1 && pa.songs[0].id === "1997293311",
                   "在线曲目读回正确（id=" + (pa && pa.songs[0] ? pa.songs[0].id : "?") + "）")
                ok(pa && pa.songs[0].pic_id === "109951173449168898", "pic_id 没丢（封面不断链）")
                ok(pb && pb.songs[0].file === LOCALA.file, "本地曲目 file 读回正确")
                ok(pb && pb.songs[0].size === 11735293, "本地曲目 size 读回正确")
                // 读回来之后仍要能用：播歌单 → 命中本地
                it.localList = [LOCALA]
                it.playlists = []                  // 先清，再从库读，确保下面用的是"库里的"
                it.loadSettings()
                it.playPlaylist(r1.id, 0)
                ok(it.queue.length >= 1 && it.resolveEntry(it.queue[0]).file === LOCALA.file,
                   "读回的在线歌单：播放时仍能命中本地文件 ⇒ 播的是文件")
            })

            sect("4. 坏值容错：不能连坐整个 loadSettings", function() {
                kvWrite("playlists", "{ 这根本不是 JSON")
                it.playlists = [{ id: "__sentinel", type: "online", name: "哨兵", songs: [] }]
                it.loadSettings()
                ok(it.playlists.length === 0, "坏 JSON → 歌单被换成空（哨兵没了，说明真赋值过）")
                ok(typeof it.source === "string" && it.source.length > 0,
                   "其它设置没被连坐（source=" + it.source + "）")
                // 坏值之后还能继续用
                kvWrite("playlists", "[]")
                var r = it.createPlaylist("坏值后", "online")
                it.playlists = []
                it.loadSettings()
                ok(it.playlists.length === 1 && it.playlists[0].id === r.id,
                   "坏值之后写入/读回仍正常（表没被搞坏）")
            })

            sect("5. 播歌单：队列是【拷贝】，且页面翻到 player", function() {
                kvWrite("playlists", "[]")
                it.loadSettings()
                var r = it.createPlaylist("播", "online")
                it.addSongToPlaylist(r.id, ONLINE)
                it.addSongToPlaylist(r.id, ONLINE2)
                var before = it.playlists.length
                var res = it.playPlaylist(r.id, 1)
                ok(res.ok, "playPlaylist → ok")
                ok(it.page === "player", "page 翻到 player")
                ok(it.queue.length === 2, "整单进了队列（2 首）")
                it.addSongToPlaylist(r.id, { id: "9", source: "netease", name: "后来加的" })
                ok(it.playlists.length === before, "歌单本身加了 1 首")
                ok(it.queue.length === 2, "队列长度不变 ⇒ 不是同一个数组（拷贝生效）")
                ok(it.queue[0] !== it.playlists[0].songs[0], "队列条目确实是新对象")
                var empty = it.createPlaylist("空", "online")
                ok(it.playPlaylist(empty.id, 0).err === "E_EMPTY", "空歌单 → E_EMPTY")
            })

            sect("6. 还原探针库", function() {
                kvWrite("playlists", oldPlHas ? oldPl : null)
                ok(true, "已还原（hasRow=" + oldPlHas + "）")
            })

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
