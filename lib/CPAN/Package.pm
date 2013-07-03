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
    jail perl
    cpan metadb dist packages
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

sub new_obj {
    my ($self, $class, @args) = @_;

    load_class("CPAN::Package::$class")->new(
        config  => $self,
        @args,
    );
}

sub find {
    my ($self, $type, @args) = @_;

    my $class = load_class("CPAN::Package::$type");
    $self->new_obj($type, $class->find($self, @args));
}

sub build_for {
    my ($self, $jail, $dist) = @_;

    $self->new_obj("Build",
        jail    => $jail,
        dist    => $dist,
    );
}

sub pkg_tool {
    my ($self, $jail) = @_;

    $self->new_obj("PkgTool",
        jail    => $jail,
    );
}

1;
