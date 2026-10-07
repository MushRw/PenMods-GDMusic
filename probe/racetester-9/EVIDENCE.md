# task-9 真机测量证据（racetester）

设备：`2AB2900000800514`（`Linux YoudaoDictionaryPen-514 4.4.159 aarch64`，busybox 1.27.2，**4 核**）
所有数字均为**真机实测**，每条附命令与原始输出。标注为「推断」的另行说明。

---

## 0. 先说三条纠正任务前提的实测

### 0.1 `/tmp` 是 **tmpfs（RAM）**，不是 eMMC

```
$ adb shell "cat /proc/mounts | grep -E ' /tmp | /userdisk | / '"
/dev/root / ext4 rw,relatime,data=ordered 0 0
tmpfs /tmp tmpfs rw,relatime,size=230096k,nr_inodes=57524 0 0
/dev/mmcblk1p14 /userdisk ext4 rw,relatime,data=ordered 0 0

$ adb shell "df -h /tmp /userdisk"
tmpfs            225M  180K  225M   1% /tmp
/dev/mmcblk1p14  6.5G  4.0G  2.1G  66% /userdisk
```

而 `gdnext.lua:31` `local DIR = "/tmp/gdmusic"`、`:33` `NFILE = DIR.."/now.json"`，
`MediaBridge.qml:69` `nowFile = stateDir + "/now.json"`。

⇒ **now.json 落在 tmpfs（纯内存）上，不在 eMMC/flash 上。**
任务描述里「设备是 eMMC/tmpfs，肯定比本机 SSD 慢」的**前提不成立**——
now.json 这一路径根本不经 flash。

### 0.2 设备上**没有** lua / python；有 perl

```
$ adb shell 'for t in sh busybox perl python python3 lua luac awk sed dd cat od stat date head tail wc tr cmp gcc; do printf "%s=%s\n" "$t" "$(command -v $t 2>/dev/null)"; done'
sh=/bin/sh      busybox=/bin/busybox  perl=/usr/bin/perl  python=(空)  python3=(空)
lua=(空)  luac=(空)  awk=/usr/bin/awk  sed=/bin/sed  dd=/bin/dd  cat=/bin/cat
od=/usr/bin/od  stat=/usr/bin/stat  date=/bin/date  head=/usr/bin/head
tail=/usr/bin/tail  wc=/usr/bin/wc  tr=/usr/bin/tr  cmp=/usr/bin/cmp  gcc=(空)
```

⇒ 测量只能用 **busybox sh + perl**（perl 有 `Time::HiRes`，实测 `1791356087.63371`）。
`date +%N` 也给 ns（`372073733`），但 perl 的 `Time::HiRes::time()` 更省事。

### 0.3 部署件 == 仓库 HEAD（我测的是真代码，不是旧版）

```
$ adb shell "cmp -s /userdisk/.../bin/gdnext.lua /tmp/.../gdnext-deployed.lua && echo SAME || echo DIFF"
DIFF          # 与我自己拉的那份同名文件比，当然是 DIFF（无关）
$ Get-FileHash (repo plugin/bin/gdnext.lua)     -> 3104A4909324AC965BD9D6EBFA32D46DB7E0156F8CAA56B3280B0795E459AE43
$ Get-FileHash (pulled deployed gdnext.lua)     -> 3104A4909324AC965BD9D6EBFA32D46DB7E0156F8CAA56B3280B0795E459AE43
RESULT: deployed == repo HEAD
```

且部署版里确认：
- `:97` `local f = io.open(p, "w")` —— 截断式写，非原子
- `:222` `write_file(NFILE, "{" .. table.concat(parts, ",") .. "}")`
- `:516` `add_timer(1, function() ... write_now({}) end)` —— 每秒写

⚠️ 测量期间 `plugin/bin/gdnext.lua` 被 task-7 并发修改（526→562 行）。
我的所有测量都用**设备上部署的那份（== 当时的 repo HEAD）**，与 task-7 的新版无关。

---

## 1. 写窗口 W

被测语义（与 `gdnext.lua:96-102` 逐字对齐）：
`io.open(p,"w")` → `f:write(s)` → `f:close()`。
Lua 的 `io` 走 C stdio，默认**全缓冲**，205 字节 << BUFSIZ(4096)
⇒ 数据在 `close()` 之前**不进文件** ⇒ 「文件为 0 字节」的窗口 ≈ open→close 全程。

### 1.1 夹具版（独立 perl 进程，隔离文件，n=3000）

