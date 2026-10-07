#!/usr/bin/perl
# race.pl —— 真机撕裂读竞态夹具（单文件，两种角色，必须两个进程并发跑）
#
#   写者: perl race.pl write <path> <bytes> <dur_s> <period_us> [flush]
#   读者: perl race.pl read  <path> <expected_bytes> <dur_s> <period_us>
#
# period_us = 0  ⇒ 满速循环（不加 sleep）
# period_us > 0  ⇒ 每拍 sleep 到 period_us，模拟「定时器节拍」
#
# 为什么必须两个真进程：同一进程内顺序执行时读写永不重叠，
# 测出来恒为 0 坏读 —— 那是【夹具无效】，不是「没问题」。
#
# ⚠️ 夹具自校验：载荷必须是【合法 JSON 且恰好 <bytes> 字节】。
#    早先版本用尾随空格补齐 ⇒ 205 字节的完整读也被误判为 PARTIAL，
#    坏读率被虚报成 100%。现在补白放在 JSON 字符串值【内部】。
use strict;
use warnings;
use Time::HiRes qw(time sleep);

my $mode = shift // 'read';
my $path = shift // '/tmp/racetester-9/race.json';

sub mkpayload {
    my ($n) = @_;
    my $head = '{"ts":1791356087,"seq":12345,"index":1,"pos":123.456,"dur":234.567,'
             . '"queueLen":3,"pause":false,"idle":false,"status":"playing",'
             . '"id":"1234567","name":"晴天","artist":"周杰伦","reason":"","text":"';
    my $tail = '"}';
    my $pad  = $n - length($head) - length($tail);
    die "bytes=$n too small (head=" . length($head) . ")" if $pad < 0;
    my $s = $head . ('p' x $pad) . $tail;
    die "payload len " . length($s) . " != $n" if length($s) != $n;
    die "payload not valid-json-shaped" unless substr($s,0,1) eq '{' && substr($s,-1,1) eq '}';
    return $s;
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
    return unless @$arr;
    my @s = sort { $a <=> $b } @$arr;
    my $sum = 0; $sum += $_ for @s;
    printf("WSTAT %-14s n=%d min=%.2f p50=%.2f p90=%.2f p95=%.2f p99=%.2f max=%.2f mean=%.2f (us)\n",
        $name, scalar(@s), $s[0], pct(\@s,50), pct(\@s,90), pct(\@s,95),
        pct(\@s,99), $s[-1], $sum / @s);
}

if ($mode eq 'write') {
    my $nbytes = shift // 205;
    my $dur    = shift // 5;
    my $period = shift // 0;
    my $flush  = shift // 0;
    my $payload = mkpayload($nbytes);

    open(my $pf, '>', $path) or die "preload: $!";
    print $pf $payload;
    close $pf;

    my @tot; my $n = 0;
    my $t_first = time;
    my $t_end   = $t_first + $dur;
    while (1) {
        my $t0 = time;
        last if $t0 >= $t_end;
        open(my $fh, '>', $path) or die "open(w): $!";
        if ($flush) { select((select($fh), $| = 1)[0]); }
        print $fh $payload;
        close($fh);
        my $t3 = time;
        push @tot, ($t3 - $t0) * 1e6;
        $n++;
        if ($period > 0) {
            my $s = $t0 + $period / 1e6 - time;
            sleep($s) if $s > 0;
        }
    }
    my $el = time - $t_first;
    printf("WRITER writes=%d elapsed=%.3fs rate=%.2f/s bytes=%d period_us=%d flush=%d\n",
           $n, $el, $n / $el, $nbytes, $period, $flush);
    stats('open_close_us', \@tot);
    exit 0;
}

# ---------------- 读者 ----------------
my $expect = shift // 205;
my $dur    = shift // 5;
my $period = shift // 0;

my ($total, $ok, $zero, $partial, $short, $nodata) = (0, 0, 0, 0, 0, 0);
my %sz;
my @bad;
my $t_first = time;
my $t_end   = $t_first + $dur;
while (1) {
    my $t0 = time;
    last if $t0 >= $t_end;
    my $data;
    if (open(my $fh, '<', $path)) {
        binmode $fh;
        local $/;
        $data = <$fh>;
        close $fh;
    } else {
        $data = undef;
    }
    $total++;
    if (!defined $data) {
        $nodata++;
    } else {
        my $n = length($data);
        $sz{$n}++;
        if ($n == 0) {
            $zero++;
            push @bad, 'ZERO' if @bad < 40;
        } elsif ($n != $expect || substr($data,0,1) ne '{' || substr($data,-1,1) ne '}') {
            # 非空但既不是期望长度、也不是完整 JSON ⇒ 真正的撕裂
            $partial++;
            push @bad, "TEAR($n)" if @bad < 40;
        } else {
            $ok++;
        }
    }
    if ($period > 0) {
        my $s = $t0 + $period / 1e6 - time;
        sleep($s) if $s > 0;
    }
}
my $el  = time - $t_first;
my $bad = $zero + $partial;
printf("READER reads=%d elapsed=%.3fs rate=%.2f/s ok=%d zero=%d tear=%d nodata=%d\n",
       $total, $el, $total / $el, $ok, $zero, $partial, $nodata);
printf("READER badrate=%.6f%% (bad=%d/%d)  expect_bytes=%d\n",
       $total ? 100 * $bad / $total : 0, $bad, $total, $expect);
my @ks = sort { $a <=> $b } keys %sz;
my $lim = $#ks < 12 ? $#ks : 12;
print "READER sizes=" . join(',', map { "$_:$sz{$_}" } @ks[0 .. $lim]) . "\n";
print "READER badsamples=" . join(',', @bad) . "\n";
exit 0;
