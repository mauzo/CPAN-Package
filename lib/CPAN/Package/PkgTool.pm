package CPAN::Package::PkgTool;

use 5.010;
use warnings;
use strict;

use parent "CPAN::Package::Base";

use Carp;
use File::Find::Rule;
use File::Slurp         qw/write_file/;
use File::Spec::Functions   qw/abs2rel/;

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

sub create_pkg {
    my ($self, $build) = @_;

    my $jail    = $self->jail;
    $build->jail == $jail
        or croak "This PkgTool is for the wrong jail";

    my $wrkdir  = $build->wrkdir;
    my $mandir  = $jail->hpath("$wrkdir/manifest");
    mkdir $mandir;

    my $dest    = $jail->hpath($build->destdir);
    my $FFR     = "File::Find::Rule";

    my %core    = map +($_, 1), qw[
        . opt opt/perl opt/perl/lib
        opt/perl/lib/5.16.3 opt/perl/lib/5.16.3/amd64-freebsd
        opt/perl/lib/5.16.3/amd64-freebsd/auto
        opt/perl/lib/site_perl opt/perl/lib/site_perl/5.16.3
        opt/perl/lib/site_perl/5.16.3/amd64-freebsd
    ];

    my $plist   = 
        join "", 
        (
            map "/$_\n",
            map abs2rel($_, $dest),
            $FFR->file->in($dest),
        ), (
            map "\@dirrmtry /$_\n",
            grep !$core{$_},
            map abs2rel($_, $dest),
            $FFR->directory->in($dest),
        );
    write_file "$mandir/pkg-plist", $plist;

    $jail->injail($build->wrkdir, "cat", "manifest/pkg-plist");
}

1;