```
$ adb shell "cd /tmp/racetester-9 && WDUMP=.../w_samples.txt perl wtest.pl /tmp/racetester-9/w.json 205 3000 0"
WSTAT open_us        n=3000 min=34.09 p50=38.15 p90=51.02 p95=65.09 p99=99.18 max=229.12 mean=42.68
WSTAT write_us       n=3000 min=5.96  p50=9.06  p90=10.97 p95=12.16 p99=29.09 max=155.93 mean=9.76
WSTAT close_us       n=3000 min=14.78 p50=17.17 p90=20.98 p95=24.08 p99=52.93 max=169.04 mean=18.96
WSTAT open_close_us  n=3000 min=58.89 p50=64.85 p90=90.12 p95=104.90 p99=144.00 max=323.06 mean=71.39
```

**夹具版 W（tmpfs）：p50 = 64.85 µs，p95 = 104.90 µs，max = 323.06 µs**

对照：Lead 本机 SSD 的 W 是 **p95 = 0.83 ms**
⇒ **同一夹具、tmpfs vs SSD，真机快约 8×**（105 µs vs 830 µs）。

**对照实验（证明窗口确实来自缓冲）**：打开 autoflush 后
`write_us` 从 p50=9.06 µs 涨到 30.99 µs，而 `close_us` 从 17.17 µs 降到 8.11 µs
⇒ 数据被提前刷进文件，窗口被压缩。这与「stdout 缓冲 ⇒ 0 字节窗口」的机制一致。

### 1.2 in-situ 版（真 lua 在真 mpv 里自计时，无读者扰动，n=244）

读者侧高频采样（12k reads/s）本身吃 CPU（4 核），会抬高 W——那是**测量装置扰动被测对象**。
所以改用**写者自计时**：在隔离副本的 `write_file` 里用 `mp.get_time()` 量 open→close，
旁边没有读者。注入用 `instrument.pl` 做**字面量精确替换 + 自校验**
（`funcs 23->23`、`brace_delta=0/0`、`__t0=1 __t1=1 污染=0`）。

```
$ adb shell "cd /tmp/racetester-9 && sh run_instrumented.sh 240"
INSTRUMENT ok: 精确替换 1 处，__t0=1 __t1=1 污染=0 brace_delta=0/0 funcs=23->23
INJECTION_LIVE: wdur.txt 已有 4 个样本
=== IN-SITU W ===
INSITU_W n=244 min=239.00 p50=328.00 p90=396.00 p95=495.00 p99=908.00 max=1106.00 mean=351.39 (us)
```

**in-situ W：p50 = 328 µs，p95 = 495 µs，max = 1106 µs**

⚠️ **两个 W 相差约 5×，必须分开报，不能混用**：
- 夹具版（p50 65 µs）= 一个最小 perl 进程写 tmpfs 的成本
- in-situ 版（p50 328 µs）= 真 lua 在 mpv 进程内写 tmpfs 的成本（mpv 有解码线程、更大内存压力）
⇒ **决定真实命中率的是 in-situ 那个 328 µs，不是 65 µs。**

---

## 2. 真 lua 确实每秒写（实测）

用真 mpv + 真 gdnext.lua（隔离副本：DIR→`/tmp/racetester-9/gdmusic`，LOCK→`/tmp/racetester-9/gdtest.lock`）。

```
$ adb shell "cd /tmp/racetester-9 && sh run_drift.sh"     # 300s
DRIFT elapsed=300.000s samples=3868971 rate=12896.6/s
DRIFT bad=1126 duty=0.00029103 (per-read hit prob) tears=0
DRIFT writes=301
DRIFT interval n=300 min=0.469729 p50=1.000305 p95=1.001742 max=1.005486 mean=0.99853750 std=0.030597
```

`now.json` 真实内容（真 lua 写出）：
```
{"ts":1791357375.000,"seq":5.000,"index":1.000,"pos":0.818,"dur":598.604,"queueLen":1.000,
 "pause":false,"idle":false,"status":"playing","id":"1234567","name":"AuditTone",
 "artist":"racetester","reason":"","text":""}
```
文件长度 214–218 字节（随 `pos` 位数变化），**与任务描述里的 205 字节同量级**。

⇒ **真机实测：lua 每秒写一次，p50 间隔 1.0003 s，mean 0.99854 s。**
（60 s 与 180 s 窗口同样得到 `seq_interval p50=1.000`，`distinct_seq` 与秒数一致。）

---

## 3. 坏读比例

### 3.1 对**真 now.json** 采样（写者 = 真 mpv + 真 lua，1 Hz）

