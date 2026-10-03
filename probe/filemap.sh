#!/bin/bash
# 验证「文件登记表」(fileMap) —— 拿 main.qml 的真源码求值后断言。
#
# 沿用 preferlocal.sh 的套路：**不喂假数据，而是把真源码抠出来求值**。
# 因为这类功能最容易坏的形态有两种，假数据探针一种都测不出来：
#   ① 函数写了但没接上线（逻辑测试全绿、功能却没有）
#   ② 新文件（MatchPage.qml）没登记进 qmldir / 没被 LocalPage 引用
# 所以最后一组是同类的**接线断言**，直接查函数体和文件是否存在。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
LOCALPAGE="$ROOT/plugin/qml/pages/LocalPage.qml"
MATCHPAGE="$ROOT/plugin/qml/pages/MatchPage.qml"
QMLDIR="$ROOT/plugin/qml/qmldir"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
for f in "$QML" "$LOCALPAGE" "$MATCHPAGE" "$QMLDIR"; do
    [ -f "$f" ] || { echo "找不到 $f"; exit 1; }
done

"$NODE" - "$QML" "$LOCALPAGE" "$QMLDIR" <<'JS'
'use strict'
const fs = require('fs')
const [qmlPath, localPagePath, qmldirPath] = process.argv.slice(2)
const src = fs.readFileSync(qmlPath, 'utf8')
const localPageSrc = fs.readFileSync(localPagePath, 'utf8')
const qmldirSrc = fs.readFileSync(qmldirPath, 'utf8')

// 去掉整行注释：注释里的花括号会把下面的「括号配平」截取法带偏。
const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')

function die(msg) { console.error('FAIL ❌ ' + msg); process.exit(1) }

function grab(name, text) {
    const s = text === undefined ? clean : text
    const i = s.indexOf('function ' + name)
    if (i < 0) die('找不到 function ' + name)
    let depth = 0, k = s.indexOf('{', i)
    if (k < 0) die(name + ' 找不到函数体')
    for (; k < s.length; k++) {
        const c = s[k]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) break }
    }
    if (depth !== 0) die(name + ' 花括号未配平，截取失败')
    return s.slice(i, k + 1)
}

const md = src.match(/readonly property string downloadDir:\s*"([^"]+)"/)
if (!md) die('读不到 downloadDir')
const D = md[1]

const body = ['sanitizeName', 'localNameFor', 'localPathFor',
              'songKeyOf', 'mappedPathFor', 'mapEntryOf', 'mapPut', 'mapRemove',
              'gcFileMap', 'decorateLocal', 'findLocal', 'resolveEntry',
              // sidecar 段（2026-10-02）：decorateLocal 开始读这两个表来贴 [词]/[图]。
              // 必须一并抠进来 + 在下面的桩环境里声明，否则求值直接 ReferenceError ——
              // 症状是"探针坏了"而不是"实现坏了"，很容易误判成回归。
              'sidecarBase']
    .map(n => grab(n)).join('\n\n')

// 用与 main.qml 同名的自由变量承载属性，函数闭包才能读到。
// saveFileMap 用桩替换（真实现要 SQLite），并计数以便断言"确实落盘了"。
const api = new Function(`
var downloadDir = ${JSON.stringify(D)};
var source = "netease";
var localList = [];
var fileMap = ({});
var preferLocal = true;
var minLocalBytes = 65536;
var saveCount = 0;
var saveFileMap = function () { saveCount++ };
// sidecar 表：本探针不测 sidecar 本身（那是 sidecar.sh / sidecar-e2e.sh 的活），
// 这里给空表让 decorateLocal 走"没有附件"分支 —— 本探针只关心徽标/真名/登记表。
var sidecarImgs = ({});
var sidecarLrcs = ({});
${body}
return {
  findLocal: findLocal,
  resolveEntry: resolveEntry,
  mapPut: mapPut,
  mapRemove: mapRemove,
  mappedPathFor: mappedPathFor,
  mapEntryOf: mapEntryOf,
  gcFileMap: gcFileMap,
  decorateLocal: decorateLocal,
  songKeyOf: songKeyOf,
  localPathFor: localPathFor,
  setList:    function (l) { localList = l },
  getList:    function () { return localList },
  setMap:     function (m) { fileMap = m },
  getMap:     function () { return fileMap },
  saves:      function () { return saveCount }
};
`)()
const { findLocal, resolveEntry, mapPut, mapRemove, mappedPathFor, mapEntryOf,
        gcFileMap, decorateLocal, songKeyOf, localPathFor } = api

