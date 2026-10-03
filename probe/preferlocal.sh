#!/bin/bash
# 验证「已下载优先」(preferLocal) —— **拿 main.qml 的真源码**求值 resolveEntry() 再断言。
#
# 为什么不用 qmlscene 探针喂假数据：
#   上次「本地页没歌」的教训是「假数据只测解析，测不到拼接」。这里同理 ——
#   如果只测 resolveEntry() 本身的逻辑，那么**有人把它从 queueJsonString 里摘掉**
#   （函数还在、测试全绿、功能却没了）这种错误完全测不出来。
#   所以最后一组断言是**接线断言**：直接在 queueJsonString 的函数体里找 resolveEntry(。
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

// 去掉整行注释：注释里的花括号会把下面的「括号配平」截取法带偏。
// 只匹配行首的 //，所以字符串里的 https://... 不会被误伤。
const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')

function die(msg) { console.error('FAIL ❌ ' + msg); process.exit(1) }

// 按花括号配平截取一个函数的完整源码（比 indexOf('\n    }') 稳：
// 单行函数如 localPathFor 用后者会把后面整个函数一起吞进来）
function grab(name) {
    const i = clean.indexOf('function ' + name)
    if (i < 0) die('main.qml 里找不到 function ' + name)
    let depth = 0, k = clean.indexOf('{', i)
    if (k < 0) die(name + ' 找不到函数体')
    for (; k < clean.length; k++) {
        const c = clean[k]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) break }
    }
    if (depth !== 0) die(name + ' 花括号未配平，截取失败')
    return clean.slice(i, k + 1)
}

// downloadDir 从源码读，避免脚本和实现各说各话
const md = src.match(/readonly property string downloadDir:\s*"([^"]+)"/)
if (!md) die('读不到 downloadDir')
const D = md[1]

const body = ['sanitizeName', 'localNameFor', 'localPathFor',
              'songKeyOf', 'mappedPathFor', 'findLocal', 'resolveEntry']
    .map(grab).join('\n\n')

// 用与 main.qml 同名的自由变量承载属性，函数闭包才能读到。
// fileMap 是「文件登记表」（P0.5 加的）：findLocal 现在两级查找，第二级要读它 ——
// 这里给空表，第一级（精确路径）的行为就与加表之前完全一致，下面仍可断言原语义。
const api = new Function(`
var downloadDir = ${JSON.stringify(D)};
var preferLocal = true;
var minLocalBytes = 65536;
var localList = [];
var fileMap = ({});
var source = "netease";
${body}
return {
  resolveEntry: resolveEntry,
  localNameFor: localNameFor,
  localPathFor: localPathFor,
  setList:   function (l) { localList = l },
  setMap:    function (m) { fileMap = m },
  setPrefer: function (v) { preferLocal = v }
};
`)()

let pass = 0, bad = 0
function ok(cond, label) {
    if (cond) { pass++; console.log('  ✅ ' + label) }
    else { bad++; console.log('  ❌ ' + label) }
}

const ONLINE = { id: '1997293311', source: 'netease', name: '断气', artist: '回春丹',
                 pic_id: '109951173449168898', lyric_id: '1997293311' }
const REC = { file: D + '/断气-回春丹.mp3', size: 11735293, name: '断气', artist: '回春丹' }

console.log('--- 命中：给在线条目补 file，且不丢在线字段 ---')
api.setList([REC]); api.setPrefer(true)
const r1 = api.resolveEntry(ONLINE)
ok(r1.file === REC.file, '命中 → 补上 file 字段')
ok(r1.id === '1997293311' && r1.source === 'netease', 'id / source 保留')
ok(r1.pic_id === '109951173449168898' && r1.lyric_id === '1997293311',
   'pic_id / lyric_id 保留（封面不断链、歌词照样落本地 .lrc）')
ok(r1.name === '断气' && r1.artist === '回春丹', '歌名 / 歌手保留')
ok(ONLINE.file === undefined, '纯函数：传进去的原对象没被改动')
ok(r1 !== ONLINE, '命中时返回的是新对象')

console.log('--- 未命中 / 已是本地 ---')
const MISS = { id: '1', source: 'netease', name: '没有这首歌', artist: 'X' }
ok(api.resolveEntry(MISS) === MISS, '未命中 → 原样返回同一个引用（不做无谓拷贝）')
const LOCAL = { file: D + '/a.mp3', name: 'a' }
ok(api.resolveEntry(LOCAL) === LOCAL, '已经是本地条目 → 原样返回')

