#!/usr/bin/perl
# Costruisce uno zip "a mano" per i test (anche artefatto: nomi con .., assoluti,
# link, dimensioni dichiarate false).
# Uso: mkzip.pl USCITA "nome|modo-ottale|dim-dichiarata[|reali]"...
# Il quarto campo può essere: un numero (byte reali, "x"), "=testo" (contenuto letterale)
# o "zNUMERO" (NUMERO byte di zeri compressi con deflate: una bomba che dichiara poco).
# Il nome che finisce con / è una cartella; il modo 12xxxx è un link verso /etc/shadow.
use strict;
use warnings;
use Compress::Raw::Zlib qw(crc32 Z_OK Z_STREAM_END Z_FINISH);

my $out = shift @ARGV;
my ($body, $cd, $n) = ('', '', 0);
for my $a (@ARGV) {
    my ($name, $mode, $us, $len) = split /\|/, $a, 4;
    $len = $us unless defined $len;
    my ($data, $method, $crc) = ('', 0, 0);
    if ($len =~ /^=/) {
        $data = substr($len, 1);
        $us   = length $data;
    } elsif ($len =~ /^z(\d+)$/) {
        my $total = $1;
        my ($d) = Compress::Raw::Zlib::Deflate->new(-WindowBits => -15, -AppendOutput => 1);
        my $chunk = "\0" x 1048576;
        my $c = 0;
        for (my $i = 0; $i < $total; $i += length $chunk) {
            my $part = $total - $i < length $chunk ? "\0" x ($total - $i) : $chunk;
            $d->deflate($part, $data);
            $c = Compress::Raw::Zlib::crc32($part, $c);
        }
        $d->flush($data, Z_FINISH);
        ($method, $crc) = (8, $c);
    } else {
        $data = 'x' x $len;
    }
    $data = '/etc/shadow' if $mode =~ /^12/;
    $crc = crc32($data) unless $method;
    my $cs  = length $data;
    my $off = length $body;
    $body .= pack('VvvvvvVVVvv', 0x04034b50, 20, 0, $method, 0, 0x21, $crc, $cs, $us, length $name, 0) . $name . $data;
    $cd .= pack('VvvvvvvVVVvvvvvVV', 0x02014b50, (3 << 8) | 20, 20, 0, $method, 0, 0x21, $crc, $cs, $us,
        length $name, 0, 0, 0, 0, oct($mode) << 16, $off) . $name;
    $n++;
}
my $eocd = pack('VvvvvVVv', 0x06054b50, 0, 0, $n, $n, length $cd, length $body, 0);
open my $fh, '>:raw', $out or die "$out: $!";
print $fh $body, $cd, $eocd;
close $fh;