let pass = 0, bad = 0
function ok(cond, label) {
    if (cond) { pass++; console.log('  ✅ ' + label) }
    else { bad++; console.log('  ❌ ' + label) }
}

const ONLINE = { id: '1997293311', source: 'netease', name: '断气', artist: '回春丹',
                 pic_id: '109951173449168898' }
const NORMAL = D + '/断气-回春丹.mp3'      // 按公式算出来的名字（精确路径能命中）
const RENAMED = D + '/断气 - 回春丹 (Live).mp3'  // 用户改过名（公式命中不了）

console.log('--- ① 精确路径优先（原有行为不能坏） ---')
api.setMap({})
api.setList([{ file: NORMAL, size: 11735293 }])
ok(findLocal(ONLINE) && findLocal(ONLINE).file === NORMAL, '按公式命名 → 命中')
ok(localPathFor(ONLINE) === NORMAL, '公式本身没变')

console.log('--- ② 登记表兜底：改过名 / 别的工具下的也能命中 ---')
api.setMap({})
api.setList([{ file: RENAMED, size: 11735293 }])
ok(findLocal(ONLINE) === null, '没登记时：改过名的命中不了（这是原状）')
api.setMap({ [RENAMED]: { id: '1997293311', source: 'netease', name: '断气',
                          artist: '回春丹', m: 'manual', t: 100 } })
ok(findLocal(ONLINE) && findLocal(ONLINE).file === RENAMED, '登记后 → 命中改过名的文件')

console.log('--- ③ 两级优先级：公式命中 > 登记表 ---')
api.setList([{ file: NORMAL, size: 111 }, { file: RENAMED, size: 222 }])
api.setMap({ [RENAMED]: { id: '1997293311', source: 'netease', t: 999 } })
ok(findLocal(ONLINE).file === NORMAL, '两者都在时取公式命中的那个（置信度更高）')

console.log('--- ④ 悬空登记绝不命中（宁可判未匹配，也不能去播不存在的文件）---')
// 先把 localList 换成"公式也命中不了"的内容，否则上一段留下的 NORMAL 会被
// 精确路径那一级先命中，这条断言就测不到登记表的悬空行为了。
api.setList([{ file: D + '/别的歌-别人.mp3', size: 100 }])
api.setMap({ [D + '/已删除的文件.mp3']:
             { id: '1997293311', source: 'netease', t: 999 } })
ok(findLocal(ONLINE) === null, '表里有、磁盘上没有 → 判未匹配')
ok(mappedPathFor(ONLINE) === D + '/已删除的文件.mp3',
   'mappedPathFor 仍返回表里的路径（求交的责任在 findLocal）')
ok(mapEntryOf({ file: D + '/不在列表里.mp3' }) === null, 'mapEntryOf 与 localList 求交')

console.log('--- ⑤ mappedPathFor：同 key 多文件取最新 ---')
api.setMap({
  [D + '/旧.mp3']: { id: '1', source: 'netease', t: 100 },
  [D + '/新.mp3']: { id: '1', source: 'netease', t: 200 }
})
ok(mappedPathFor({ id: '1', source: 'netease' }) === D + '/新.mp3', 't 大的胜出')
ok(mappedPathFor({ id: '1', source: 'kugou' }) === '', 'source 不同不算同一首')
ok(mappedPathFor({ name: '没有 id' }) === '', '无 id → 返回空串（不误命中）')
ok(mappedPathFor(null) === '', 'null 不炸')

