#!/bin/bash
# 验证「下载时同时下载封面与歌词」(sidecar) —— 拿 main.qml 的真源码求值再断言。
#
# 覆盖三组：
#   A 纯函数：路径推导（sidecarBase/localImgFor/localLrcFor）+ 扩展名推断（imgExtForUrl）
#   B 纯函数：两个扫描解析器（parseSidecarScan/parseSidecarLrcScan）+ decorate 的贴字段逻辑
#   C 接线断言：dlKick 真的调 saveSidecars、buildMetaCmd 真的写 pic_id、
#               fetchCover 真的先查本地、fetchLocalLyric 真的返回布尔
#
# 为什么 B 组要用**手写的假扫描输出**而不是真设备：
#   真设备的拼接由 probe/scancmd-e2e.sh 负责（那边会打破行数断言，本组不重复）。
#   本组只管"输出 → 解析 → 贴到记录"这一段纯逻辑，可以穷举边界。
#   ⚠️ 两组都要有：只有真设备那组，解析器的边界（webp/空行/大小写）测不到；
#   只有本组，命令拼接错了会全绿。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
[ -f "$QML" ] || { echo "找不到 $QML"; exit 1; }

"$NODE" - "$QML" <<'JS'
'use strict'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8')

const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')
function die(m) { console.error('FAIL ❌ ' + m); process.exit(1) }

// 遮蔽字符串/注释/正则，返回**与输入等长**的数组（被遮蔽处填中性字符 'x'）。
// ⛔ 必须等长：早先版本把字符串替换成 ""，长度就变了，于是拿剥离结果按原下标取值会错位，
//    表现为"正则字面量从中间被截断"（Invalid regular expression: missing /）。
//    等长之后，遮蔽结果与原文可以按下标一一对应，括号配平才不会看错位置。
// 返回 -2 = 引号没闭合（白捡一个"引号忘了收尾"检查）。
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

function grab(name) {
    const i = clean.indexOf('function ' + name)
    if (i < 0) die('main.qml 里找不到 function ' + name)
    let k = clean.indexOf('{', i)
    if (k < 0) die(name + ' 找不到函数体')
    // 逐字符**同步**推进原文指针与剥离后的指针：两者长度不同（字符串被替换成 ""），
    // 不能拿 st[k - i] 去索引 —— 那样会在字符串处错位，
    // 表现为"正则字面量被从中间截断"（Invalid regular expression: missing /）。
    const st = stripLiterals(clean.slice(i))
    if (st === -2) die(name + ' 引号未闭合')
    let depth = 0
    // st 与 clean.slice(i) **等长**（stripLiterals 返回数组），可按下标一一对应
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
const LM = '@@GDMUS@@'
// sidecarImgExts 是 var 数组，直接从源码抠出来求值
const extsBody = grab ? null : null
const mExts = clean.match(/readonly property var sidecarImgExts:\s*(\[[^\]]*\])/)
if (!mExts) die('读不到 sidecarImgExts')
const IMGS = new Function('return ' + mExts[1])()

let pass = 0, bad = 0
function ok(c, label) {
    if (c) { pass++; console.log('  ✅ ' + label) }
    else { bad++; console.log('  ❌ ' + label) }
}
function eq(a, b, label) { ok(a === b, label + '  (得到 ' + JSON.stringify(a) + ')') }

console.log('=== A. 路径推导与扩展名推断（纯函数）===')
const api = new Function(`
var downloadDir = ${JSON.stringify(D)};
var sidecarImgExt = ${JSON.stringify(IMG_EXT)};
var sidecarImgExts = ${JSON.stringify(IMGS)};
var sidecarMark = ${JSON.stringify(SMARK)};
var lrcMark = ${JSON.stringify(LMARK)};
var localMark = ${JSON.stringify(LM)};
var localList = [];
var fileMap = ({});
var sidecarImgs = ({});
var sidecarLrcs = ({});
var shellQuote = function (s) { return "'" + String(s).replace(/'/g, "'\\\\''") + "'" };
${grab('sidecarBase')}
${grab('localImgFor')}
${grab('localLrcFor')}
${grab('imgExtForUrl')}
${grab('parseSidecarScan')}
${grab('parseSidecarLrcScan')}
${grab('parseLocalScan')}
${grab('decorateLocal')}
return {
  sidecarBase: sidecarBase, localImgFor: localImgFor, localLrcFor: localLrcFor,
  imgExtForUrl: imgExtForUrl,
  parseSidecarScan: parseSidecarScan, parseSidecarLrcScan: parseSidecarLrcScan,
  parseLocalScan: parseLocalScan, decorateLocal: decorateLocal,
  setImgs: function (v) { sidecarImgs = v },
  setLrcs: function (v) { sidecarLrcs = v },
  setList: function (v) { localList = v },
  getList: function () { return localList }
};
`)()

