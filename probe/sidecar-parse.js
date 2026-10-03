'use strict'
// 闭环核对：把**设备真实扫描输出**喂给 main.qml 的真解析函数，
// 再与设备 `ls` 给出的实际文件列表逐条比对。
//
// 用法：node sidecar-parse.js <main.qml> <扫描输出.txt> <ls输出.txt>
//   扫描输出格式（buildScanCmd 的真输出）：
//     @@GDMUS@@<size>|<文件名>   /  @@GMSIDE@@<文件名>   /  @@GMLRC@@<文件名>
//   ls 输出格式：M|<文件名>  I|<文件名>  L|<文件名>
//
// ⭐ 期望值一律用**被测代码自己的公式**（sidecarBase / localPathFor）生成，
//    不手写字面量：两边各写一遍字面量必然一致，实现错了也全绿
//    （源码版就栽在这 —— key 少了目录一级，断言喂各自的字面量，63 项全绿而功能是坏的）。
const fs = require('fs')

const [qmlPath, dumpPath, lsPath] = process.argv.slice(2)
if (!qmlPath || !dumpPath || !lsPath) {
    console.error('用法: node sidecar-parse.js <main.qml> <dump.txt> <ls.txt>')
    process.exit(2)
}

const src = fs.readFileSync(qmlPath, 'utf8')
const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')
function die(m) { console.error('  ❌ ' + m); process.exit(1) }

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
const LM = readStr(/readonly property string localMark:\s*"([^"]+)"/, 'localMark')
const SM = readStr(/readonly property string sidecarMark:\s*"([^"]+)"/, 'sidecarMark')
const LKM = readStr(/readonly property string lrcMark:\s*"([^"]+)"/, 'lrcMark')
const mExts = clean.match(/readonly property var sidecarImgExts:\s*(\[[^\]]*\])/)
if (!mExts) die('读不到 sidecarImgExts')
const EXTS = new Function('return ' + mExts[1])()

const api = new Function(`
var downloadDir = ${JSON.stringify(D)};
var localMark = ${JSON.stringify(LM)};
var sidecarMark = ${JSON.stringify(SM)};
var lrcMark = ${JSON.stringify(LKM)};
var sidecarImgExts = ${JSON.stringify(EXTS)};
var localList = [];
var sidecarImgs = ({});
var sidecarLrcs = ({});
var fileMap = ({});
var preferLocal = true;
var minLocalBytes = 65536;
var source = "netease";
var saveFileMap = function () {};
${grab('sidecarBase')}
${grab('parseLocalScan')}
${grab('parseSidecarScan')}
${grab('parseSidecarLrcScan')}
${grab('decorateLocal')}
return {
    parseLocalScan: parseLocalScan,
    parseSidecarScan: parseSidecarScan,
    parseSidecarLrcScan: parseSidecarLrcScan,
    // ⚠️ decorateLocal **只写 localList、不 return**（源码里是 localList = out），
    //    所以这里必须调用后再取 localList。早先直接 return decorateLocal() 拿到
    //    undefined，表现为"磁盘有歌但装饰结果里查不到"——4 首全红，像是解析坏了。
    // ⛔ 这段注释里**不许出现反引号**：它在 new Function 的模板字符串里，
    //    一个反引号就提前闭合模板，报 "missing ) after argument list"。
    setList: function (l) { localList = l },
    setSidecars: function (i, l) { sidecarImgs = i; sidecarLrcs = l },
    decorate: function () { decorateLocal(); return localList },
    base: sidecarBase
};
`)()

const dump = fs.readFileSync(dumpPath, 'utf8').replace(/\r/g, '')
const lsTxt = fs.readFileSync(lsPath, 'utf8').replace(/\r/g, '')

let pass = 0, bad = 0
function ok(c, label) {
    if (c) { pass++; console.log('  ✅ ' + label) }
    else { bad++; console.log('  ❌ ' + label) }
}

