import QtQuick 2.12

// ============================================================================
// 实参个数判读 v2 —— 关掉 v1 的漏洞（grabToImage 可能有多载）
//
// v1 用 grabToImage(cb) 单参成功来推断「QML 看得见 C++ 默认参数」，
// 但 Qt 里 grabToImage 可能同时存在 1 参重载 ⇒ 单参成功可能是重载解析的结果，
// 不构成证据。v2 换成**只有一个声明、且唯一参数带默认值**的方法：
//
//   QQuickItem::nextItemInFocusChain(bool forward = true)
//       ↑ Qt5 源码里就这一个声明，不存在零参重载
//   QQuickItem::childAt(real x, real y)   ← 两参都无默认值，作校准
//   QQuickItem::contains(const QPointF &) ← 一参无默认值，作校准
//
// 判读矩阵（每条都附原始输出）：
//   · contains() 零参 / childAt(x) 单参 必须抛 "Insufficient arguments"（校准）
//   · nextItemInFocusChain() 零参：成功 ⇒ 默认参数**可见**；抛错 ⇒ **不可见**
//   · grabToImage() 零参：用来判定 grabToImage 是否存在 1 参重载
// ============================================================================
Item {
    id: root
    width: 32
    height: 32

    property int pass: 0
    property int bad: 0
    property int rawFail: 0

    function ok(c, label) {
        if (c) { pass++; console.log("AR2 PASS " + label) }
        else   { bad++;  console.log("AR2 FAIL " + label) }
    }
    function tryCall(label, fn) {
        var r = { threw: false, err: "", ret: null }
        try { r.ret = fn() } catch (e) { r.threw = true; r.err = String(e) }
        console.log("AR2 CALL " + label + " threw=" + r.threw
                    + " err=" + JSON.stringify(r.err)
                    + " retType=" + (typeof r.ret))
        return r
    }

    Item { id: target; width: 16; height: 16 }

    Component.onCompleted: {
        function rawCheck(c) { if (!c) root.rawFail++ }
        rawCheck(false)
        ok(root.rawFail === 1, "夹具自检 rawCheck(false) 计到 1（PASS 非恒真）")

        ok(typeof target.nextItemInFocusChain === "function", "前置 nextItemInFocusChain 是 function")
        ok(typeof target.childAt === "function", "前置 childAt 是 function")
        ok(typeof target.contains === "function", "前置 contains 是 function")

        // ================= 校准组：无默认参数的方法，少传必须抛错 =================
        var c1 = tryCall("CAL1 contains() 零参（无默认值）", function() { return target.contains() })
        ok(c1.threw && c1.err.indexOf("Insufficient arguments") >= 0,
           "CAL1 contains() 零参抛 Insufficient arguments")

        var c2 = tryCall("CAL2 childAt(1) 单参（两参都无默认值）", function() { return target.childAt(1) })
        ok(c2.threw && c2.err.indexOf("Insufficient arguments") >= 0,
           "CAL2 childAt(1) 单参抛 Insufficient arguments")

        var c3 = tryCall("CAL3 childAt(1,1) 双参（基线）", function() { return target.childAt(1, 1) })
        ok(!c3.threw, "CAL3 childAt(1,1) 双参成功")

        // ================= 判定组：唯一参数带默认值，零参调用 =================
        // Qt5: Q_INVOKABLE QQuickItem *nextItemInFocusChain(bool forward = true);
        //      —— 只有这一个声明，不存在零参重载 ⇒ 零参能调 = 默认参数可见
        var d1 = tryCall("D1 nextItemInFocusChain() 零参（forward 有默认值 true）", function() {
            return target.nextItemInFocusChain()
        })
        var d2 = tryCall("D2 nextItemInFocusChain(true) 单参（基线）", function() {
            return target.nextItemInFocusChain(true)
        })

        // ================= 旁证组：grabToImage 的重载情况 =================
        var g0 = tryCall("G0 grabToImage() 零参（判定是否存在 1 参重载）", function() {
            return target.grabToImage()
        })
        var g1 = tryCall("G1 grabToImage(cb) 单参", function() {
            return target.grabToImage(function(res) {})
        })
        console.log("AR2 NOTE grabToImage 零参" + (g0.threw ? "抛错" : "成功")
                    + " ⇒ " + (g0.threw ? "不存在零参重载" : "存在零参重载（v1 的 B 项因此不可用作证据）"))

        // ================= 结论 =================
        var calibrated = c1.threw && c2.threw && !c3.threw
        var defaultVisible = !d1.threw
        console.log("AR2 SUMMARY 校准成立=" + calibrated + " 默认参数可见=" + defaultVisible)
        if (calibrated && defaultVisible)
            console.log("AR2 CONCLUSION 证伪：QML **看得见** C++ 默认参数。"
                        + "nextItemInFocusChain() 零参成功调用，而 contains()/childAt() 少传就抛 "
                        + "Insufficient arguments ⇒ 抛不抛只取决于**该参数在 C++ 侧有没有默认值**，"
                        + "不是「moc 注册了完整参数表所以 QML 永远要传满」。")
        else if (calibrated && !defaultVisible)
            console.log("AR2 CONCLUSION 证实：QML 看不见 C++ 默认参数，少传即抛 Insufficient arguments")
        else
            console.log("AR2 CONCLUSION 不确定：校准未成立，判读无效")

        console.log("AR2 RESULT pass=" + root.pass + " bad=" + root.bad)
        Qt.quit(root.bad > 0 ? 1 : 0)
    }
}
