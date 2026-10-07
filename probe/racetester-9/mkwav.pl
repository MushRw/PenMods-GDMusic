#!/usr/bin/perl
# mkwav.pl —— 生成一个真实可解码的 WAV，供真机 mpv 离线播放（不碰网络）
# 用法: perl mkwav.pl <out.wav> <seconds>
use strict; use warnings;
my $out = shift // '/tmp/racetester-9/tone.wav';
my $sec = shift // 30;
my $rate = 8000;
my $ch   = 1;
my $bits = 16;
my $n = $rate * $sec;
my $data = "\x00" x ($n * $ch * $bits / 8);
my $bytes = length($data);
open(my $f, '>:raw', $out) or die "open: $!";
print $f 'RIFF', pack('V', 36 + $bytes), 'WAVEfmt ', pack('V', 16),
         pack('v', 1), pack('v', $ch), pack('V', $rate),
         pack('V', $rate * $ch * $bits / 8), pack('v', $ch * $bits / 8),
         pack('v', $bits), 'data', pack('V', $bytes), $data;
close $f;
print "WAV out=$out bytes=" . (44 + $bytes) . " sec=$sec rate=$rate\n";
exit 0;
