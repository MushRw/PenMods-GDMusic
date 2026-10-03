import QtQuick 2.12
import QtQuick.LocalStorage 2.0

// 在**真机**上验证「文件登记表」(fileMap)。
//
// 与 probe/filemap.sh（node 求值源码）互补：这里加载的是**真实 main.qml**、跑在真 QML
// 引擎上，专门验证主机上根本测不了的两件事：
//   ① 真属性系统（fileMap 这种 var 属性读回来还是不是个能按 key 索引的对象）
//   ② LocalStorage 真落盘 / 真读回 / 坏值容错（主机上没有 SQLite 那一层）
// 注意：qmlscene 下没有宿主注入的 shell，refreshLocal 会提前返回 —— 所以这里**手工**
// 设置 localList 来扮演"扫出来的磁盘状态"，扫文件夹那条链路由 probe/scancmd-e2e.sh 守。
//
// 用法（设备上）：
//   adb push probe/filemap-device.qml /tmp/
//   adb shell "cd /userdisk/PenMods/plugins/gdmusic/qml && HOME=/tmp \
//              QT_QPA_PLATFORM=offscreen timeout 60 /usr/bin/qmlscene /tmp/filemap-device.qml"
Item {
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

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onLoaded: {
            var it = ld.item
            if (!it) { console.log("CHECK FAIL 加载 main.qml 得到空对象"); Qt.quit(); return }

            var D = "/userdisk/Music/GDMusic"
            var RENAMED = D + "/断气 - 回春丹 (Live).mp3"
            var OTHER   = D + "/别的歌-别人.mp3"
            var online = { id: "1997293311", source: "netease", name: "断气",
                           artist: "回春丹", pic_id: "109951173449168898",
                           lyric_id: "1997293311" }

            // 记录库里原来的值，跑完还原 —— 这个探针库是 qmlscene 的（不是宿主那份），
            // 但脏数据还是别留下，免得下次跑出"看起来像 bug"的结果。
            var dbOld = null, dbHasRow = false
            function kvRead() {
                var d = LocalStorage.openDatabaseSync("gdmusic", "1.0", "GD Music", 100000)
                var v = null, has = false
                d.transaction(function(tx) {
                    tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                    var rs = tx.executeSql("SELECT value FROM kv WHERE key='filemap'")
                    if (rs.rows.length) { v = rs.rows.item(0).value; has = true }
                })
                dbHasRow = has
                return v
            }
            function kvWrite(val) {
                var d = LocalStorage.openDatabaseSync("gdmusic", "1.0", "GD Music", 100000)
                d.transaction(function(tx) {
                    tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                    if (val === null)
                        tx.executeSql("DELETE FROM kv WHERE key='filemap'")
                    else
                        tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", ["filemap", String(val)])
                })
            }

            sect("0. LocalStorage 是否可用", function() {
                try { kvRead(); ok(true, "能打开 gdmusic 库并读到 kv 表") }
                catch (e) { ok(false, "LocalStorage 不可用：" + e) }
                try { dbOld = kvRead(); ok(true, "已记下原值（hasRow=" + dbHasRow + "）") }
                catch (e) { ok(false, "读原值失败：" + e) }
            })

            sect("1. 真引擎上的两级查找", function() {
                it.fileMap = ({})
                it.localList = [{ file: RENAMED, size: 11735293,
                                 name: "断气 - 回春丹 (Live)", artist: "" }]
                ok(it.findLocal(online) === null, "未登记 → 改过名的不命中（这是原状）")
                it.mapPut(RENAMED, online, "manual")
                ok(it.fileMap[RENAMED] !== undefined && it.fileMap[RENAMED] !== null,
                   "mapPut 之后能按路径索引到（var 属性读回仍是对象）")
                var hit = it.findLocal(online)
                ok(hit !== null && hit !== undefined && hit.file === RENAMED,
                   "登记后 → 命中改过名的文件")
                it.fileMap = ({})
            })

            sect("2. LocalStorage 真落盘 / 真读回", function() {
                it.fileMap = ({})
                it.mapPut(RENAMED, online, "manual")
                it.fileMap = ({})                  // 清掉内存里的，只留库里的
                it.loadSettings()                  // 从库读回
                var e = it.fileMap[RENAMED]
                ok(e !== undefined && e !== null, "loadSettings 把登记表读回来了")
                ok(e && e.id === "1997293311", "id 读回正确：" + (e ? e.id : "(无)"))
                ok(e && e.source === "netease", "source 读回正确")
                ok(e && e.name === "断气" && e.artist === "回春丹", "歌名/歌手读回正确")
                ok(e && e.pic_id === "109951173449168898", "pic_id 读回正确")
                ok(e && e.m === "manual", "来源标记读回正确")
                // 读回来之后仍然要能反查（说明不是"读了个形状不对的东西"）
                it.localList = [{ file: RENAMED, size: 999999 }]
                ok(it.findLocal(online) !== null, "读回的登记表仍能反查命中")
            })

            sect("3. 坏值容错：不能连坐整个 loadSettings", function() {
                try { kvWrite("{ 这根本不是 JSON") } catch (e) { ok(false, "写坏值失败：" + e) }
                it.fileMap = ({ "__sentinel": { id: "x" } })   // 先放个哨兵
                it.loadSettings()
                ok(it.fileMap["__sentinel"] === undefined,
                   "坏 JSON → 表被换成空表（哨兵没了，说明真的重新赋值过）")
                ok(it.fileMap[RENAMED] === undefined, "坏 JSON → 没有凭空造出条目")
                ok(typeof it.source === "string" && it.source.length > 0,
                   "其它设置没被连坐（source=" + it.source + "）")
                // 坏值之后表还能不能用
                it.fileMap = ({})
                it.mapPut(RENAMED, online, "manual")
                it.fileMap = ({})
                it.loadSettings()
                ok(it.fileMap[RENAMED] !== undefined, "坏值之后写入/读回仍正常（表没被搞坏）")
            })

            sect("4. 数组值也要当成空表（不能把数组当表用）", function() {
                try { kvWrite("[1,2,3]") } catch (e) { ok(false, "写数组失败：" + e) }
                it.fileMap = ({ "__sentinel": { id: "x" } })
                it.loadSettings()
                ok(it.fileMap["__sentinel"] === undefined, "数组值 → 也换成空表")
            })

            sect("5. decorateLocal / gcFileMap（真引擎）", function() {
                it.fileMap = ({})
                it.mapPut(RENAMED, online, "manual")
                it.localList = [{ file: RENAMED, size: 1000,
                                  name: "从文件名反推的名", artist: "反推歌手" }]
                it.decorateLocal()
                ok(it.localList[0].matched === true, "已登记 → matched=true（徽标 ✓）")
                ok(it.localList[0].name === "断气", "真名覆盖反推名：" + it.localList[0].name)
                ok(it.localList[0].size === 1000, "size 等原有字段没丢")
                it.localList = [{ file: OTHER, size: 10 }]
                it.decorateLocal()
                ok(it.localList[0].matched === false, "未登记 → matched=false（徽标 ?）")
                it.gcFileMap()
                ok(it.fileMap[RENAMED] === undefined, "文件已不在列表 → GC 清掉悬空登记")
                it.fileMap = ({ "__keep": { id: "1", source: "netease", t: 1 } })
                it.localList = []
                it.gcFileMap()
                ok(it.fileMap["__keep"] !== undefined,
                   "localList 为空 → 一条都不清（区分不了空文件夹/扫描失败）")
            })

            sect("6. 匹配页导航接线（真实属性 + 真实函数）", function() {
                it.fileMap = ({})
                it.localList = [{ file: RENAMED, size: 100, matched: false,
                                  name: "断气 - 回春丹 (Live)", artist: "" }]
                it.openMatch(0)
                ok(it.page === "match", "openMatch → page=match（真的切过去了）")
                ok(it.matchRec !== null && it.matchRec.file === RENAMED, "matchRec 就位")
                ok(String(it.matchQuery).length > 0,
                   "搜索词按文件名预填了：" + it.matchQuery)
                it.closeMatch()
                ok(it.page === "local", "closeMatch → 回本地页")
                ok(it.matchRec === null, "matchRec 清空（不留悬挂引用）")
            })

            sect("7. 还原探针库", function() {
                try {
                    kvWrite(dbHasRow ? dbOld : null)
                    ok(true, "已还原（hasRow=" + dbHasRow + "）")
                } catch (e) { ok(false, "还原失败：" + e) }
            })

            console.log("CHECK DONE pass=" + pass + " bad=" + bad)
            Qt.quit()
        }

        onStatusChanged: {
            if (status === Loader.Error) {
                console.log("CHECK FAIL main.qml 加载失败（Loader.Error）")
                Qt.quit()
            }
        }
    }
}
