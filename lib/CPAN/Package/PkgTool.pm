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

sub _write_plist {
    my ($self, $build, $plist) = @_;

    my $dest    = $self->jail->hpath($build->destdir);
    my $FFR     = "File::Find::Rule";

    my %core    = map +($_, 1), qw[
        . opt opt/perl opt/perl/lib
        opt/perl/lib/5.16.3 opt/perl/lib/5.16.3/amd64-freebsd
        opt/perl/lib/5.16.3/amd64-freebsd/auto
        opt/perl/lib/site_perl opt/perl/lib/site_perl/5.16.3
        opt/perl/lib/site_perl/5.16.3/amd64-freebsd
    ];

    write_file $plist,
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
}

sub _write_manifest {
    my ($self, $build, $mandir) = @_;

    my $name    = $build->dist->name;
    my $version = $build->dist->version;
    my $maint   = $self->config("builtby");
    my $prefix  = $self->config("prefix");

    # This must not contain tabs. It upsets pkg.
    write_file "$mandir/+MANIFEST", <<MANIFEST;
name:       cpan2pkg-$name
origin:     cpan2pkg/$name
version:    $version
comment:    $name built with CPAN::Package.
desc:       $name built with CPAN::Package.
www:        http://search.cpan.org/dist/$name
maintainer: $maint
prefix:     $prefix
dep:
    opt-perl: { version: 5.16.3, origin: lang/opt-perl }
MANIFEST
}


sub create_pkg {
    my ($self, $build) = @_;

    my $jail    = $self->jail;
    $build->jail == $jail
        or croak "This PkgTool is for the wrong jail";

    my $wrkdir  = $build->wrkdir;
    my $mandir  = $jail->hpath("$wrkdir/manifest");
    mkdir $mandir;

    $self->_write_plist($build, "$mandir/pkg-plist");
    $self->_write_manifest($build, $mandir);

    $self->_pkg($wrkdir, "create",
        -o  => $jail->jpath("pkg"),
        -r  => $jail->jpath($build->destdir),
        -m  => "manifest",
        -p  => "manifest/pkg-plist",
    );
}

1;
