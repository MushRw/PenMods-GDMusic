import QtQuick 2.12
import "."
import "sub" as Sub

Item {
    width: 100
    height: 100

    // 目录导入 + 别名方式引用子目录组件
    Sub.SubRow { }

    Component.onCompleted: {
        console.log("TEST-A singleton-Theme.c=" + Theme.c + " name=" + Theme.name)
        console.log("TEST-B alias-subdir=" + (Sub.SubRow !== undefined ? "OK" : "MISSING"))
        Qt.quit()
    }
}
