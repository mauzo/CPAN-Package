package CPAN::Package::PkgTool;

use 5.010;
use warnings;
use strict;

use parent "CPAN::Package::Base";

for my $s (qw/ jail /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

sub setup_jail {
    my ($self) = @_;

    $self->jail->injail(".", "tar", "-xvf", "/packages/Latest/pkg.txz", 
        "-s,/.*/,,", "*/pkg-static");
}

sub _pkg {
    my ($self, $cwd, @args) = @_;

    my $jail = $self->jail;
    $jail->injail($cwd, $jail->jpath("pkg-static"), @args);
}

sub install_pkgs {
    my ($self, @pkgs) = @_;

    $self->_pkg("", "add", @pkgs);
}

1;
