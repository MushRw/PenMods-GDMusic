#!/bin/bash
# 验证「小图标按钮」的可点性 —— 纯源码结构断言。
#
# 为什么需要一个专门盯这个的探针：这类 bug **一个都不会报错**。
#   ① 按钮被整行点击区盖住：QML 不警告，点击"穿透"成播放，界面看着一切正常，
#      用户只会以为"自己没点准"（本次的真凶）；
#   ② 按钮没背景：纯视觉问题，任何逻辑测试都测不出来，但用户看不出可点范围的边界，
#      落指就只能靠猜；
#   ③ 按钮太小：同上，而且 press/release 之间手指位移稍大，MouseArea 的 onClicked 就不触发。
# 三者的共同点是「跑起来一切正常、只有人手指知道不对」，所以只能靠读源码结构钉住。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
Q="$ROOT/plugin/qml"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)

for f in "$Q/pages/LocalPage.qml" "$Q/pages/SearchPage.qml" \
         "$Q/pages/MatchPage.qml" "$Q/components/TitleBar.qml" \
         "$Q/components/IconButton.qml"; do
    [ -f "$f" ] || { echo "找不到 $f"; exit 1; }
done

"$NODE" - "$Q" <<'JS'
'use strict'
const fs = require('fs')
const Q = process.argv[2]

let pass = 0, fail = 0
function ok(cond, msg) {
    if (cond) { pass++; console.log('  OK   ' + msg) }
    else { fail++; console.log('  BAD  ' + msg) }
}

// 去掉整行注释：注释里的花括号会把下面的「括号配平」截取法带偏，
// 而本次好几处注释里正好写了 "?" "×" 和括号。
function strip(src) { return src.replace(/^[ \t]*\/\/.*$/gm, '') }

// 截取 marker 所在的块：先从 marker 往前找最近的 opener，再向后配平花括号。
// （marker 写在块**内部**，所以不能从 marker 往后找第一个 '{'。）
function block(src, marker, opener) {
    const p = src.indexOf(marker)
    if (p < 0) return null
    const j = src.lastIndexOf(opener, p)
    if (j < 0) return null
    let depth = 0
    for (let k = j; k < src.length; k++) {
        if (src[k] === '{') depth++
        else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(j, k + 1) }
    }
    return null
}

function delegateOf(src) {
    const p = src.indexOf('delegate:')
    if (p < 0) return null
    const j = src.indexOf('{', p)
    if (j < 0) return null
    let depth = 0
    for (let k = j; k < src.length; k++) {
        if (src[k] === '{') depth++
        else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(j, k + 1) }
    }
    return null
}

const F = {}
function src(rel) {
    if (!F[rel]) F[rel] = strip(fs.readFileSync(Q + '/' + rel, 'utf8'))
    return F[rel]
}

// =====================================================================
console.log('--- ① 整行点击区必须【先声明】（= 在下层），不能盖住按钮 ---')
// QML 同 z 下后声明的在上层。整行点击区 anchors.fill 覆盖全行，
// 一旦写在按钮之后就会吃掉按钮的点击 —— 用户按「?」「×」「↓」实际触发的是「播放这首」。
// ⚠️ 只对 ListView 的 delegate 断言：那里面才有"覆盖整行的点击区"。
//    （下载队列卡片的取消键虽然也是按钮，但那一层没有覆盖整行的 MouseArea，不受此规则约束。）
;[['pages/LocalPage.qml',  'itemArea', ['mapArea', 'delArea']],
  ['pages/SearchPage.qml', 'itemArea', ['dlArea']]].forEach(function (spec) {
    const [rel, rowId, btnIds] = spec
    const d = delegateOf(src(rel))
    if (!d) { ok(false, rel + ' 找不到 delegate'); return }
    const rowPos = d.indexOf('id: ' + rowId)
    ok(rowPos >= 0, rel + '：delegate 里有整行点击区 ' + rowId)
    // 防止有人复制粘贴后留下两个同名 MouseArea
    const dup = (d.match(new RegExp('id:\\s*' + rowId + '\\b', 'g')) || []).length
    ok(dup === 1, rel + '：' + rowId + ' 只应声明一次（实际 ' + dup + '）')
    btnIds.forEach(function (b) {
        const bp = d.indexOf('id: ' + b)
        ok(bp >= 0, rel + '：delegate 里有按钮 ' + b)
        if (rowPos >= 0 && bp >= 0)
            ok(rowPos < bp, rel + '：' + rowId + ' 必须先于 ' + b + ' 声明，否则会盖住它')
    })
})

