#!/usr/bin/env node
// 复现「有翻译时歌词显示时序错乱」。
//
// 机制推断（先用真源码验证再下结论）：
//   main.qml:2915 把原文与翻译**拼成一个字符串**：merged = lyric + "\n" + tlyric
//   然后 parseLrc(merged) 解析出**两份**条目，各自带自己的时间戳，最后按 time 排序。
//   updateLyricIndex 取「最后一个 time <= pos」的条目（:1183-1186）。
//   ⇒ 同一时刻原文与翻译**同时命中**，谁被选中取决于**等时元素的排序结果**。
//   若 sort 对相等 time 不稳定（V8/旧引擎允许），选中的就会在两份之间来回跳。
const fs = require('fs')
const path = require('path')
const SRC = process.env.GD_MAIN_SRC
  || path.join(__dirname, '..', 'plugin', 'qml', 'main.qml')
const src = fs.readFileSync(SRC, 'utf8')

function extractFn(name) {
  const re = new RegExp('^\\s*function ' + name + '\\s*\\(', 'm')
  const m = re.exec(src)
  if (!m) throw new Error('找不到 ' + name)
  const open = src.indexOf('{', m.index)
  let d = 0, i = open, st = 'code', prev = ''
  const rx = (c) => c === '' || '(,=:[!&|?{};+-*%<>~^'.indexOf(c) >= 0
  for (; i < src.length; i++) {
    const c = src[i], n = src[i + 1]
    if (st === 'code') {
      if (c === '\n') continue
      if (c === '/' && n === '/') { st = 'lc'; i++; continue }
      if (c === "'") { st = 'sq'; continue }
      if (c === '"') { st = 'dq'; continue }
      if (c === '/' && rx(prev)) {
        let j = i + 1, inC = false
        for (; j < src.length; j++) { const dd = src[j]
          if (dd === '\\') { j++; continue }
          if (dd === '\n') break
          if (dd === '[') inC = true; else if (dd === ']') inC = false
          else if (dd === '/' && !inC) break }
        i = j; prev = 'x'; continue
      }
      if (c === '{') d++; else if (c === '}') { d--; if (d === 0) break }
      if (!/\s/.test(c)) prev = c
      continue
    }
    if (st === 'lc') { if (c === '\n') st = 'code'; continue }
    if (c === '\\') { i++; continue }
    if ((st === 'sq' && c === "'") || (st === 'dq' && c === '"')) { st = 'code'; prev = c }
  }
  return src.slice(m.index, i + 1)
}

const bodies = extractFn('mergeLrc') + '\n' + extractFn('parseLrc')
             + '\n' + extractFn('parseLrcFile') + '\n' + extractFn('updateLyricIndex')
function mk() {
  const o = { lyricLines: [], lyricIndex: -1, timePos: 0 }
  const f = new Function('scope', `with(scope){ ${bodies}
    return { mergeLrc: mergeLrc, parseLrc: parseLrc, parseLrcFile: parseLrcFile,
             updateLyricIndex: updateLyricIndex } }`)
  o.api = f(o)
  return o
}

let pass = 0, bad = 0
const ok = (c, l) => { if (c) { pass++; console.log('  [OK] ' + l) } else { bad++; console.log('  [XX] ' + l) } }

// 真实形态：GD/网易云返回的 lyric 与 tlyric 都是 LRC，时间戳**完全相同**
const LYR = [
  '[00:00.00] 作词 : 方文山',
  '[00:12.00]一群嗜血的蚂蚁 被腐肉所吸引',
  '[00:16.50]我面无表情 看孤独的风景',
  '[00:21.00]失去你 爱恨开始分明'
].join('\n')
const TLY = [
  '[00:12.00]A swarm of bloodthirsty ants attracted by rotten flesh',
  '[00:16.50]I look expressionless at the lonely scenery',
  '[00:21.00]Losing you, love and hate begin to be distinct'
].join('\n')

console.log('=== 1. 新实现：翻译挂到原文上（不是并列条目）===')
const s = mk()
s.lyricLines = s.api.mergeLrc(LYR, TLY)
console.log('  解析出 ' + s.lyricLines.length + ' 条（旧实现是 7 条：原文 4 + 翻译 3）')
s.lyricLines.forEach((l, i) => console.log('    [' + i + '] t=' + l.time
  + '  原文="' + l.text.slice(0, 26) + '"  译文=' + (l.trans ? '"' + l.trans.slice(0, 26) + '…"' : '(无)')))
