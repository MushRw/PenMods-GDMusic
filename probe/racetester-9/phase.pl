#!/usr/bin/perl
# phase.pl —— 高频采样真 now.json，直接量出【每次写】的坏状态窗口 W，并做相位分析
#
# 输出三类证据：
#   1. 每次写的坏窗口 W（由连续 0 字节样本的起止时间推出）
#   2. 坏状态占空比（= 每次读的命中概率）
#   3. 写事件时刻 mod 1s 的相位漂移（判断「两个 1Hz 定时器相位是否会扫过写窗口」）
#
# 用法: perl phase.pl <now.json> <dur_s>
use strict; use warnings;
use Time::HiRes qw(time sleep);

my $path = shift // '/tmp/racetester-9/gdmusic/now.json';
my $dur  = shift // 120;

sub pct { my ($s,$p)=@_; return 0 unless @$s; my $i=int(($p/100)*$#$s); $i=0 if $i<0; $i=$#$s if $i>$#$s; return $s->[$i]; }

my $total = 0; my $bad_total = 0; my $tear_total = 0;
my @runs;                       # [start_t, end_t, nbad]
my @writes;                     # 每次 seq 变化的时刻
my %seq_seen;
my $cur_run_start; my $cur_run_n = 0; my $prev_bad = 0;
my $prev_content = '';
my $t_first = time;
my $t_end   = $t_first + $dur;
my $last_t;

while (1) {
    my $t = time;
    last if $t >= $t_end;
    $last_t = $t;
    my $data;
    if (open(my $fh, '<', $path)) { binmode $fh; local $/; $data = <$fh>; close $fh; }
    else { $data = undef; }
    $total++;
    my $is_bad = 1;
    if (defined $data) {
        my $n = length($data);
        if ($n > 0 && substr($data,0,1) eq '{' && substr($data,-1,1) eq '}') {
            $is_bad = 0;
            if ($data ne $prev_content) {
                if ($data =~ /"seq":(\d+)/) {
                    my $s = $1;
                    if (!exists $seq_seen{$s}) { $seq_seen{$s} = 1; push @writes, $t; }
                }
                $prev_content = $data;
            }
        } else { $tear_total++ if $n > 0; }
    }
    if ($is_bad) {
        $bad_total++;
        if ($prev_bad) { $cur_run_n++; }
        else { $cur_run_start = $t; $cur_run_n = 1; }
    } else {
        if ($prev_bad && defined $cur_run_start) {
            push @runs, [$cur_run_start, $t, $cur_run_n];
            undef $cur_run_start; $cur_run_n = 0;
        }
    }
    $prev_bad = $is_bad;
}
# 收尾：采样结束时仍在坏状态
push @runs, [$cur_run_start, $last_t, $cur_run_n] if $prev_bad && defined $cur_run_start;

my $elapsed = $last_t - $t_first;
my $cycle   = $total ? $elapsed / $total : 0;
printf("PHASE path=%s\n", $path);
printf("PHASE elapsed=%.3fs samples=%d rate=%.1f/s cycle=%.2fus\n",
       $elapsed, $total, $total/$elapsed, $cycle*1e6);
printf("PHASE bad_samples=%d duty=%.8f (= 每次读命中概率)  tears=%d\n",
       $bad_total, $total ? $bad_total/$total : 0, $tear_total);
printf("PHASE writes_detected=%d (seq 变化次数)\n", scalar(@writes));

# 每次写的坏窗口 W：用 run 内样本数 × cycle 估计（比起止差更稳）
my @W;
for my $r (@runs) {
    my ($s, $e, $n) = @$r;
    push @W, ($e - $s) + $cycle;      # 首个坏样本到首个好样本 = 一个 cycle 的下限修正
}
if (@W) {
    my @s = sort { $a <=> $b } @W;
    my $sum = 0; $sum += $_ for @s;
    printf("PHASE window W n=%d min=%.2f p50=%.2f p90=%.2f p95=%.2f max=%.2f mean=%.2f (us)\n",
        scalar(@s), $s[0]*1e6, pct(\@s,50)*1e6, pct(\@s,90)*1e6, pct(\@s,95)*1e6,
        $s[-1]*1e6, $sum/@s*1e6);
    # 由占空比反推的平均窗口：duty / (writes per second)
    my $wps = $elapsed ? scalar(@writes)/$elapsed : 0;
    printf("PHASE duty_implied_W=%.2f us (duty=%.8f, writes/s=%.4f)\n",
        $wps ? ($bad_total/$total)/$wps*1e6 : 0, $total ? $bad_total/$total : 0, $wps);
    printf("PHASE runs_with_bad=%d / writes=%d  (比值 <1 表示有写事件没被抓到窗口)\n",
        scalar(@runs), scalar(@writes));
}

# ---- 写事件相位分析：写时刻 mod 1s ----
if (@writes >= 3) {
    my @iv;
    for my $i (1 .. $#writes) { push @iv, $writes[$i] - $writes[$i-1]; }
    my @s = sort { $a <=> $b } @iv;
    my $sum = 0; $sum += $_ for @s;
    printf("PHASE write_interval n=%d min=%.4f p50=%.4f max=%.4f mean=%.6f (s)\n",
        scalar(@s), $s[0], pct(\@s,50), $s[-1], $sum/@s);
    printf("PHASE write_period_bias=%.6f ms/写 (mean-1.000)\n", ($sum/@s - 1.0)*1000);

    my @ph = map { my $x = $_ - int($_); $x } @writes;
    my @ps = sort { $a <=> $b } @ph;
    my $psum = 0; $psum += $_ for @ph;
    my $pmean = $psum / @ph;
    my $var = 0; $var += ($_-$pmean)**2 for @ph;
    printf("PHASE write_phase_mod1 n=%d min=%.4f p50=%.4f max=%.4f mean=%.4f std=%.4f (s)\n",
        scalar(@ps), $ps[0], pct(\@ps,50), $ps[-1], $pmean, sqrt($var/@ph));
    # 前半 vs 后半 的相位均值：系统性漂移会表现为两者明显不同
    my $h = int(@ph/2);
    my ($m1, $m2) = (0, 0);
    $m1 += $ph[$_] for 0 .. $h-1;
    $m1 /= $h;
    $m2 += $ph[$_] for $h .. $#ph;
    $m2 /= (@ph - $h);
    printf("PHASE drift_check first_half_mean=%.4f second_half_mean=%.4f delta=%.4f (s)\n",
        $m1, $m2, $m2 - $m1);
    print "PHASE phase_series=" . join(',', map { sprintf('%.3f', $_) } @ph[0 .. ($#ph < 40 ? $#ph : 40)]) . "\n";
}
exit 0;
