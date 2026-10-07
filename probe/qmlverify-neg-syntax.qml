import QtQuick 2.12
// 阴性对照 B：import 语法错误的 singleton 目录
import "file:///tmp/qmlverify/negB"

Item {
    width: 10
    height: 10
    Component.onCompleted: {
        console.log("NEGB typeof MediaBridge = " + typeof MediaBridge)
        Qt.quit(0)
    }
}