const MP3 = D + '/断气-回春丹.mp3'
eq(api.sidecarBase(MP3), D + '/断气-回春丹', 'sidecarBase 去掉 .mp3')
eq(api.localImgFor(MP3), D + '/断气-回春丹' + IMG_EXT, 'localImgFor = 同名 + 默认扩展名')
eq(api.localLrcFor(MP3), D + '/断气-回春丹.lrc', 'localLrcFor = 同名 + .lrc')
// 三者必须同源：这是 A 组最要紧的一条 —— 各自写公式的话，改命名规则时只会对上一半
eq(api.sidecarBase(MP3), api.localLrcFor(MP3).replace(/\.lrc$/, ''), '封面/歌词与 mp3 共享同一个 base（mp3/封面/歌词三路径同源）')
ok(api.sidecarBase('') === '' && api.sidecarBase(null) === '', 'sidecarBase 对空输入返回空串（不崩）')

// 扩展名推断：查询串必须先剥掉，否则会截出 ".jpg?param=500y500"
eq(api.imgExtForUrl('https://p2.music.126.net/xx==/109951165671182684.jpg?param=500y500'),
   '.jpg', 'imgExtForUrl 剥掉查询串后取 .jpg')
eq(api.imgExtForUrl('https://example.com/a/b/c.PNG'), '.png', '大写 .PNG 归一为 .png')
eq(api.imgExtForUrl('https://example.com/a/b/c.webp'), IMG_EXT, '白名单外的 .webp 兜底成 ' + IMG_EXT)
eq(api.imgExtForUrl('https://example.com/noext'), IMG_EXT, '无扩展名兜底')
eq(api.imgExtForUrl(''), IMG_EXT, '空 URL 兜底')
ok(IMGS.indexOf('.jpg') >= 0 && IMGS.indexOf('.png') >= 0, '白名单含 .jpg/.png（设备实测只有 jpeg 解码器）')
ok(IMGS.indexOf('.webp') < 0, '白名单**不含** .webp（设备没有 webp 插件，存下来也加载不出）')

console.log('--- B. 扫描解析 ---')
const DUMP = [
    LM + '11735293|断气-回春丹.mp3',
    LM + '7340032|孤勇者-陈奕迅.mp3',
    LM + '512|只有歌没附件-某人.mp3',
    SMARK + '断气-回春丹.jpg',
    SMARK + '孤勇者-陈奕迅.PNG',          // 大写扩展名
    SMARK + '不该被认-某人.webp',          // 白名单外
    SMARK + '',                          // 空文件名
    LMARK + '断气-回春丹.lrc',
    'not a marked line',                 // 噪声
    ''
].join('\n')
const imgs = api.parseSidecarScan(DUMP)
const lrcs = api.parseSidecarLrcScan(DUMP)
eq(Object.keys(imgs).length, 2, '只认 2 张封面（.webp 与空行被忽略）')
// ⚠️ key 必须是「含目录的完整 base」—— 与 sidecarBase(绝对路径) 逐字符相同。
//   这里刻意用 sidecarBase() 构造期望值，而不是手写字面量：
//   早先实现用"只有文件名"当 key，于是 decorateLocal 查表永远 miss（封面下了永不显示），
//   而当时这两条断言（各自喂各自的字面量）**都是绿的**。
//   教训：跨模块的 key 必须由**被测代码自己的公式**生成期望值，两边手写字面量必然一致。
eq(imgs[api.sidecarBase(MP3)], D + '/断气-回春丹.jpg', 'jpg 封面：key == sidecarBase(绝对路径)')
eq(imgs[api.sidecarBase(D + '/孤勇者-陈奕迅.mp3')], D + '/孤勇者-陈奕迅.PNG', '大写 .PNG 也能认（原样保留文件名）')
ok(imgs['不该被认-某人'] === undefined && imgs[D + '/不该被认-某人'] === undefined, '.webp 不进封面表')
ok(imgs[''] === undefined && imgs[D] === undefined, '空文件名不进封面表')
eq(Object.keys(lrcs).length, 1, '只认 1 份歌词')
eq(lrcs[api.sidecarBase(MP3)], D + '/断气-回春丹.lrc', 'lrc：key == sidecarBase(绝对路径)')
// 钉死"key 含目录"这件事本身。⚠️ 别用 Object.keys(...)[0] 之类依赖键序的写法 ——
//   对象键序不保证，那条断言会在某次无关改动后毫无原因地变红，而那会教会错误的调试直觉。
//   这里直接验证"只有文件名（不含目录）时查不到"，这才是那个 bug 的实际症状。
ok(imgs['断气-回春丹'] === undefined, '只给文件名查不到（这就是那个 bug 的症状：封面下了永不显示）')
ok(lrcs[D + '/断气-回春丹'] !== undefined, 'lrc 表的 key 与封面表同形态')