console.log('--- 半截/坏文件不算命中 ---')
api.setList([{ file: REC.file, size: 1024 }])
ok(api.resolveEntry(ONLINE).file === undefined, '1KB（下坏了）→ 不认，回退网络')
api.setList([{ file: REC.file, size: 65536 }])
ok(api.resolveEntry(ONLINE).file === REC.file, '边界：正好 64KB → 认')
api.setList([{ file: REC.file }])
ok(api.resolveEntry(ONLINE).file === undefined, 'size 缺失 → 不认（宁走网络也不赌）')

console.log('--- 开关 ---')
api.setList([REC]); api.setPrefer(false)
ok(api.resolveEntry(ONLINE).file === undefined, 'preferLocal=false → 完全不生效')
api.setPrefer(true)

console.log('--- 文件名公式必须与下载时同源 ---')
const MULTI = { id: '9', source: 'netease', name: '歌名', artist: 'A,B' }
api.setList([{ file: D + '/歌名-A、B.mp3', size: 999999 }])
ok(api.localNameFor(MULTI) === '歌名-A、B.mp3', '多歌手：逗号在文件名里写成「、」')
ok(api.resolveEntry(MULTI).file === D + '/歌名-A、B.mp3', '匹配用的是同一个公式 ⇒ 能命中')
api.setList([{ file: D + '/a_b-c.mp3', size: 999999 }])
ok(api.resolveEntry({ id: '7', name: 'a/b', artist: 'c' }).file === D + '/a_b-c.mp3',
   '歌名里的 / 被 sanitize 成 _（带 artist，避开下面那条已知缺陷）')

// ⚠️ 已知缺陷（**不是本功能引入的**，属 localNameFor 原有行为）：
//    sanitizeName("") 返回 "untitled" 而不是空串，于是「无歌手」的歌文件名是
//    「歌名-untitled.mp3」。下载与匹配同源，所以不影响 prefer-local 命中；
//    但别的工具下的 / 被改过名的「歌名.mp3」匹配不上。
//    这里断言的是**当前实际行为** —— 将来若修掉它，这条会变红，正好提醒同步。
ok(api.localNameFor({ name: '纯音乐' }) === '纯音乐-untitled.mp3',
   '⚠️ 已知缺陷：无歌手 → 「纯音乐-untitled.mp3」（而非「纯音乐.mp3」）')

console.log('--- 与文件登记表（fileMap）联动 ---')
// P0.5 之后 findLocal 是两级查找：公式算出的精确路径 → 登记表反查。
// 这一组锁住"第二级真的接上了"，否则上面那些公式类断言即使全绿也说明不了实际问题。
const RENAMED = D + '/断气 - 回春丹 (Live).mp3'
api.setList([{ file: RENAMED, size: 999999 }]); api.setPrefer(true)
api.setMap({})
ok(api.resolveEntry(ONLINE).file === undefined, '未登记 → 改过名的不命中（老实回退网络）')
api.setMap({ [RENAMED]: { id: '1997293311', source: 'netease', t: 1 } })
ok(api.resolveEntry(ONLINE).file === RENAMED, '登记后 → 命中（补上公式覆盖不了的盲区）')
api.setMap({ [RENAMED]: { id: '1', source: 'netease', t: 1 } })
ok(api.resolveEntry(ONLINE).file === undefined, '登记的是别的 id → 不误命中')
api.setMap({})

console.log('--- 健壮性 ---')
ok(api.resolveEntry(null) === null, 'null 不炸')
ok(api.resolveEntry(undefined) === undefined, 'undefined 不炸')
ok(api.resolveEntry({}).file === undefined, '空对象不炸')
ok(api.resolveEntry({ name: 'x' }).file === undefined, '只有歌名、无 id → 不炸')

console.log('--- 接线断言（防止"函数写了却没接上"）---')
const qi = clean.indexOf('function queueJsonString')
if (qi < 0) die('找不到 queueJsonString')
let d2 = 0, k2 = clean.indexOf('{', qi), kk = k2
for (; kk < clean.length; kk++) {
    const c = clean[kk]
    if (c === '{') d2++
    else if (c === '}') { d2--; if (d2 === 0) break }
}
const qbody = clean.slice(qi, kk + 1)
ok(/resolveEntry\s*\(/.test(qbody), 'queueJsonString 里确实调用了 resolveEntry')
ok(!/\blist:\s*queue\b/.test(qbody), 'queueJsonString 不再直接塞原始 queue')

console.log('')
if (bad) { console.log('FAIL ❌ ' + bad + " 项未通过（通过 " + pass + '）'); process.exit(1) }
console.log('PASS ✅ 全部 ' + pass + ' 项通过')
JS
