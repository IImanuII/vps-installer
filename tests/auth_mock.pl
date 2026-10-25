#!/usr/bin/perl
# Finto rclone authorize per i test di vps-backup (tests/backup.bats): ascolta su
# 127.0.0.1:53682 come il vero, scrive nel file degli errori la riga con l'indirizzo
# locale, risponde col redirect a Google su /auth e, ricevuto il code giusto, scrive il
# "token" nel file di uscita ed esce. Argomenti: err out state locfile tokfile cidfile
# activefile mode logfile errafterfile
use strict;
use warnings;
use IO::Socket::INET;

my ($err, $out, $state, $locfile, $tokfile, $cidfile, $active, $mode, $log, $errafter) = @ARGV;

sub slurp { my ($f) = @_; return '' unless defined $f && -f $f; open(my $h, '<', $f) or return ''; local $/; my $t = <$h>; close $h; return $t; }
sub append { my ($f, $t) = @_; open(my $h, '>>', $f) or return; print $h $t; close $h; }

my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 53682, Listen => 5, ReuseAddr => 1);
if (!$s) {
  append($err, "Failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: address already in use\n");
  unlink $active;
  exit 1;
}
$SIG{ALRM} = sub { exit 0 };
alarm 40;
if ($mode ne 'nostart') {
  append($err, "<5>NOTICE: Please go to the following link: http://127.0.0.1:53682/auth?state=$state\n<5>NOTICE: Waiting for code...\n");
}
while (my $c = $s->accept) {
  my $line = <$c>;
  $line = '' unless defined $line;
  while (my $h = <$c>) { last if $h eq "\r\n" || $h eq "\n"; }
  append($log, $line) if length $line;
  if (-f "$log.drip") {
    print $c "HTTP/1.1 307 Temporary Redirect
";
    for (1 .. 30) { print $c "X-a: b
"; sleep 1; }
    exit 0;
  }
  if ($line =~ m{^GET /auth\?state=(\S+) HTTP}) {
    my $loc = slurp($locfile);
    if ($loc eq '') {
      my $cid = '202264815644.apps.googleusercontent.com';
      my $env = slurp($cidfile);
      $cid = $1 if $env =~ /^RCLONE_DRIVE_CLIENT_ID=(.*)$/m;
      $loc = "https://accounts.google.com/o/oauth2/auth?access_type=offline&client_id=$cid&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2F&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file&state=$state";
    }
    print $c "HTTP/1.1 307 Temporary Redirect\r\nContent-Type: text/html\r\nLocation: $loc\r\nDate: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    close $c;
  } elsif ($line =~ m{^GET /\?state=([^&\s]+)&code=(\S+) HTTP}) {
    if ($1 ne $state) {
      print $c "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      close $c;
      exit 1;
    }
    if (-f "$log.drop") { close $c; exit 0; }
    print $c "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    close $c;
    append($out, slurp($tokfile));
    if (-f $errafter) { append($err, slurp($errafter)); unlink $active; }
    exit 0;
  } else {
    print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    close $c;
  }
}
