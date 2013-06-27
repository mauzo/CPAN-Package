package CPAN::Package::Config;

use warnings;
use strict;

use HTTP::Tiny;

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
    $class->new(
        config  => $self,
        $class->find($self, @args),
    );
}

1;
