package CPAN::Package;

use 5.010;
use warnings;
use strict;
use autodie;

our $VERSION = "1";

use Carp;
use Class::Load     qw/load_class/;
use File::Spec::Functions   qw/devnull/;
use HTTP::Tiny;
use Scalar::Util    qw/blessed/;
use Scope::Guard    qw/guard/;

for my $a (qw/ 
    jail perl prefix builtby
    cpan metadb dist packages pkgdb
    http verb msgfh logfh errfh
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
    $conf{su}       //= sub { $_[0]->system(@_[1..$#_]) };
    $conf{http}     //= HTTP::Tiny->new;
    $conf{verb}     //= 100;

    $conf{msgfh} or open $conf{msgfh}, ">&", \*STDOUT;
    $conf{errfh} or open $conf{errfh}, ">&", \*STDERR;

    unless ($conf{logfh}) {
        my $log = delete($conf{log}) // devnull;
        open $conf{logfh}, ">", $log;
    }

    if ($conf{redirect_stdh}) {
        open STDOUT, ">&", $conf{logfh};
        open STDERR, ">&", $conf{logfh};
    }

    bless \%conf, $class;
}

sub say {
    my ($self, $verb, @what) = @_;

    my $pfx = ("=" x $verb) . "=>";
    local $, = " ";
    say { $self->logfh } $pfx, @what;
    $self->verb >= $verb and say { $self->msgfh } $pfx, @what;
}

sub sayf {
    my ($self, $verb, $fmt, @args) = @_;

    $self->say($verb, sprintf $fmt, @args);
}

sub system {
    my ($self, @cmd) = @_;

    0 == system @cmd;
}

sub su {
    my ($self, @cmd) = @_;
    $self->{su}->($self, @cmd);
}

sub find {
    my ($self, $class, @args) = @_;

    load_class("CPAN::Package::$class")->new($self, @args);
}

1;
