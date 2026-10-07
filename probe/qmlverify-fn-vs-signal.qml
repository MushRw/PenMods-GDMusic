import QtQuick 2.12
// 精确回答 Lead 的问题 3：**QML 函数（JS 函数）** 少传实参会不会抛错？
// Lead 说「QML 函数少传只得到 undefined、不抛错（与 C++ 不同）」。
// 我实测的是 **QML 信号**（会抛）。这里把三种可调用对象分开测，一次说清：
//   (1) QML JS 函数      function f(a, b) { return [a,b] }
//   (2) QML 信号         signal sig(string, color)
//   (3) C++ Q_INVOKABLE  contains()（无默认值）
Item {
    id: root
    width: 10; height: 10
    property int pass: 0
    property int bad: 0
    property int rawFail: 0
    function ok(c, l) { if (c) { pass++; console.log("FN PASS " + l) } else { bad++; console.log("FN FAIL " + l) } }

    // (1) QML JS 函数：两个形参
    function twoArgs(a, b) { return "a=" + a + " b=" + b + " argc=" + arguments.length }

    // (2) QML 信号 + 处理器
    property int sigCalls: 0
    property var sigSeen: []
    signal twoArgSignal(string m, color c)
    onTwoArgSignal: { root.sigCalls++; root.sigSeen = root.sigSeen.concat([arguments.length]) }

    // (3) C++ 对照
    Item { id: calib; width: 4; height: 4 }

    Component.onCompleted: {
        function rawCheck(c) { if (!c) root.rawFail++ }
        rawCheck(false)
        ok(root.rawFail === 1, "夹具自检 rawCheck(false) 计到 1（PASS 非恒真）")

        // ---------- (1) QML JS 函数少传 ----------
        var fThrew = false, fErr = "", fRet = ""
        try { fRet = root.twoArgs("x") } catch (e) { fThrew = true; fErr = String(e) }
        console.log("FN CALL QML函数 twoArgs('x') threw=" + fThrew
                    + " err=" + JSON.stringify(fErr) + " ret=" + JSON.stringify(fRet))
        ok(!fThrew, "(1) QML **函数** 少传实参不抛错（threw=" + fThrew + "）—— 与 Lead 的说法一致")
        ok(String(fRet).indexOf("b=undefined") >= 0,
           "(1b) 缺的形参确实是 undefined（ret=" + JSON.stringify(fRet) + "）")

        // ---------- (2) QML 信号少传 ----------
        root.sigCalls = 0; root.sigSeen = []
        var sThrew = false, sErr = ""
        try { root.twoArgSignal("only-one") } catch (e) { sThrew = true; sErr = String(e) }
        console.log("FN CALL QML信号 twoArgSignal('only-one') threw=" + sThrew
                    + " err=" + JSON.stringify(sErr) + " 处理器调用次数=" + root.sigCalls)
        ok(sThrew && sErr.indexOf("Insufficient arguments") >= 0,
           "(2) QML **信号** 少传实参**抛 Insufficient arguments**（threw=" + sThrew + "）")
        ok(root.sigCalls === 0, "(2b) 信号处理器一次都没被调用（" + root.sigCalls + "）")

        // 基线：信号传满
        root.sigCalls = 0
        var s2 = false
        try { root.twoArgSignal("m", "#fff") } catch (e) { s2 = true }
        ok(!s2 && root.sigCalls === 1, "(2c) 信号传满 2 个实参正常")

        // ---------- (3) C++ Q_INVOKABLE 少传 ----------
        var cThrew = false, cErr = ""
        try { calib.contains() } catch (e) { cThrew = true; cErr = String(e) }
        ok(cThrew && cErr.indexOf("Insufficient arguments") >= 0,
           "(3) C++ Q_INVOKABLE 少传抛 Insufficient arguments（err=" + JSON.stringify(cErr) + "）")

        console.log("FN CONCLUSION QML函数少传抛错=" + fThrew
                    + " QML信号少传抛错=" + sThrew
                    + " C++方法少传抛错=" + cThrew)
        console.log("FN RESULT pass=" + root.pass + " bad=" + root.bad)
        Qt.quit(root.bad > 0 ? 1 : 0)
    }
}
