#!/usr/bin/perl
# audit_read.pl —— 对【真 lua 写出的】now.json 做高频采样，测真实坏读比例与写入节奏
#
# 与 race.pl read 的区别：这里采样的是真 mpv+gdnext.lua 产出的文件，
# 不是合成夹具 ⇒ 得到的是【真机实测】而不是模型外推。
#
# 用法: perl audit_read.pl <now.json> <dur_s> <period_us>
#   period_us=0 ⇒ 满速采样（用于把「每次读的命中概率」估准）
use strict; use warnings;
use Time::HiRes qw(time sleep);

my $path   = shift // '/tmp/racetester-9/gdmusic/now.json';
my $dur    = shift // 60;
my $period = shift // 0;

my ($total, $ok, $zero, $tear, $nodata) = (0,0,0,0,0);
my %sz;
my @bad_t;
my %seq_first;      # seq -> 首次见到的时间
my %seq_count;
my $first_len;
my $t_first = time;
my $t_end   = $t_first + $dur;

while (1) {
    my $t0 = time;
    last if $t0 >= $t_end;
    my $data;
    if (open(my $fh, '<', $path)) {
        binmode $fh; local $/; $data = <$fh>; close $fh;
    } else { $data = undef; }
    $total++;
    if (!defined $data) { $nodata++; }
    else {
        my $n = length($data);
        $sz{$n}++;
        if ($n == 0) { $zero++; push @bad_t, sprintf('%.3f', $t0 - $t_first) if @bad_t < 60; }
        elsif (substr($data,0,1) ne '{' || substr($data,-1,1) ne '}') {
            $tear++; push @bad_t, sprintf('%.3f', $t0 - $t_first) if @bad_t < 60;
        } else {
            $ok++;
            $first_len = $n unless defined $first_len;
            if ($data =~ /"seq":(\d+)/) {
                my $s = $1;
                $seq_first{$s} = $t0 - $t_first unless exists $seq_first{$s};
                $seq_count{$s}++;
            }
        }
    }
    if ($period > 0) { my $s = $t0 + $period/1e6 - time; sleep($s) if $s > 0; }
}
my $el = time - $t_first;
my $bad = $zero + $tear;
printf("AUDIT path=%s reads=%d elapsed=%.3fs rate=%.2f/s ok=%d zero=%d tear=%d nodata=%d\n",
       $path, $total, $el, $total/$el, $ok, $zero, $tear, $nodata);
printf("AUDIT badrate=%.6f%% (bad=%d/%d) full_len=%s\n",
       $total ? 100*$bad/$total : 0, $bad, $total, defined $first_len ? $first_len : 'n/a');
my @ks = sort { $a <=> $b } keys %sz;
my $lim = $#ks < 12 ? $#ks : 12;
print "AUDIT sizes=" . join(',', map { "$_:$sz{$_}" } @ks[0..$lim]) . "\n";
print "AUDIT badtimes=" . join(',', @bad_t) . "\n";

# 写入节奏：按 seq 首次出现时间算间隔
my @sq = sort { $a <=> $b } keys %seq_first;
print "AUDIT distinct_seq=" . scalar(@sq) . "\n";
if (@sq >= 2) {
    my @iv;
    for my $i (1 .. $#sq) { push @iv, $seq_first{$sq[$i]} - $seq_first{$sq[$i-1]}; }
    my @s = sort { $a <=> $b } @iv;
    my $sum = 0; $sum += $_ for @s;
    printf("AUDIT seq_interval n=%d min=%.3f p50=%.3f max=%.3f mean=%.3f (s)\n",
           scalar(@s), $s[0], $s[int(0.5*$#s)], $s[-1], $sum/@s);
    print "AUDIT seq_list=" . join(',', @sq[0 .. ($#sq < 20 ? $#sq : 20)]) . "\n";
}
exit 0;
