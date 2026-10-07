#!/usr/bin/perl
# wtest.pl —— 真机测量「截断式写」的坏状态窗口 W
#
# 被测语义（与 gdnext.lua:96 write_file 完全对齐）：
#   local f = io.open(p,"w")   -- 截断
#   f:write(s)                 -- Lua io 走 C stdio，默认【全缓冲】
#   f:close()                  -- 这里才 flush 落盘
# 205 字节 << BUFSIZ(4096) ⇒ 数据在 close() 之前根本不进文件
# ⇒ 「文件为 0 字节」的窗口 ≈ open→close 全程。
#
# 本脚本用 Perl 的默认缓冲（不 autoflush）复刻同一语义。
# 第 4 个参数 flush=1 时打开 autoflush，用来【对照】证明窗口确实来自缓冲。
#
# 用法: perl wtest.pl <path> <bytes> <iters> [flush]
use strict;
use warnings;
use Time::HiRes qw(time);

my $path   = shift // '/tmp/racetester-9/w.json';
my $nbytes = shift // 205;
my $iters  = shift // 3000;
my $flush  = shift // 0;

# 载荷按真实 now.json 的字段形状构造（gdnext.lua:212-222 的字段顺序）
sub mkpayload {
    my ($n) = @_;
    my $u = '{"ts":1791356087,"seq":12345,"index":1,"pos":123.456,"dur":234.567,'
          . '"queueLen":3,"pause":false,"idle":false,"status":"playing",'
          . '"id":"1234567","name":"晴天","artist":"周杰伦","reason":"","text":""}';
    my $s = $u;
    $s .= ' ' while length($s) < $n;
    return substr($s, 0, $n);
}
my $payload = mkpayload($nbytes);
my $plen    = length($payload);

# 预置：真实场景里文件本来就在（不是首次创建）
open(my $pf, '>', $path) or die "preload open: $!";
print $pf 'x' x $plen;
close $pf;

my (@top, @twr, @tcl, @tot);
for my $i (1 .. $iters) {
    my $t0 = time;
    open(my $fh, '>', $path) or die "open(w): $!";
    my $t1 = time;
    if ($flush) { select((select($fh), $| = 1)[0]); }
    print $fh $payload;
    my $t2 = time;
    close($fh);
    my $t3 = time;
    push @top, ($t1 - $t0) * 1e6;    # open(含截断)  µs
    push @twr, ($t2 - $t1) * 1e6;    # write(进缓冲) µs
    push @tcl, ($t3 - $t2) * 1e6;    # close(flush)  µs
    push @tot, ($t3 - $t0) * 1e6;    # open→close    µs  <= 坏状态窗口 W
}

sub pct {
    my ($s, $p) = @_;
    return 0 unless @$s;
    my $i = int(($p / 100) * $#$s);
    $i = 0 if $i < 0;
    $i = $#$s if $i > $#$s;
    return $s->[$i];
}
sub stats {
    my ($name, $arr) = @_;
    my @s = sort { $a <=> $b } @$arr;
    my $sum = 0; $sum += $_ for @s;
    printf("WSTAT %-14s n=%d min=%.2f p50=%.2f p90=%.2f p95=%.2f p99=%.2f max=%.2f mean=%.2f (us)\n",
        $name, scalar(@s), $s[0], pct(\@s,50), pct(\@s,90), pct(\@s,95),
        pct(\@s,99), $s[-1], $sum / @s);
}

printf("WTEST path=%s bytes=%d iters=%d flush=%d payload_len=%d\n",
       $path, $nbytes, $iters, $flush, $plen);
stats('open_us',      \@top);
stats('write_us',     \@twr);
stats('close_us',     \@tcl);
stats('open_close_us', \@tot);

# W 的原始样本落到文件，便于复核（不依赖 stdout 截断）
if (my $dump = $ENV{WDUMP}) {
    if (open(my $d, '>', $dump)) {
        print $d "$_\n" for @tot;
        close $d;
    }
}
exit 0;
