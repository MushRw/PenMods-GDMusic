// ============================================================
// ⚠️ NOT-A-TEST —— 这是**诊断打印件**，不是断言件。
//
// 本文件全文没有 bad++ / pass 计数，只有两行 console.log 让人眼看；
// 裸 Qt.quit() 恒返回 0；且 probe/ 下**没有任何 .sh 引用本文件**
// ⇒ 它的"CHECK DONE"不构成任何回归保护。
//
// 2026-10-05 标注：它带着 -device 前缀和 CHECK DONE 字样，混在一堆真断言件里，
// 极易被当成"验过了"。**本次刻意不改它的断言性**（改成断言会改变用途，
// 且 Image.status 的判定要连设备实测才能定阈值，不该由我拍板）——
// 只把身份讲清楚。要变成真断言件：加 bad 计数 + `Qt.quit(bad>0?1:0)`
// + 写一个配套 .sh 去 grep "bad=0"（照抄 login-device.qml:126-127 /
// addpick-device.sh:47）。清单见 audit-report/gdmusic-probe-ref.md 第一节 B。
// ============================================================
import QtQuick 2.12

Item {
    id: root
    width: 320
    height: 170

    property int imgStatus: -1
    property string imgSize: "?"

    Image {
        id: im
        objectName: "gdImgProbe"
        width: 64; height: 64
        source: "file:///tmp/imgchk/c.jpg"
        asynchronous: false
        cache: false
        onStatusChanged: {
            root.imgStatus = status
            root.imgSize = String(sourceSize.width) + "x" + String(sourceSize.height)
            console.log("IMG status", status, "size", root.imgSize, "err", errorString)
        }
    }

    Timer {
        interval: 2500
        running: true
        repeat: false
        onTriggered: {
            console.log("CHK img status=" + root.imgStatus + " size=" + root.imgSize)
            console.log("CHECK DONE")
            Qt.quit()
        }
    }
}
