import QtQuick 2.12
import QtQuick.LocalStorage 2.0

// 验证插件的设置持久化在同一路径下真的能读写。
// 运行时要带上应用的环境（HOME=/ XDG_DATA_HOME=/userdata/pen-data/share），
// 否则 QStandardPaths 算出的 OfflineStorage 路径和主程序不一致。
Item {
    width: 10
    height: 10

    Component.onCompleted: {
        try {
            var d = LocalStorage.openDatabaseSync("gdmusic", "1.0", "GD Music", 100000)
            var out = "(未读到)"
            d.transaction(function(tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
                tx.executeSql("INSERT OR REPLACE INTO kv VALUES(?,?)", ["probe", "hello"])
                var rs = tx.executeSql("SELECT value FROM kv WHERE key=?", ["probe"])
                if (rs.rows.length) out = rs.rows.item(0).value
            })
            console.log("LS OK readback=" + out + " path=" + d.databasePath)
        } catch (e) {
            console.log("LS FAIL " + e)
        }
        Qt.quit()
    }
}