// =====================================================================
console.log('--- ② 小按钮：有 objectName / 有底色 / 有描边 / 够大 ---')
// [文件, 定位 marker, 外层 opener, 最小宽, 最小高, 说明]
const BTNS = [
    ['pages/LocalPage.qml',  'objectName: "gdLocalMatchBtn"', 'Rectangle {', 28, 24, '本地页·匹配徽标 ?/✓'],
    ['pages/LocalPage.qml',  'objectName: "gdLocalDelBtn"',   'Rectangle {', 28, 24, '本地页·删除 ×'],
    ['pages/LocalPage.qml',  'objectName: "gdDlCancelBtn"',   'Rectangle {', 24, 20, '下载队列·取消 ×'],
    ['pages/SearchPage.qml', 'objectName: "gdSearchDlBtn"',   'Rectangle {', 28, 24, '搜索页·下载 ↓'],
    ['pages/SearchPage.qml', 'objectName: "gdHistDelBtn"',    'Rectangle {', 24, 18, '搜索历史·删除 ×'],
    ['components/TitleBar.qml',  'id: backBox',  'Rectangle {', 28, 24, '标题栏·返回'],
    ['components/TitleBar.qml',  'id: localBox', 'Rectangle {', 28, 24, '标题栏·本地'],
    ['components/TitleBar.qml',  'id: setBox',   'Rectangle {', 28, 24, '标题栏·设置'],
    ['components/IconButton.qml','id: btn',      'Rectangle {', 34, 28, '播放控制按钮'],
    ['pages/MatchPage.qml',  'objectName: "gdMatchClearBtn"', 'Rectangle {', 56, 18, '匹配页·清除匹配'],
    ['pages/MatchPage.qml',  'objectName: "gdMatchCloseBtn"', 'Rectangle {', 44, 18, '匹配页·关闭'],
]

// 只认「自己那一层」的 width/height：用负向后顾排除 border.width / anchors.fillWidth 等。
// ❗不能带 g 标志：带 g 时 String.match 返回的是全部匹配文本、拿不到捕获组，
//   而且我们要的就是**第一个**（块自己那一层），不是全块最小值。
const RE_W = /(?<![.\w])width:\s*([^\n;]+)/
const RE_H = /(?<![.\w])height:\s*([^\n;]+)/

function numsIn(expr) {
    const m = expr.match(/\d+/g)
    return m ? m.map(Number) : []
}

BTNS.forEach(function (spec) {
    const [rel, marker, opener, minW, minH, name] = spec
    const blk = block(src(rel), marker, opener)
    if (!blk) { ok(false, name + '：在 ' + rel + ' 里定位不到'); return }

    ok(/objectName:/.test(blk) || rel.indexOf('components/') === 0 || /id:/.test(blk),
       name + '：可被探针定位')

    // 底色不能是 transparent（那正是"没有背景"的写法）
    ok(!/"transparent"/.test(blk), name + '：有可见底色（不再是 "transparent"）')

    // 描边：把可点范围的边界画出来
    ok(/border\.width:\s*1/.test(blk), name + '：有 1px 描边')

    // 尺寸：只取**块自己那一层**的声明 —— 即第一个 width/height 表达式。
    // ⚠️ 不能对整个块求 min：块里还嵌套着 Canvas / Text 子项（比如标题栏的
    //    Canvas 是 16x16），取 min 会把子项的尺寸当成按钮的，是本探针踩过的坑。
    // 条件表达式取最小值（如 delBox 的 `confirming ? 46 : 30` → 30，即未展开态）。
    const wm = blk.match(RE_W), hm = blk.match(RE_H)
    const ws = wm ? numsIn(wm[1]) : []
    const hs = hm ? numsIn(hm[1]) : []
    const w = ws.length ? Math.min(...ws) : 0
    const h = hs.length ? Math.min(...hs) : 0
    ok(w >= minW, name + '：宽 ' + w + ' >= ' + minW)
    ok(h >= minH, name + '：高 ' + h + ' >= ' + minH)
})

// =====================================================================
console.log('--- ③ 下载页的取消键不再是裸 Item（Item 画不了底色）---')
const qc = block(src('pages/LocalPage.qml'), 'objectName: "gdDlCancelBtn"', 'Rectangle {')
ok(qc !== null, '下载队列取消键的外层是 Rectangle（不是 Item）')

// =====================================================================
console.log('--- ④ 相邻按钮不能贴在一起（误触）---')
const lp = src('pages/LocalPage.qml')
const mapBoxBlk = block(lp, 'objectName: "gdLocalMatchBtn"', 'Rectangle {')
ok(/anchors\.rightMargin:\s*([6-9]|\d\d)/.test(mapBoxBlk || ''),
   '本地页·匹配徽标与左侧删除键之间留有 >= 6px 间距')

console.log('')
console.log('CHECK DONE  pass=' + pass + '  bad=' + fail)
process.exit(fail ? 1 : 0)
JS