ok(s.lyricLines.length === 4, '条数 = 原文条数（实测 ' + s.lyricLines.length + '，旧实现 7）')
ok(s.lyricLines.every(l => l.text.length > 0), '每条都有原文')
ok(s.lyricLines.filter(l => l.trans && l.trans.length).length === 3, '3 条带翻译')

console.log('')
console.log('=== 2. 同一时刻不再有两条（旧实现的根源）===')
const byTime = {}
s.lyricLines.forEach(l => { byTime[l.time] = (byTime[l.time] || 0) + 1 })
const dup = Object.keys(byTime).filter(t => byTime[t] > 1)
console.log('  时间戳重复处: ' + (dup.length ? dup.join(', ') : '(无)'))
ok(dup.length === 0, '时间戳唯一 ⇒ 索引不会在原文/翻译之间选错')

console.log('')
console.log('=== 3. 00:12 处选中谁（旧实现选中了翻译）===')
s.timePos = 12.0
s.api.updateLyricIndex()
const picked = s.lyricLines[s.lyricIndex]
console.log('  lyricIndex=' + s.lyricIndex + '  原文: "' + picked.text.slice(0, 30) + '"')
console.log('                       译文: "' + (picked.trans || '').slice(0, 30) + '"')
ok(picked.text.indexOf('一群嗜血') >= 0, '选中原文（旧实现选中翻译）')
ok(picked.trans.indexOf('swarm') >= 0, '翻译与原文成对挂在同一条上')

console.log('')
console.log('=== 4. 下一句（面板预览用 index+1）===')
const nxt = s.lyricLines[s.lyricIndex + 1]
console.log('  下一句原文: "' + nxt.text.slice(0, 30) + '"')
console.log('  下一句译文: "' + (nxt.trans || '').slice(0, 30) + '"')
ok(nxt.text.indexOf('我面无表情') >= 0, '下一句是**下一句的原文**（旧实现这里配的是上一句翻译）')
ok(nxt.trans.indexOf('expressionless') >= 0, '下一句的翻译也是对应的')

console.log('')
console.log('=== 5. 本地 .lrc 文件（原文与翻译拼在一起存，同时间戳出现两次）===')
const fileTxt = LYR + '\n' + TLY
const f2 = mk()
f2.lyricLines = f2.api.parseLrcFile(fileTxt)
console.log('  parseLrcFile 得到 ' + f2.lyricLines.length + ' 条')
f2.lyricLines.forEach((l, i) => console.log('    [' + i + '] t=' + l.time
  + '  原文="' + l.text.slice(0, 20) + '"  译文=' + (l.trans ? '"' + l.trans.slice(0, 20) + '…"' : '(无)')))
ok(f2.lyricLines.length === 4, '本地文件也还原成 4 条（实测 ' + f2.lyricLines.length + '）')
ok(f2.lyricLines.filter(l => l.trans && l.trans.length).length === 3,
   '本地文件里的翻译被正确识别为翻译')
// 关键：不能把翻译当成原文
const at12 = f2.lyricLines.filter(l => Math.abs(l.time - 12) < 0.01)[0]
ok(at12 && at12.text.indexOf('一群嗜血') >= 0 && at12.trans.indexOf('swarm') >= 0,
   '本地文件：00:12 的原文/翻译配对正确')

console.log('')
console.log('=== 6. 边界：只有原文（无翻译）===')
const f3 = mk()
const only = f3.api.mergeLrc(LYR, '')
ok(only.length === 4, '只有原文时 4 条')
ok(only.every(l => !l.trans || l.trans === ''), '所有 trans 为空 ⇒ 渲染层不会显示空翻译行')

console.log('')
console.log('=== 7. 边界：翻译里有原文没有的时间戳（孤儿翻译）===')
const TLY_EXTRA = TLY + '\n[00:30.00]这是原文没有的一句翻译'
const f4 = mk()
const g = f4.api.mergeLrc(LYR, TLY_EXTRA)
ok(g.length === 4, '孤儿翻译不进入列表（实测 ' + g.length + '，应为 4）')
ok(g.every(l => l.text.indexOf('原文没有') < 0), '孤儿翻译没有混进原文')

console.log('')
console.log('=== 8. 边界：完全没歌词 ===')
const f5 = mk()
ok(f5.api.mergeLrc('', '').length === 0, '空输入返回空数组')
ok(f5.api.mergeLrc('', TLY).length === 0, '只有翻译没有原文 ⇒ 返回空（无处可挂）')

console.log('')
if (bad) { console.log('  ' + pass + ' 项通过, bad=' + bad); process.exit(1) }
console.log('  ' + pass + ' 项通过')
