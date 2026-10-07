import QtQuick 2.12
// 阴性对照 A：插件目录副本里 MediaBridge.qml 被剥掉 `pragma Singleton`
// 期望：报 "qmldir defines type as singleton, but no pragma Singleton found"
//       或 "Type MediaBridge unavailable" ⇒ 证明「加载失败」这条路是可复现、可被探针看见的
import "file:///tmp/qmlverify/negA"

Item {
    width: 10
    height: 10
    Component.onCompleted: {
        console.log("NEGA typeof MediaBridge = " + typeof MediaBridge)
        Qt.quit(0)
    }
}
