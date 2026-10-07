import QtQuick 2.12
import QtQuick.Window 2.12

// ============================================================================
// 实参个数判读 v4 —— 证明 QML 不只是「不抛错」，而是真的**应用了 C++ 默认值**。
//
// 用 QQuickItem::nextItemInFocusChain(bool forward = true)
//   Qt 5.15 只有一个声明，且唯一参数 forward 的默认值是 **true**。
// 构造焦点链 A → B → C（activeFocusOnTab: true），站在 B 上：
//   · nextItemInFocusChain()      若返回 C ⇒ forward 取到了默认值 true（正确）
//                                 若返回 A ⇒ 传进去的是 false（零初始化）⇒ 默认值没被应用
//   · nextItemInFocusChain(false) 基线，应返回 A
//   · nextItemInFocusChain(true)  基线，应返回 C
// 这样「不抛错」和「语义正确」两件事被分开验证。
// ============================================================================
Window {
    id: win
    width: 100
    height: 100
    visible: true

    property int pass: 0
    property int bad: 0
    property int rawFail: 0

    function ok(c, label) {
        if (c) { pass++; console.log("FOC PASS " + label) }
        else   { bad++;  console.log("FOC FAIL " + label) }
    }
    function nameOf(it) {
        if (!it) return "null"
        if (it === a) return "A"
        if (it === b) return "B"
        if (it === c) return "C"
        return "other"
    }

    Item {
        id: host
        anchors.fill: parent
        Item { id: a; objectName: "A"; activeFocusOnTab: true; width: 10; height: 10 }
        Item { id: b; objectName: "B"; activeFocusOnTab: true; width: 10; height: 10 }
        Item { id: c; objectName: "C"; activeFocusOnTab: true; width: 10; height: 10 }
    }

    Component.onCompleted: {
        function rawCheck(x) { if (!x) win.rawFail++ }
        rawCheck(false)
        ok(win.rawFail === 1, "夹具自检 rawCheck(false) 计到 1（PASS 非恒真）")

        ok(typeof b.nextItemInFocusChain === "function", "前置 nextItemInFocusChain 是 function")

        // 校准：无默认参数的方法少传必须抛错（证明本环境确实在检查实参个数）
        var threw = false, err = ""
        try { b.contains() } catch (e) { threw = true; err = String(e) }
        ok(threw && err.indexOf("Insufficient arguments") >= 0,
           "校准 contains() 零参抛 Insufficient arguments")

        // 关键：站在 B 上，零参调用（forward 用默认值 true）
        var n0 = nameOf(b.nextItemInFocusChain())
        console.log("FOC CALL B.nextItemInFocusChain() -> " + n0)
        ok(n0 === "C", "零参调用取到默认值 true ⇒ 返回 C（得到 " + n0 + "）")

        // 基线
        var nf = nameOf(b.nextItemInFocusChain(false))
        console.log("FOC CALL B.nextItemInFocusChain(false) -> " + nf)
        ok(nf === "A", "显式 false ⇒ 返回 A（得到 " + nf + "）")

        var nt = nameOf(b.nextItemInFocusChain(true))
        console.log("FOC CALL B.nextItemInFocusChain(true) -> " + nt)
        ok(nt === "C", "显式 true ⇒ 返回 C（得到 " + nt + "）")

        console.log("FOC RESULT pass=" + win.pass + " bad=" + win.bad)
        Qt.quit(win.bad > 0 ? 1 : 0)
    }
}
