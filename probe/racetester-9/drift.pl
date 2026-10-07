#!/usr/bin/perl
# drift.pl —— 长窗口精确测 lua 写入周期漂移 + 每次读命中概率
# 同时把写时刻原始序列落盘，便于离线复核回归。
# 用法: perl drift.pl <now.json> <dur_s> [dumpfile]
use strict; use warnings;
use Time::HiRes qw(time);

my $path = shift // '/tmp/racetester-9/gdmusic/now.json';
my $dur  = shift // 300;
my $dump = shift // '';

sub pct { my ($s,$p)=@_; return 0 unless @$s; my $i=int(($p/100)*$#$s); $i=0 if $i<0; $i=$#$s if $i>$#$s; return $s->[$i]; }

my $total=0; my $bad=0; my $tear=0;
my @wt;                 # 每次 seq 变化（写事件）的精确时刻
my %seen; my $prev='';
my $t0 = time; my $t_end = $t0 + $dur; my $last;

while (1) {
    my $t = time;
    last if $t >= $t_end;
    $last = $t;
    my $d;
    if (open(my $f,'<',$path)) { binmode $f; local $/; $d=<$f>; close $f; } else { $d=undef; }
    $total++;
    if (!defined $d || length($d)==0) { $bad++; next; }
    if (substr($d,0,1) ne '{' || substr($d,-1,1) ne '}') { $bad++; $tear++; next; }
    if ($d ne $prev) {
        $prev = $d;
        if ($d =~ /"seq":(\d+)/) { my $s=$1; unless ($seen{$s}++) { push @wt, $t; } }
    }
}
my $el = $last - $t0;
printf("DRIFT elapsed=%.3fs samples=%d rate=%.1f/s\n", $el, $total, $total/$el);
printf("DRIFT bad=%d duty=%.8f (per-read hit prob) tears=%d\n", $bad, $total?$bad/$total:0, $tear);
printf("DRIFT writes=%d\n", scalar(@wt));

if (@wt >= 5) {
    # 丢弃启动首个写事件（它与前一个间隔不完整）
    my @iv;
    for my $i (1..$#wt) { push @iv, $wt[$i]-$wt[$i-1]; }
    my @s = sort { $a <=> $b } @iv;
    my $sum=0; $sum+=$_ for @s;
    my $mean = $sum/@s;
    my $var=0; $var+=($_-$mean)**2 for @s;
    printf("DRIFT interval n=%d min=%.6f p50=%.6f p95=%.6f max=%.6f mean=%.8f std=%.6f\n",
        scalar(@s), $s[0], pct(\@s,50), pct(\@s,95), $s[-1], $mean, sqrt($var/@s));
    printf("DRIFT period_bias=%+.4f ms/write  (mean - 1.000s)\n", ($mean-1.0)*1000);
    printf("DRIFT implied_sweep_time=%.1f s  (1s / |bias|, 相位扫过整周期所需)\n",
        abs($mean-1.0) > 1e-9 ? 1.0/abs($mean-1.0) : -1);

    # 线性回归 phase(index) => 斜率即每次写的相位漂移
    my @ph = map { $_ - int($_) } @wt;
    my $n = scalar @ph;
    my ($sx,$sy,$sxx,$sxy)=(0,0,0,0);
    for my $i (0..$n-1) { $sx+=$i; $sy+=$ph[$i]; $sxx+=$i*$i; $sxy+=$i*$ph[$i]; }
    my $slope = ($n*$sxy - $sx*$sy) / ($n*$sxx - $sx*$sx);
    printf("DRIFT phase_slope=%+.6f s/write  (每次写相位推进量 delta)\n", $slope);
    printf("DRIFT delta_vs_W: delta=%.1f us, W(duty-implied)=%.1f us\n",
        abs($slope)*1e6, ($total?$bad/$total:0)/ (($el>0 && @wt>1) ? ($#wt/$el) : 1) * 1e6);
    if (abs($slope) > 1e-9) {
        printf("DRIFT sweep_time=%.1f s (1/|slope|)\n", 1.0/abs($slope));
    }
    print "DRIFT phase_head=" . join(',', map { sprintf('%.4f',$_) } @ph[0..($#ph<25?$#ph:25)]) . "\n";
    print "DRIFT phase_tail=" . join(',', map { sprintf('%.4f',$_) } @ph[($#ph>25?$#ph-25:0)..$#ph]) . "\n";
    if ($dump) { if (open(my $f,'>',$dump)) { print $f "$_\n" for @wt; close $f; } }
}
exit 0;