const songs = api.parseLocalScan(DUMP)
eq(songs.length, 3, 'parseLocalScan 仍只出 3 首（sidecar 行不混进歌曲列表）')

api.setImgs(imgs); api.setLrcs(lrcs)
api.setList(songs)
api.decorateLocal()
const dec = api.getList()
eq(dec.length, 3, 'decorate 后仍是 3 条')
eq(dec[0].img, D + '/断气-回春丹.jpg', '第 1 首贴上本地封面路径')
ok(dec[0].hasLrc === true, '第 1 首 hasLrc 为严格 true')
eq(dec[1].img, D + '/孤勇者-陈奕迅.PNG', '第 2 首贴上 .PNG 封面')
ok(dec[1].hasLrc === false, '第 2 首没有歌词 → hasLrc 为 false')
eq(dec[2].img, '', '第 3 首没封面 → img 为空串（不是猜一个路径）')
ok(dec[2].hasLrc === false, '第 3 首没歌词 → hasLrc 为 false')
ok(dec[0].name === '断气' && dec[0].artist === '回春丹', 'decorate 不破坏原有的歌名/歌手解析')

console.log('--- C. 接线断言（函数写了却没接上线，两轨逻辑测试全是绿的）---')
function hasIn(fnName, needle) {
    return grab(fnName).indexOf(needle) >= 0
}
ok(hasIn('dlKick', 'saveSidecars('), 'dlKick 取到地址后调用 saveSidecars')
ok(!hasIn('dlPoll', 'saveLocalLrc('), 'dlPoll 的 ok 分支**不再**重复存歌词（否则白走一遍 API）')
ok(hasIn('dlRecover', 'saveSidecars('), 'dlRecover 补 sidecar（关插件期间下的歌否则永远没封面）')
ok(src.indexOf('pic_id: song.pic_id') >= 0, 'buildMetaCmd 把 pic_id 写进 .meta（recover 靠它要封面）')
ok(/var song = \{ id: meta\.id[\s\S]{0,200}pic_id: meta\.pic_id/.test(clean), 'dlRecover 从 .meta 读回 pic_id')
ok(hasIn('saveSidecars', 'dlSidecar'), 'saveSidecars 受 dlSidecar 开关控制')
ok(hasIn('saveLocalLrc', 'dlSidecar') === false, '开关只在统一入口判断（saveLocalLrc 自己不重复判）')
ok(hasIn('fetchCover', 'sidecarImgs'), 'fetchCover 先查本地封面表')
ok(hasIn('fetchCover', 'loadExtra'), 'fetchCover 的**联网**分支受 loadExtra 控制')
// ⭐ 顺序才是这个 bug 的全部要害，只验"函数里出现过 loadExtra"等于没验。
//    真机 qmlscene 里 apiGet 无 shell 会**在 apiSeq++ 之前**早退，
//    "有没有真的联网"在设备上根本没有对外痕迹，猴补 apiGet 也不行（QML function 只读）——
//    所以分支归属只能在这里断言。真机探针只留它测得了的那部分。
ok(/function fetchCover[\s\S]*?sidecarImgs[\s\S]*?coverUrl = "file:\/\/"[\s\S]*?return[\s\S]*?if \(!loadExtra\) return/.test(clean),
   'fetchCover：本地分支与 return 在 loadExtra 判据**之前**（否则关掉开关连本地封面也没了）')
ok(/function fetchLyric[\s\S]*?if \(fetchLocalLyric\(song\.file\)\) return[\s\S]*?if \(!loadExtra\) return/.test(clean),
   'fetchLyric：本地读到就 return，在 loadExtra 判据之前（同上）')
ok(hasIn('saveLocalLrc', 'scheduleLocalRescan'), '歌词落盘后触发重扫')
ok(hasIn('saveLocalCover', 'scheduleLocalRescan'), '封面落盘后触发重扫')
ok(/function fetchLocalLyric[\s\S]{0,900}return true/.test(clean), 'fetchLocalLyric 返回 true（fetchLyric 靠它决定要不要联网兜底）')
ok(hasIn('fetchLyric', 'fetchLocalLyric('), 'fetchLyric 走 fetchLocalLyric')
ok(/function fetchLyric[\s\S]{0,400}if \(fetchLocalLyric/.test(clean), 'fetchLyric：本地读到就 return，读不到继续联网')
ok(hasIn('deleteLocal', 'sidecarImgExts'), 'deleteLocal 一并删封面（两种扩展名都删，否则留孤儿文件）')
ok(hasIn('decorateLocal', 'sidecarImgs'), 'decorateLocal 贴 img 字段')
ok(hasIn('buildCoverCmd', 'imgExtForUrl'), 'buildCoverCmd 按 URL 推断扩展名（不写死 .jpg）')
ok(/function buildCoverCmd[\s\S]{0,900}test -s|\[ -s /.test(clean), 'buildCoverCmd 有非空校验（.part → mv）')
ok(hasIn('loadExtras', 'fetchCover') && hasIn('loadExtras', 'fetchLyric'),
   'loadExtras 统一分发（调用点不再写 if (loadExtra)）')
ok(clean.indexOf('if (loadExtra) { fetchCover(') < 0, '两处切歌调用点都不再用 if (loadExtra) 包住（会连本地封面一起关掉）')
ok(src.indexOf('dlSidecar      = get(') >= 0, 'dlSidecar 有持久化读')
ok(src.indexOf('put("dlSidecar"') >= 0, 'dlSidecar 有持久化写')
ok(src.indexOf('dlSidecar = true; sysMedia') >= 0, 'resetAll 重置 dlSidecar')
ok(src.indexOf('property bool   dlSidecar: true') >= 0, 'dlSidecar 默认开')
ok(clean.indexOf('sidecarRescanTimer') >= 0, 'sidecarRescanTimer 已声明')

console.log('--- D. 页面 ---')
const lp = fs.readFileSync(process.argv[2].replace(/main\.qml$/, 'pages/LocalPage.qml'), 'utf8')
ok(/rec\.hasLrc/.test(lp) && /rec\.img/.test(lp), '本地页副标题显示 [词]/[图] 标记')
const sp = fs.readFileSync(process.argv[2].replace(/main\.qml$/, 'pages/SettingsPage.qml'), 'utf8')
ok(/toggleDlSidecar/.test(sp), '设置页有「下载时附带」开关')
ok(/controller\.dlSidecar/.test(sp), '设置页开关绑定 dlSidecar')

console.log('--- E. 括号配平（只查本次改过的文件）---')
ok(stripLiterals(clean) !== -2, 'main.qml 引号全部闭合')
for (const [f, nm] of [['pages/LocalPage.qml', 'LocalPage'], ['pages/SettingsPage.qml', 'SettingsPage']]) {
    const t = fs.readFileSync(process.argv[2].replace(/main\.qml$/, f), 'utf8')
    const st = stripLiterals(t)
    ok(st !== -2, nm + ' 引号闭合')
    let d = 0
    for (const c of st) { if (c === '{') d++; else if (c === '}') d-- }
    ok(d === 0, nm + ' 花括号配平（差 ' + d + '）')
}

console.log('\npass=' + pass + ' bad=' + bad)
if (bad > 0) { console.error('FAIL ❌'); process.exit(1) }
console.log('PASS ✅ sidecar 源码断言全过')
JS
