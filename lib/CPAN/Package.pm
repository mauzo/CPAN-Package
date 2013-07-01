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
    jail perl perlpkg
    cpan metadb dist packages
    su http
/) {
    no strict "refs";
    *$a = sub { $_[0]{$a} };
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
    my ($self, $type, @args) = @_;

    my $class = "CPAN::Package::$type";
    load_class($class)->new(
        config  => $self,
        $class->find($self, @args),
    );
}

sub build_for {
    my ($self, $jail, $dist) = @_;

    load_class("CPAN::Package::Build")->new(
        config  => $self,
        jail    => $jail,
        dist    => $dist,
    );
}

1;
