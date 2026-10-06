#!/usr/bin/env node
// qml-dupdecl.js 的自检 —— 用合成夹具证明它「能抓到」且「不误报」。
//
// 2026-10-05 加。理由：门禁的价值全在"抓到真事故"，而它上一版**漏检了事故文件
// MediaBridge.qml 本身**（deploy.sh 只喂了 main + pages + components）。
// 一个从没被验证过的检查器，它的"全绿"没有意义 —— 因为全绿和"根本没跑"输出一样。
// 这里把 4 类真实事故形态做成夹具，钉死行为。
//
// 用法：node tools/test-qml-dupdecl.js
'use strict'
const fs = require('fs')
const os = require('os')
const path = require('path')
// ⚠️ 本机（2026-10-04 查清）由 Node 启动的进程里，`execFileSync` / `spawnSync`
// 一律返回 EBUSY、stdout 为空 —— 同步等待子进程那条路径在本机被拦住了，异步 spawn 正常。
// 所以这里用 promisify(execFile)。⛔ 别改回 execFileSync：那会让**全部断言恒红**，
// 而且症状是"实测："后面一片空白，看起来像检查器坏了，实际是根本没跑起来。
const { execFile } = require('child_process')
const { promisify } = require('util')
const execFileAsync = promisify(execFile)

