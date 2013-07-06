package CPAN::Package::PkgTool;

use 5.010;
use warnings;
use strict;

use parent "CPAN::Package::Base";

use Capture::Tiny           qw/capture_stdout/;
use Carp;
use File::Find::Rule;
use File::Slurp             qw/write_file/;
use File::Spec::Functions   qw/abs2rel/;
use List::MoreUtils         qw/uniq/;

for my $s (qw/ jail /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

sub BUILDARGS {
    my ($class, $config, $jail) = @_;
    return {
        config  => $config,
        jail    => $jail,
    };
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

sub install_sys_pkgs {
    my ($self, @pkgs) = @_;

    my @new = grep !$self->is_installed($_), @pkgs
        or return;
    $self->_pkg("", "add",
        map "/packages/All/$_.txz", 
        @new
    );
}

sub install_my_pkgs {
    my ($self, @pkgs) = @_;

    my @new = grep !$self->is_installed($_), @pkgs
        or return;
    $self->_pkg("", "add",
        map $self->jail->jpath("pkg/$_.txz"), 
        @new
    );
}

sub is_installed {
    my ($self, $pkg) = @_;

    $self->_pkg("", "info", "-qe", $pkg);
    return $? == 0;
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

sub pkg_for_dist {
    my ($self, $dist) = @_;
    my $name = $dist->name;
    return {
        name    => "cpan2pkg-$name",
        version => $dist->version,
        origin  => "cpan2pkg/$name",
    };
}

sub deps_for_build {
    my ($self, $build) = @_;
    
    my $conf    = $self->config;
    my $req     = $build->needed("install");
    return
        { 
            name    => "opt-perl", 
            version => "5.16.3", 
            origin  => "lang/opt-perl",
        },
        map $self->pkg_for_dist($_),
        map $conf->find(Dist =>
            name    => $$_{dist},
            version => $$_{distver},
        ),
        @{ $$req{pkg} };
}

sub _all_deps {
    my ($self, $pkg) = @_;

    capture_stdout {
        $self->_pkg("", "query", 
            "  %${_}n: { version: %${_}v, origin: %${_}o }",
            $$pkg{origin}
        )
            for "", "d";
    };
}

sub _write_manifest {
    my ($self, $build, $mandir) = @_;

    my $dist    = $build->dist;
    my $name    = $dist->name;
    my $info    = $self->pkg_for_dist($dist);
    my @deps    = $self->deps_for_build($build);
    my $maint   = $self->config("builtby");
    my $prefix  = $self->config("prefix");

    my $deps    = 
        join "\n",
        uniq
        map split("\n"),
        map $self->_all_deps($_),
        @deps;

    # This must not contain tabs. It upsets pkg.
    write_file "$mandir/+MANIFEST", <<MANIFEST;
name:       $$info{name}
origin:     $$info{origin}
version:    $$info{version}
comment:    $name built with CPAN::Package.
desc:       $name built with CPAN::Package.
www:        http://search.cpan.org/dist/$name
maintainer: $maint
prefix:     $prefix
deps:
$deps
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

    $jail->pkgdb->register_build($build);
}

1;