```
# 60 s 满速采样
AUDIT reads=341081 rate=5684.68/s ok=341034 zero=47 tear=0 nodata=0
AUDIT badrate=0.013780%   sizes=0:47,214:23550,215:26399,216:291085

# 180 s 满速采样
PHASE samples=2283171 rate=12684.3/s cycle=78.84us
PHASE bad_samples=310 duty=0.00013578 (= 每次读命中概率)  tears=0

# 300 s 满速采样（最大样本，最可信）
DRIFT samples=3868971 rate=12896.6/s
DRIFT bad=1126 duty=0.00029103  tears=0
DRIFT writes=301
```

**真机每次读命中坏状态的概率：0.0136% – 0.0291%（三次测量范围），300 s 那次为 0.0291%。**
**全部坏读都是 0 字节，撕裂（半截）0 次** —— 与缓冲机制预测一致。

交叉验证：`duty ≈ W × 写入频率 = 328 µs × 1.0/s = 328 µs/s = 0.0328%`，
实测 0.0291% ⇒ **偏差 11%，互相印证**。

### 3.2 双进程合成夹具（用于标定，不代表真机节拍）

`race.pl`：写者/读者**两个独立真进程**（必须，同进程顺序执行永不重叠 ⇒ 恒 0 坏读 = 夹具无效）。

```
$ adb shell "cd /tmp/racetester-9 && sh drive.sh saturated 6 0 0 0"   # 双方满速
WRITER writes=67221 rate=11203.35/s
READER reads=66315 ok=7105 zero=59210 tear=0
READER badrate=89.285984%   sizes=0:59210,205:7105
```

```
$ adb shell "cd /tmp/racetester-9 && sh sweep.sh 30"    # 写者与读者同节拍
beat 2ms : badrate=50.849385%   (ok=6915 zero=7154)
beat 5ms : badrate=34.637159%   (ok=3810 zero=2019)
beat 20ms: badrate=46.459879%   (ok=794  zero=689)
```

🔴 **注意 sweep 不单调**（2ms 50.8% → 5ms 34.6% → 20ms 46.5%）。
原因：两个**同周期**定时器会**相位锁死**，不是独立的 `W/T` 随机对撞。
⇒ 本机那个 33.9% 是**满速对撞的上界**；合成夹具的数字**不能**直接搬到真机 1 Hz 场景。
真机 1 Hz 的正确数字只能由 §3.1 的实测给出。

### 3.3 相位漂移（判断「命中是时间问题还是运气问题」）

```
DRIFT period_bias=-1.4625 ms/write          # mean 间隔 - 1.000s
DRIFT phase_slope=+0.000277 s/write         # 相位线性回归斜率
DRIFT implied_sweep_time=683.8 s            # 1s / |bias|
DRIFT sweep_time=3609.6 s                   # 1 / |slope|
DRIFT phase_head=0.7449,0.2146,0.2144,...   # 相位 mod 1s
DRIFT phase_tail=0.2981,0.2983,...,0.3061
```

两个估计（684 s / 3610 s）**不一致**，因为它们量的不是一回事：
`bias` 用平均间隔（含抖动），`slope` 是相位序列回归（更干净但受噪声影响）。
**诚实结论：相位确实在缓慢漂移（head 0.2146 → tail 0.3061，300 s 内推进约 0.09 s），
但漂移速率的具体值我给不准；能确定的量级是「几百秒到一小时扫过一整圈」。**
⇒ 只要 QML 的 1 s 轮询与 lua 的 1 s 定时器不是严格同源，
相位就会周期性扫过写窗口 ⇒ **命中是时间问题，不是运气问题**（这一点成立）。
但**「每 N 秒必中一次」的 N 我给不出可靠数字**，只能说量级是数百秒以上。

---

## 4. 后果链的 QML 侧 raw 输出（Lead 点名要的）

逐字复刻 `MediaBridge.qml:226-228` 的命令：
`if [ -f NOW ]; then cat NOW; else printf 'NOFILE'; fi; printf '\n@@\n'; if [ -S SOCK ]; then printf 'S\n'; else printf 'D\n'; fi`

```
=== A: 文件不存在 + socket 不存在 ===
0000000   N   O   F   I   L   E  \n   @   @  \n   D  \n
=== B: 文件不存在 + socket 存在 ===
0000000   N   O   F   I   L   E  \n   @   @  \n   S  \n
=== C: 文件存在且完整（对照）===
0000000   {   "   t   s   "   :   1   ,   "   s   e   q   "   :   9   }  \n   @   @  \n   D  \n
=== D: 文件存在但 0 字节（撕裂读命中那一拍）===
0000000  \n   @   @  \n   D  \n
=== E: 文件存在但半截 ===
0000000   {   "   t   s   "   :   1   ,   "   s   e   q   "   :   9   ,   "   n   a   m   e   "   :   " 345 215 212  \n   @   @  \n   D  \n
```

