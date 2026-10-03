'use strict'
// 从 main.qml 抠出**真源码**求值，产出 sidecar 相关的命令/路径。
//
// 为什么单独一个文件（而不是塞在 .sh 的 heredoc 里）：
//   早先把这段 JS 放在 `EVAL=$(node - <<'JS' ... JS)` 里，bash 解析命令替换时
//   先把 JS 当 shell 词法扫了一遍 —— 于是 `import QtQuick 5.15` 变成
//   "import: command not found"，脚本直接跑飞。
//   heredoc 只有**紧跟在命令后面**时才不被解析；一旦套进 $( ) 就失效。
//   ⇒ 凡是「JS 里必然出现 $(、引号、括号」的求值，一律走独立 .js 文件。
//
// 用法：node sidecar-eval.js <main.qml> <mp3路径> <封面URL>
//   输出 JSON：{ cover, scan, ext, base, img, lrc }
const fs = require('fs')

const qmlPath = process.argv[2]
const mp3 = process.argv[3]
const url = process.argv[4]
if (!qmlPath || !mp3 || !url) {
    console.error('用法: node sidecar-eval.js <main.qml> <mp3> <coverUrl>')
    process.exit(2)
}

const src = fs.readFileSync(qmlPath, 'utf8')
const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')
// 全局 UA 常量（main.qml 的属性区），求值环境要提供给 buildCoverCmd 等命令生成函数
const UA = (/readonly property string uaBrowser: "([^"]+)"/.exec(clean) || [, 'Mozilla/5.0'])[1]

function die(m) { console.error('FAIL ❌ ' + m); process.exit(1) }

// 遮蔽字符串/注释/正则，返回**与输入等长**的数组（遮蔽处填 'x'）。
// ⛔ 必须等长：早先版本把字符串替换成 ""，长度变化后按原下标取值会错位，
//    表现为"正则字面量从中间被截断"（Invalid regular expression: missing /）。
function stripLiterals(s) {
    const out = s.split('')
    const mask = (a, b) => { for (let k = a; k < b && k < out.length; k++) out[k] = 'x' }
    let i = 0, n = s.length, prev = ''
    while (i < n) {
        const c = s[i]
        if (c === '"' || c === "'") {
            const q = c, st = i; i++
            while (i < n && s[i] !== q) { if (s[i] === '\\') i++; i++ }
            if (i >= n) return -2
            i++; mask(st, i); prev = 'x'; continue
        }
        if (c === '/' && s[i + 1] === '/') {
            const st = i
            while (i < n && s[i] !== '\n') i++
            mask(st, i); continue
        }
        if (c === '/' && s[i + 1] === '*') {
            const st = i
            i += 2
            while (i < n && !(s[i] === '*' && s[i + 1] === '/')) i++
            i += 2; mask(st, i); prev = 'x'; continue
        }
        // 正则字面量：靠上一个有效字符区分"除号"与"正则开头"
        if (c === '/' && (prev === '' || '(,=:[!&|?{};+-*%~^'.indexOf(prev) >= 0)) {
            let j = i + 1, inCls = false, ok = false
            while (j < n && s[j] !== '\n') {
                if (s[j] === '\\') { j += 2; continue }
                if (s[j] === '[') inCls = true
                else if (s[j] === ']') inCls = false
                else if (s[j] === '/' && !inCls) { ok = true; break }
                j++
            }
            if (ok) {
                let k = j + 1
                if (s[k] === 'g' || s[k] === 'i' || s[k] === 'm') k++
                mask(i, k); i = k; prev = 'x'; continue
            }
        }
        if (!/\s/.test(c)) prev = c
        i++
    }
    return out
}

// 花括号配平截取整个函数定义
function grab(name) {
    const i = clean.indexOf('function ' + name)
    if (i < 0) die('main.qml 里找不到 function ' + name)
    let k = clean.indexOf('{', i)
    if (k < 0) die(name + ' 找不到函数体')
    const st = stripLiterals(clean.slice(i))
    if (st === -2) die(name + ' 引号未闭合')
    let depth = 0
    for (let j = k; j < clean.length; j++) {
        const c = st[j - i]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) { k = j; break } }
    }
    if (depth !== 0) die(name + ' 花括号未配平')
    return clean.slice(i, k + 1)
}

function readStr(re, what) {
    const m = src.match(re)
    if (!m) die('读不到 ' + what)
    return m[1]
}

const D = readStr(/readonly property string downloadDir:\s*"([^"]+)"/, 'downloadDir')
const IMG_EXT = readStr(/readonly property string sidecarImgExt:\s*"([^"]+)"/, 'sidecarImgExt')
const SMARK = readStr(/readonly property string sidecarMark:\s*"([^"]+)"/, 'sidecarMark')
const LMARK = readStr(/readonly property string lrcMark:\s*"([^"]+)"/, 'lrcMark')
// localMark 也从源码读，不硬编码 —— 硬编码的话改了标记这条探针还在绿
const LMUS = readStr(/readonly property string localMark:\s*"([^"]+)"/, 'localMark')
const mExts = clean.match(/readonly property var sidecarImgExts:\s*(\[[^\]]*\])/)
if (!mExts) die('读不到 sidecarImgExts')
const IMGS = new Function('return ' + mExts[1])()

// dlTmpDir 在 main.qml 里是由 stateDir 拼出来的，这里按同一公式还原
const STATE = '/userdata/pen-data/share/NeteaseYoudao/YoudaoDictPen/penmods/gdmusic/state'
const TMP = STATE + '/parts'

const api = new Function(`
var downloadDir = ${JSON.stringify(D)};
var sidecarImgExt = ${JSON.stringify(IMG_EXT)};
var sidecarImgExts = ${JSON.stringify(IMGS)};
var sidecarMark = ${JSON.stringify(SMARK)};
var lrcMark = ${JSON.stringify(LMARK)};
var localMark = ${JSON.stringify(LMUS)};
var dlTmpDir = ${JSON.stringify(TMP)};
// 全局 UA 常量：main.qml 里所有 curl 都用它（2026-10-03 统一，原先各处硬编码残缺 UA）
var uaBrowser = ${JSON.stringify(UA)};
var shellQuote = function (s) { return "'" + String(s).replace(/'/g, "'\\\\''") + "'" };
${grab('sidecarBase')}
${grab('imgExtForUrl')}
${grab('buildCoverCmd')}
${grab('buildScanCmd')}
${grab('localLrcFor')}
return {
    cover: buildCoverCmd,
    scan: buildScanCmd,
    ext: imgExtForUrl,
    base: sidecarBase,
    lrc: localLrcFor
};
`)()

// 标记在顶层**摊平**输出：调用方是 shell，用点号路径取嵌套字段很容易静默拿到
// undefined（踩过：grep -c "^undefined" 恒为 0，断言全红却看不出是探针坏了）
process.stdout.write(JSON.stringify({
    cover: api.cover(url, mp3),
    scan: api.scan(),
    ext: api.ext(url),
    base: api.base(mp3),
    img: api.base(mp3) + api.ext(url),
    lrc: api.lrc(mp3),
    tmpDir: TMP,
    markImg: SMARK,
    markLrc: LMARK,
    markMp3: LMUS
}))