const CHECKER = path.join(__dirname, 'qml-dupdecl.js')
let pass = 0, bad = 0
function ok(c, label) {
  if (c) { pass++; console.log('  ✅ ' + label) }
  else { bad++; console.log('  ❌ ' + label) }
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dupdecl-'))
async function run(src, name) {
  const f = path.join(dir, name)
  fs.writeFileSync(f, src, 'utf8')
  let out = '', code = 0
  try {
    const r = await execFileAsync(process.execPath, [CHECKER, f], { encoding: 'utf8' })
    out = r.stdout || ''
  } catch (e) {
    out = (e.stdout || '') + (e.stderr || '')
    // 异步 execFile 的退出码在 e.**code**（同步版是 e.status）—— 写错就恒为 -1。
    code = (typeof e.code === 'number') ? e.code : -1
  }
  return { out, code }
}

// 与 run() 同签名，但**不预建文件** —— 用于测"参数写错"的路径（字面量通配符、
// 不存在的文件）。这两种情况检查器该人话报错，绝不该先崩在 fs 上。
async function runRaw(args) {
  let out = '', code = 0
  try {
    const r = await execFileAsync(process.execPath, [CHECKER, ...args], { encoding: 'utf8' })
    out = r.stdout || ''
  } catch (e) {
    out = (e.stdout || '') + (e.stderr || '')
    code = (typeof e.code === 'number') ? e.code : -1
  }
  return { out, code }
}

// 主体包在 async 函数里：CJS 不支持 top-level await，而本机又不能用 execFileSync。
// （下面的缩进保持夹具原样，仅为容纳 wrapper 而无谓重排反而容易改错。）
async function main() {
console.log('=== 1. 必须抓到：同层重复 property（2026-10-03 事故形态）===')
{
  // 行号：1=Item{ 2=首个 ncQrFile 3=a 4=空行 5=function 6=第二个 ncQrFile
  const r = await run('Item {\n    property string ncQrFile: ""\n    property string a: "b"\n\n    function f() {}\n    property string ncQrFile: ""\n}\n', 'dup.qml')
  ok(r.code === 1, '退出码为 1（门禁能中止 deploy）')
  ok(/第 6 行/.test(r.out), '报出第二次声明所在的第 6 行，实测：' + (r.out.match(/第 \d+ 行/g) || []).join(','))
  ok(/第 2 行/.test(r.out), '并指出首次声明在第 2 行，实测：' + (r.out.match(/第 \d+ 行/g) || []).join(','))
  ok(/ncQrFile/.test(r.out), '点名了 ncQrFile')
}

console.log('=== 2. 必须抓到：default / required 限定词（2026-10-05 修的盲区）===')
{
  const r = await run('Item {\n    default property alias content: children\n    default property alias content: inner\n}\n', 'dupdef.qml')
  ok(r.code === 1, 'default property alias 重复 -> 退出码 1（旧版会漏）')
  ok(/第 3 行/.test(r.out), '报出第 3 行，实测：' + (r.out.match(/第 \d+ 行/g) || []).join(','))
}
{
  const r = await run('Item {\n    required property int currentIndex: 0\n    required property int currentIndex: 1\n}\n', 'dupreq.qml')
  ok(r.code === 1, 'required property 重复 -> 退出码 1（旧版会漏）')
}
{
  const r = await run('Item {\n    property alias content: children\n    property alias content: inner\n}\n', 'dupalias.qml')
  ok(r.code === 1, 'property alias 重复 -> 退出码 1')
}

console.log('=== 3. 必须不误报：Connections 里的 onXxx handler ===')
console.log('    （MediaBridge.qml:672-680 的真实形态 —— 名字与根对象方法相同但层级不同）')
{
  const r = await run('Item {\n    property Connections links: Connections {\n        function onPlayRequested() { root.onPlayRequested() }\n        function onPauseRequested() { root.onPauseRequested() }\n    }\n\n    function onPlayRequested() {}\n    function onPauseRequested() {}\n}\n', 'conn.qml')
  ok(r.code === 0, 'Connections handler 与根对象同名方法共存 -> 绿（实测 bad=' + (r.out.match(/bad=(\d+)/) || [])[1] + '）')
}

console.log('=== 4. 必须不误报：不同缩进层级的同名 property（合法：不同对象各自持有）===')
{
  const r = await run('Item {\n    property var a: 1\n    Item {\n        property var a: 2\n        Item {\n            property var a: 3\n        }\n    }\n}\n', 'nest.qml')
  ok(r.code === 0, '三层嵌套同名 property -> 绿')
}

console.log('=== 5. 缩进不一致 -> 不再硬编码 4 空格，改成"按实际缩进分层" ===')
{
  // 旧版 `^ {4}` 硬编码 4 空格：有人把顶层写成 2 或 6 空格缩进时**整层漏检**。
  // 新版按实际缩进宽度分层，所以任意缩进下同层重复都能抓到。
  const r = await run('Item {\n  property string dup: "a"\n  property string dup: "b"\n}\n', 'indent2.qml')
  ok(r.code === 1, '2 空格缩进下的同层重复 -> 退出码 1（旧版 `^ {4}` 会漏）')
}
{
  const r = await run('Item {\n      property string dup: "a"\n      property string dup: "b"\n}\n', 'indent6.qml')
  ok(r.code === 1, '6 空格缩进下的同层重复 -> 退出码 1（旧版会漏）')
}
{
  // 但不同缩进 = 不同对象，**必须**放行，否则全是误报（见 MediaBridge 注释）
  const r = await run('Item {\n    property string dup: "a"\n      property string dup: "b"\n}\n', 'indentdiff.qml')
  ok(r.code === 0, '同文件不同缩进的同名 property -> 绿（按 QML 对象语义属两个对象）')
}

console.log('=== 6. 必须不误报：注释与字符串里的 property/id ===')
{
  const r = await run('// property string fake: ""\n    // id: fake\n    property string real: "x"\n', 'comment.qml')
  ok(r.code === 0, '注释行不触发 -> 绿')
}
{
  const r = await run('Item {\n    property string s: "property string fake: id: nope"\n}\n', 'str.qml')
  ok(r.code === 0, '字符串字面量里的内容不触发 -> 绿')
}

console.log('=== 7. id 重复仍然被抓（本次未改逻辑，防回归）===')
{
  // 检查器的 id 正则是 `^(\s*)id:\s*(\w+)\s*$` —— 只认**独占一行**的 id 声明
  const r = await run('Item {\n    Item {\n        id: dup\n    }\n    Item {\n        id: dup\n    }\n}\n', 'id.qml')
  ok(r.code === 1, '同层重复 id（独占行）-> 退出码 1')
}
{
  const r = await run('Item {\n    Item {\n        id: same\n    }\n    Column {\n        Item {\n            id: same\n        }\n    }\n}\n', 'idnest.qml')
  ok(r.code === 0, '不同层重复 id（合法）-> 绿')
}
{
  // ⚠️ 已知盲区（**未修**，如实记录）：行内写法 `Item { id: dup }` 不被捕获。
  // 本项目真实代码里这种写法存在（Toast.qml:44 `NumberAnimation { id: animIn; ... }`、
  // main.qml:3506 `Components.Toast { id: toast; parent: root }`），
  // 但全树逐条核对**无一处行内 id 重复**（2026-10-05 实测 bad=0）。
  // 修它需要解析 `{...}` 配对来还原层级 —— 那就跨进了"靠启发式猜语义"的红线，
  // 与本文件头注释的既定教训相悖。**保持现状 + 留此记录**，而不是冒误报风险。
  const r = await run('Item {\n    Item { id: dup }\n    Item { id: dup }\n}\n', 'idinline.qml')
  ok(r.code === 0, '行内 id 重复仍不报（已知盲区，见上方注释；全树实测无此问题）')
}

console.log('=== 8. 坏输入必须与"检查结论"区分开（exit 2 ≠ exit 1）===')
{
  // 背景：Windows PowerShell 下 Node 不展开 glob，直接传 `foo/*.qml` 进来的是字面量，
  // fs.readFileSync 会 ENOENT 抛栈 —— 崩栈本身没有信息量，像"脚本坏了"而不是"参数给错"。
  // 2026-10-05 加了检测。**退出码必须是 2 不能是 1**：
  //   1 = 门禁正常拦下了重复声明（真信号）；2 = 根本没检查成功（坏输入）。
  // 两者混同 ⇒ CI 里一道红会被误读成"有 bug，去修"，实际是"参数写错了"。
  const r = await runRaw(['plugin/qml/*.qml'])
  ok(r.code === 2, '字面量通配符 -> 退出码 2（不是 1）')
  ok(/通配符/.test(r.out), '字面量通配符 -> 有人话提示（不是 ENOENT 崩栈）')
  ok(/Get-ChildItem/.test(r.out), '提示里附 PowerShell 正确写法')
  // ⚠️ 只检查"有没有崩栈"，**不能**连 ENOENT 一起查 —— 那句人话提示里本来就写着
  //    「会把它当字面文件名 → ENOENT」（那是解释，不是崩栈）。第一版夹具正是把解释
  //    当成了崩栈，恒红。教训：断言要盯生成物形态（`at ...` 栈帧），别盯关键词。
  ok(!/^\s+at\s+\S+/m.test(r.out), '没有 fs 崩栈堆栈')
}
{
  // 文件真不存在也要人话报错，同样 exit 2 —— 别让 fs 抛栈。
  const r = await runRaw([path.join(dir, 'nope.qml')])
  ok(r.code === 2, '文件不存在 -> 退出码 2')
  ok(/找不到文件/.test(r.out), '文件不存在 -> 有人话提示')
}
{
  // 防回归：正常路径的退出码不能被上面两条污染（1 仍然是"有重复声明"）。
  const r = await run('Item {\n    property string a: "1"\n    property string a: "2"\n}\n', 'code1.qml')
  ok(r.code === 1, '发现重复声明仍为退出码 1（与 exit 2 区分开）')
}

}

main().then(() => {
  console.log('')
  fs.rmSync(dir, { recursive: true, force: true })
  if (bad > 0) { console.log('files=0 bad=' + bad); process.exit(1) }
  console.log('  ' + pass + ' 项通过')
})
