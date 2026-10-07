import QtQuick 2.12

// ============================================================================
// 🔴 关键实验：showToast 到底是 **信号(signal)** 还是 **方法(method)**？
//
// 证据链指向「信号」：
//   · neo/factory-qml/qml/commons/YToast.qml:61-67
//       Connections { target: qmlGlobal
//                     ignoreUnknownSignals: true
//                     function onShowToast(qsMsg, clrBg) { id_global_toast.show(qsMsg, clrBg) } }
//     Connections 只能连接**信号**，onShowToast 是信号处理器的命名约定。
//   · mangled 符号 _ZN7YGlobal9showToastERK7QStringRK6QColor 正是 moc 为信号
//     生成的 emitter 函数。
//   · moc 参数名 qsMsg / clrBg 与 YToast.qml 里 onShowToast(qsMsg, clrBg) 完全一致。
//
// 为什么这决定成败：
//   QML 里 **信号** 少传实参是合法的（缺的参数 = undefined）；
//   而 **方法** 少传（无默认值时）才抛 "Insufficient arguments"。
//   ⇒ 若 showToast 是信号，则「少传一个实参 ⇒ 抛异常被 catch 吞掉 ⇒ 用户什么都看不到」
//     这条机制解释**不成立**；真实后果只是 clrBg=undefined（颜色不对/赋值失败），
//     toast 本体**照样会弹**。
// ============================================================================
Item {
    id: root
    width: 10
    height: 10

    property int pass: 0
    property int bad: 0
    property int rawFail: 0
    function ok(c, label) {
        if (c) { pass++; console.log("SG PASS " + label) }
        else   { bad++;  console.log("SG FAIL " + label) }
    }

    // ---- 模拟 YGlobal：一个带 showToast(string, color) **信号** 的 QObject ----
    QtObject {
        id: fakeYGlobal
        property int handlerCalls: 0
        property var seenArgs: []
        property string lastColor: "<never>"
        property bool lastColorValid: false

        signal showToast(string qsMsg, color clrBg)

        // 信号处理器：完全照抄 YToast.qml 的形态
        onShowToast: {
            fakeYGlobal.handlerCalls++
            // 记录实际收到的实参个数（信号处理器里 arguments 可用）
            fakeYGlobal.seenArgs = fakeYGlobal.seenArgs.concat([arguments.length])
            fakeYGlobal.lastColor = String(clrBg)
            // 复现 YToast.qml 里 `id_global_toast.color = clrBg` 的行为
            var probeColor = Qt.rgba(0, 0, 0, 0)
            probeColor = clrBg
            fakeYGlobal.lastColorValid = probeColor.valid === true
        }
        function reset() {
            handlerCalls = 0; seenArgs = []; lastColor = "<never>"; lastColorValid = false
        }
    }

    // ---- 对照：真正的「方法」少传实参（用 Qt 自带的 C++ 方法校准） ----
    Item { id: itemForCalib; width: 8; height: 8 }

    Component.onCompleted: {
        function rawCheck(c) { if (!c) root.rawFail++ }
        rawCheck(false)
        ok(root.rawFail === 1, "夹具自检 rawCheck(false) 计到 1（PASS 非恒真）")

        // ============ 校准：C++ 方法少传实参确实抛错（证明本环境检查实参个数） ============
        var calThrew = false, calErr = ""
        try { itemForCalib.contains() } catch (e) { calThrew = true; calErr = String(e) }
        ok(calThrew && calErr.indexOf("Insufficient arguments") >= 0,
           "校准 C++ 方法 contains() 零参抛 Insufficient arguments（err=" + JSON.stringify(calErr) + "）")

        // ============ 实验 1：**信号** 少传实参（1 个而不是 2 个） ============
        // 🔴 本探针第一版**假设**「信号少传实参不抛错（缺的参数=undefined）」——
        //    真机实测**证伪**：QML 信号同样抛 Insufficient arguments，且处理器
        //    **一次都没被调用**。断言已按实测结果改正（下面三条就是实测结论）。
        fakeYGlobal.reset()
        var sigThrew = false, sigErr = ""
        try {
            fakeYGlobal.showToast("只有一条实参")          // ← 故意只传 1 个
        } catch (e) { sigThrew = true; sigErr = String(e) }
        console.log("SG CALL 信号 showToast(1个实参) threw=" + sigThrew
                    + " err=" + JSON.stringify(sigErr)
                    + " 处理器调用次数=" + fakeYGlobal.handlerCalls
                    + " 收到实参数=" + JSON.stringify(fakeYGlobal.seenArgs)
                    + " clrBg=" + JSON.stringify(fakeYGlobal.lastColor)
                    + " 颜色有效=" + fakeYGlobal.lastColorValid)
        ok(sigThrew && sigErr.indexOf("Insufficient arguments") >= 0,
           "1 信号少传实参**抛 Insufficient arguments**（threw=" + sigThrew + "）")
        ok(fakeYGlobal.handlerCalls === 0,
           "1b 信号处理器**一次都没被调用**（次数=" + fakeYGlobal.handlerCalls + "）⇒ toast 不会弹")
        ok(fakeYGlobal.seenArgs.length === 0,
           "1c 处理器未收到任何实参（seenArgs=" + JSON.stringify(fakeYGlobal.seenArgs) + "）")

        // ============ 实验 2：信号传满 2 个实参（基线） ============
        fakeYGlobal.reset()
        var fullThrew = false
        try { fakeYGlobal.showToast("两条实参", "#E5605C") } catch (e) { fullThrew = true }
        console.log("SG CALL 信号 showToast(2个实参) threw=" + fullThrew
                    + " 处理器调用次数=" + fakeYGlobal.handlerCalls
                    + " clrBg=" + JSON.stringify(fakeYGlobal.lastColor)
                    + " 颜色有效=" + fakeYGlobal.lastColorValid)
        ok(!fullThrew && fakeYGlobal.handlerCalls === 1, "2 信号双实参正常")
        ok(fakeYGlobal.lastColorValid === true, "2b 双实参时颜色有效")

        // ============ 实验 3：确认「少传」的真实后果 ============
        // 🔴 实测结果：不是「toast 弹出来但颜色不对」，而是**信号根本没发出、
        //    处理器一次都没跑** ⇒ toast 完全不显示。第一版的猜测（颜色失效）已证伪。
        fakeYGlobal.reset()
        var threw3 = false
        try { fakeYGlobal.showToast("单实参") } catch (e) { threw3 = true }
        console.log("SG NOTE 单实参时 threw=" + threw3
                    + " 处理器调用次数=" + fakeYGlobal.handlerCalls
                    + " ⇒ 真实后果是 **toast 完全不显示**，不是「颜色失效」")
        ok(threw3 && fakeYGlobal.handlerCalls === 0,
           "3 少传实参 ⇒ 信号未发出、toast 完全不显示")

        // ============ 实验 4：本探针**刻意不** import 插件目录 ============
        // 它只回答「信号少传实参会怎样」这一个问题，不依赖 MediaBridge。
        // （MediaBridge 是否可加载由 qmlverify-singleton.qml 单独验证。）
        console.log("SG NOTE 本探针不 import 插件目录，typeof MediaBridge = " + typeof MediaBridge)

        console.log("SG SUMMARY 信号少传抛错=" + sigThrew
                    + " 处理器被调用次数=" + fakeYGlobal.handlerCalls)
        console.log("SG RESULT pass=" + root.pass + " bad=" + root.bad)
        Qt.quit(root.bad > 0 ? 1 : 0)
    }
}