解析（对照 `MediaBridge.qml:235-252`）：
- `raw.indexOf("@@") >= 0` 在 **A–E 全部成立** ⇒ 「这一拍有效」的判据全部通过
- 场景 A/B：`parts[0]="NOFILE"` ⇒ `out.charAt(0) !== '{'` ⇒ **`o = null`** ⇒ 走 `!o` 分支
- 场景 D（0 字节）：`parts[0]=""` ⇒ `out.length === 0` ⇒ **`o = null`** ⇒ 同上
- 场景 E（半截）：以 `{` 开头 ⇒ 进 `JSON.parse` ⇒ 抛异常被 catch ⇒ **`o = null`** ⇒ 同上

⇒ **「文件不存在」(NOFILE) 与「0 字节」「半截」在 QML 侧收敛到同一个 `o=null`**，
三者后果相同。Lead 的修复「读不到时沿用上一拍状态」确实需要覆盖 NOFILE 这一支。

⚠️ 补充一条 tmpfs 特有的事实：`/tmp` 是 tmpfs，**重启/清 tmp 后 now.json 会消失**。
我实测过设备上 `/tmp/gdmusic` 曾经不存在（任务开始时 `ls -ld` = No such file），
后来由 Lead 的 mpv 创建——即**「文件不存在」这个态在真机上真实可达**，不是纯理论。

---

## 5. 与 Lead 本机数字对比

| 量 | Lead 本机（SSD） | 真机（tmpfs） | 结论 |
|---|---|---|---|
| W 夹具 p95 | 0.83 ms | **0.105 ms** | 真机快 ~8× |
| W in-situ p95 | （未测） | **0.495 ms** | — |
| 每次读命中概率 | 0.083%（= 0.83ms/1s） | **0.0136%–0.0291%** | 真机**更低** |
| 满速对撞坏读率 | 33.9% | 89.3%（夹具上界） | 不可比（节拍不同） |

**核心结论：真机命中概率比 Lead 的本机 SSD 估计更低（约 0.029% vs 0.083%），
因为 now.json 在 tmpfs 上。任务描述里「真机必然更大」的方向是错的。**

但**量级不变**：两者都是**万分之几/每次读**。按 1 Hz 轮询、
相位漂移在数百秒量级扫一圈 ⇒ **一天连续播放（86400 拍）里命中次数是「几次到几十次」量级**，
不是「永远不会发生」。配合「单次坏读 ⇒ `o=null` ⇒ `release(); killMpv()`」的零容忍后果，
P1 依然是真问题。

---

## 6. 测量方法学（踩过的坑，供后人复用）

1. **`/tmp` 是 tmpfs** —— 先查 `/proc/mounts` 再假设「设备慢」。
2. **同进程顺序跑并发测试 = 夹具无效**（恒 0 坏读）。必须两个真进程。
3. **同周期定时器相位锁死** ⇒ sweep 不单调，`W/T` 模型不适用于同拍场景。
4. **夹具载荷必须自校验**：我第一版用尾随空格补齐 205 字节，
   导致**完整 205 字节读被误判为 PARTIAL**，坏读率虚报成 100%（真值 85.4%）。
   修法：补白放在 JSON 字符串值内部，并断言 `len == expect && 首尾是 {}`。
5. **adb shell 退出会 SIGHUP 收走 mpv** —— 实测两次：单独起 mpv（即使 `nohup`）后
   会话一结束 mpv 就死，`now.json` 停在 `seq=6` 不再增长，会被**误读成「lua 没在每秒写」**。
   修法：起 mpv + 采样 + kill 全放在**同一个 sh 会话**里。
6. **注入式测量必须自校验**：早先正则懒惰匹配停在错误的 `end` 上，
   生成 `return true  local __t1 = ...` 语法错误 ⇒ 整个 lua 加载失败。
   修法：字面量精确替换 + 校验函数数量/花括号增量/污染串。
7. **真机这份 mpv 的 libavcodec 没有 `pcm_s16le` 解码器** —— WAV 必失败
   （`Failed to initialize a decoder for codec 'pcm_s16le'`），用 MP3 才行。
8. **`/userdisk/mpv/mpv` 是 wrapper，会写 `/tmp/audio_wakelocks/VideoPlayer.lock`** ——
   必须直接用 `/userdisk/mpv/bin/mpv` 才能守住「不碰 VideoPlayer.lock」的约束。
9. **PowerShell 传 `$(...)`/`|` 给 adb 会被本地展开** —— 一律写 sh 脚本推上去跑。