console.log('--- ⑥ mapPut / mapRemove 的形状与落盘 ---')
api.setMap({})
const before = api.saves()
mapPut(RENAMED, ONLINE, 'manual')
const e = api.getMap()[RENAMED]
ok(!!e, '写进去了')
ok(e.id === '1997293311' && e.source === 'netease', 'id / source 正确')
ok(e.name === '断气' && e.artist === '回春丹', '歌名 / 歌手正确')
ok(e.pic_id === '109951173449168898', 'pic_id 带上（本地条目播放能有封面）')
ok(e.lyric_id === '1997293311', 'lyric_id 缺省回落到 id')
ok(e.m === 'manual' && typeof e.t === 'number' && e.t > 0, '来源标记与时间戳')
ok(api.saves() === before + 1, 'mapPut 落盘一次')
mapPut(D + '/x.mp3', ONLINE, 'auto')
ok(api.getMap()[D + '/x.mp3'].m === 'auto', 'mode="auto" 被记录')
mapPut(D + '/y.mp3', { name: '没有 id 的歌' }, 'manual')
ok(api.getMap()[D + '/y.mp3'] === undefined, '无 id 的条目被拒绝（否则反查会误命中）')
mapPut('', ONLINE, 'manual')
ok(api.getMap()[''] === undefined, '空路径被拒绝')
mapRemove(RENAMED)
ok(api.getMap()[RENAMED] === undefined, 'mapRemove 删掉了')
const saved2 = api.saves()
mapRemove(RENAMED)
ok(api.saves() === saved2, '删不存在的条目不白写一次库')

console.log('--- ⑦ gcFileMap：只清悬空的，且空列表时不动手 ---')
api.setMap({
  [NORMAL]:  { id: '1', source: 'netease', t: 1 },
  [RENAMED]: { id: '2', source: 'netease', t: 1 }
})
api.setList([{ file: NORMAL, size: 10 }])
gcFileMap()
ok(api.getMap()[NORMAL] !== undefined, '文件还在 → 保留')
ok(api.getMap()[RENAMED] === undefined, '文件没了 → 清掉')
// ⚠️ 关键边界：localList 为空时既可能是"文件夹真的空了"，也可能是"扫描挂了"，
//    两者输出无法区分 ⇒ 必须不动手，否则一次扫描失败就清空整张表。
api.setMap({ [NORMAL]: { id: '1', source: 'netease', t: 1 } })
api.setList([])
gcFileMap()
ok(api.getMap()[NORMAL] !== undefined, 'localList 为空 → 一条都不清（区分不了空文件夹/扫描失败）')

console.log('--- ⑧ decorateLocal：贴徽标 + 用真名覆盖文件名反推名 ---')
api.setMap({ [NORMAL]: { id: '1', source: 'netease', name: '断气（真名）',
                         artist: '回春丹', m: 'auto', t: 1 } })
const raw = [{ file: NORMAL, size: 11735293, name: '断气', artist: '回春丹',
               id: NORMAL, matched: false }]
api.setList(raw)
decorateLocal()
const d0 = api.getList()[0]
ok(d0.matched === true, '已登记的 → matched=true（徽标 ✓）')
ok(d0.name === '断气（真名）', '真名覆盖从文件名反推的名')
ok(d0.mapMode === 'auto', '带上来源标记')
ok(d0.size === 11735293 && d0.file === NORMAL, 'size / file 等原有字段没丢')
ok(raw[0].name === '断气', '纯拷贝：没改动传进来的原对象')
api.setList([{ file: RENAMED, size: 10, name: 'x' }])
decorateLocal()
ok(api.getList()[0].matched === false, '没登记的 → matched=false（徽标 ?）')

console.log('--- ⑨ 与 preferLocal 联动：登记过的歌才不会白下 ---')
api.setMap({ [RENAMED]: { id: '1997293311', source: 'netease', name: '断气',
                          artist: '回春丹', m: 'manual', t: 1 } })