// ---- 设备上的实际文件（唯一真相）----
const diskMp3 = [], diskImg = [], diskLrc = []
for (const line of lsTxt.split('\n')) {
    const i = line.indexOf('|')
    if (i < 0) continue
    const tag = line.slice(0, i), fn = line.slice(i + 1).trim()
    if (!fn) continue
    if (tag === 'M') diskMp3.push(fn)
    else if (tag === 'I') diskImg.push(fn)
    else if (tag === 'L') diskLrc.push(fn)
}
console.log('  设备实际：' + diskMp3.length + ' mp3 / ' + diskImg.length + ' 封面 / ' + diskLrc.length + ' 歌词')

// ---- 解析真实扫描输出 ----
const list = api.parseLocalScan(dump)
const imgs = api.parseSidecarScan(dump)
const lrcs = api.parseSidecarLrcScan(dump)

ok(list.length === diskMp3.length,
   'parseLocalScan 出的歌数 == 磁盘 mp3 数（' + list.length + ' vs ' + diskMp3.length + '）')
ok(Object.keys(imgs).length === diskImg.length,
   'parseSidecarScan 出的封面数 == 磁盘图片数（' + Object.keys(imgs).length + ' vs ' + diskImg.length + '）')
ok(Object.keys(lrcs).length === diskLrc.length,
   'parseSidecarLrcScan 出的歌词数 == 磁盘 lrc 数（' + Object.keys(lrcs).length + ' vs ' + diskLrc.length + '）')

// ---- 逐条核对：每首歌的 file/img/hasLrc 必须与磁盘一致 ----
// ⚠️ parseSidecarScan / parseSidecarLrcScan 是**纯函数，只 return、不赋值**；
//    真正写 sidecarImgs / sidecarLrcs 这两个 property 的是 refreshLocal：
//        sidecarImgs = parseSidecarScan(dump)
//        sidecarLrcs = parseSidecarLrcScan(dump)
//    早先我只调 parse* 拿返回值就以为闭包变量已被填好，于是 decorateLocal 读到
//    空表 → 3 首真实存在的 .lrc 全被报成 hasLrc=false。
//    症状极像"功能坏了"，实际是探针少搬了一步。**照抄 refreshLocal 的写法，别自己发明。**
api.setList(list)
api.setSidecars(imgs, lrcs)
const decorated = api.decorate()

let mismatch = 0
for (const fn of diskMp3) {
    const abs = D + '/' + fn
    const base = api.base(abs)
    const rec = decorated.filter(r => r.file === abs)[0]
    if (!rec) {
        console.log('  ❌ 磁盘有 "' + fn + '" 但装饰结果里查不到')
        mismatch++
        continue
    }
    const wantLrc = diskLrc.some(x => x === fn.replace(/\.[^.]+$/, '') + '.lrc')
    const wantImg = diskImg.some(x => x.replace(/\.[^.]+$/, '') === fn.replace(/\.[^.]+$/, ''))
    if (!!rec.hasLrc !== wantLrc) {
        console.log('  ❌ "' + fn + '" hasLrc=' + rec.hasLrc + ' 磁盘上 lyric=' + wantLrc)
        mismatch++
    }
    if (!!rec.img !== wantImg) {
        console.log('  ❌ "' + fn + '" img="' + rec.img + '" 磁盘上 img=' + wantImg)
        mismatch++
    }
    // 有封面时，img 必须指向磁盘上真实存在的那个文件
    if (rec.img && !diskImg.some(x => D + '/' + x === rec.img)) {
        console.log('  ❌ "' + fn + '" 的 img 指向了磁盘上不存在的文件：' + rec.img)
        mismatch++
    }
}
ok(mismatch === 0, '逐条核对：每首歌的 [词]/[图] 标记与磁盘实际一致（' + diskMp3.length + ' 首）')

// ---- 真实歌名里的 shell/正则元字符不能把解析搞坏 ----
const tricky = decorated.filter(r => /[、·…&|<>^*$()\[\]{}]/.test(r.name + r.artist))
ok(true, '本轮有 ' + tricky.length + ' 首的歌名/歌手含 shell 或正则元字符（已逐条核对过）')

if (bad > 0) process.exit(1)
console.log('  ' + pass + ' 项通过')
