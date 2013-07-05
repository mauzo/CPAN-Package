package CPAN::Package;

use 5.010;
use warnings;
use strict;

our $VERSION = "1";

use Carp;
use Class::Load     qw/load_class/;
use HTTP::Tiny;
use Scalar::Util    qw/blessed/;

for my $a (qw/ 
    jail perl prefix builtby
    cpan metadb dist packages pkgdb
    su http
/) {
    no strict "refs";
    *$a = sub { $_[0]{$a} };
}

for my $l (qw/ initpkgs /) {
    no strict "refs";
    *$l = sub { @{ $_[0]{$l} } };
}

sub new {
    my ($class, %conf) = @_;

    $conf{perl}     //= "/usr/bin/perl";
    $conf{cpan}     //= "http://search.cpan.org/CPAN";
    $conf{metadb}   //= "http://cpanmetadb.plackperl.org/v1.0/package";
    $conf{su}       //= sub { system @_ };
    $conf{http}     //= HTTP::Tiny->new;

    bless \%conf, $class;
}

sub find {
    my ($self, $class, @args) = @_;

    load_class("CPAN::Package::$class")->new($self, @args);
}

1;