api.setList([{ file: RENAMED, size: 11735293 }])
const r = resolveEntry(ONLINE)
ok(r.file === RENAMED, '在线条目 → 补上本地 file（走登记表）')
ok(r.id === '1997293311' && r.pic_id === '109951173449168898',
   '在线字段保留（封面仍联网取、歌词落本地 .lrc）')
api.setList([{ file: RENAMED, size: 1024 }])
ok(resolveEntry(ONLINE).file === undefined, '半截文件仍不认（登记表不绕过 64KB 门槛）')

console.log('--- ⑩ 接线断言（防止"函数写了却没接上"）---')
const dl = grab('dlFinish')
ok(/mapPut\s*\(/.test(dl), 'dlFinish 里确实登记了（下载即自动登记）')
ok(/"auto"/.test(dl), '登记用的是 mode="auto"')
ok(/if\s*\(ok\s*&&/.test(dl), '只在下载成功时登记（失败时文件根本没进歌曲文件夹）')

const fl = grab('findLocal')
ok(/mappedPathFor\s*\(/.test(fl), 'findLocal 里确实用了登记表反查')
ok(/localPathFor\s*\(/.test(fl), 'findLocal 仍保留精确路径那一级')

const rl = grab('refreshLocal')
ok(/gcFileMap\s*\(/.test(rl), 'refreshLocal 会做惰性 GC')
ok(/decorateLocal\s*\(/.test(rl), 'refreshLocal 会做装饰（徽标/真名）')
ok(rl.indexOf('gcFileMap') < rl.indexOf('decorateLocal'),
   'GC 在装饰之前（顺序反了会把刚删掉的条目又贴上去）')

ok(/"filemap"/.test(grab('loadSettings')), 'loadSettings 读的是 "filemap" 这个 key')
ok(/"filemap"/.test(grab('saveFileMap')), 'saveFileMap 写的是同一个 key')
ok(/mapRemove\s*\(/.test(grab('deleteLocal')), 'deleteLocal 顺手清登记（rm 是异步的，GC 靠不住）')
ok(/mapEntryOf\s*\(/.test(grab('playLocal')), 'playLocal 用登记信息补 source/pic_id')
ok(/"match"/.test(clean), '键盘回调里有 "match" 这一支（匹配页搜索框复用宿主键盘）')

console.log('--- ⑪ 新文件必须真的存在且被登记（踩过：新增文件没进 qmldir）---')
ok(/openMatch\s*\(/.test(localPageSrc), 'LocalPage 调用了 openMatch（徽标是入口）')
ok(/rec\.matched/.test(localPageSrc), 'LocalPage 显示 matched 徽标')
ok(/MatchPage 1\.0 pages\/MatchPage\.qml/.test(qmldirSrc), 'qmldir 登记了 MatchPage')
ok(/Pages\.MatchPage\s*\{/.test(clean), 'main.qml 实例化了 Pages.MatchPage')
ok(/page\s*===\s*"match"/.test(clean), 'MatchPage 的 visible 绑在 page === "match"')
ok(/backPage\s*=\s*"local"/.test(grab('openMatch')), 'openMatch 记住返回目标是本地页')
ok(/page\s*=\s*"match"/.test(grab('openMatch')), 'openMatch 真的切到匹配页')
ok(/page\s*=\s*"local"/.test(grab('closeMatch')), 'closeMatch 回本地页')
ok(/refreshLocal\s*\(/.test(grab('bindMatch')), '绑定后刷新本地页（徽标立刻变）')
ok(/mapPut\s*\(/.test(grab('bindMatch')), 'bindMatch 写的是登记表')
ok(/refreshLocal\s*\(/.test(grab('clearMatch')), '清除后也刷新')

console.log('')
if (bad) { console.log('FAIL ❌ ' + bad + " 项未通过（通过 " + pass + '）'); process.exit(1) }
console.log('PASS ✅ 全部 ' + pass + ' 项通过')
JS
