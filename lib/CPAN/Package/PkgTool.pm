package CPAN::Package::PkgTool;

=head1 NAME

CPAN::Package::PkgTool - The interface to the OS package builder

=head1 SYNOPSIS

    my $pkg = CPAN::Package::PkgTool->new($config, $jail);
    $pkg->setup_jail;

    $pkg->install_my_pkgs($pkg->pkg_for_dist($dist));

    $pkg->create_pkg($build);

=head1 DESCRIPTION

This class is the interface between L<CPAN::Package> and the OS
package-building tool it is creating packages with. Currently that tool
is always FreeBSD's B<pkg>, though in future this class will be
subclassable to allow other package tools.

=cut

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

=head1 ATTRIBUTES

=head2 jail

The jail this PkgTool is for.

=cut

for my $s (qw/ jail /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

=head1 METHODS

=head2 new

    my $pkg = CPAN::Package::PkgTool->new($config, $jail);

This is the constructor.

=cut

sub BUILDARGS {
    my ($class, $config, $jail) = @_;
    return {
        config  => $config,
        jail    => $jail,
    };
}

=head2 setup_jail

    $pkg->setup_jail;

A pkgtool may need to set things up withing the jail before it can be
used. In the case of B<pkg>, this untars a copy of B<pkg-static> from
the F</packages/Latest/pkg.txz> package.

=cut

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

=head2 install_sys_pkgs

    $pkg->install_sys_pkgs(@pkgs);

Install some packages from the system package repository (F</packages>,
for B<poudriere> jails). C<@pkgs> is a list of package names as
understood by the package tool.

=cut

sub install_sys_pkgs {
    my ($self, @pkgs) = @_;

    my @new = grep !$self->is_installed($_), @pkgs
        or return;
    $self->_pkg("", "add",
        map "/packages/All/$_.txz", 
        @new
    );
}

=head2 install_my_pkgs

    $pkg->install_my_pkgs(@dists);

Install packages we have built. C<@dists> is a list of hashrefs as
returned by L</pkg_for_dist>; the corresponding packages will be
installed in the jail.

=cut

sub install_my_pkgs {
    my ($self, @dists) = @_;

    my @new = 
        grep !$self->is_installed($_),
        map "$$_{name}-$$_{version}",
        map $self->pkg_for_dist($_),
        @dists
        or return;
    $self->_pkg("", "add",
        map $self->jail->jpath("pkg/$_.txz"), 
        @new
    );
}

=head2 is_installed

    $pkg->is_installed($pkg);

Returns a boolean indicating whether the given package is installed.
C<$pkg> is a package name as understood by the package tool.

=cut

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

=head2 pkg_for_dist

    my $pkg_info = $pkg->pkg_for_dist($dist);

Returns a hashref describing the properties of the package that would be
created for C<$dist>, which is a L<Dist|CPAN::Package::Dist>. The
contents of this hashref are unspecified, but it can be passed to
L</install_my_pkgs> to install the corresponding package.

=cut

sub pkg_for_dist {
    my ($self, $dist) = @_;
    my $name = $dist->name;
    return {
        name    => "cpan2pkg-$name",
        version => $dist->version,
        origin  => "cpan2pkg/$name",
    };
}

=head2 deps_for_build

    my @deps = $pkg->deps_for_build($build);

Returns a list of hashrefs (as returned by L</pkg_for_dist>), indicating
the dependencies of the given L<Build|CPAN::Package::Build>.

=cut

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

    $self->say(3, "Full deps:\n$deps");

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

sub _write_scripts {
    my ($self, $build, $mandir) = @_;

    my @post = $build->post_install or return;
    $self->say(2, "Post-install commands:");
    $self->say(2, "  $_") for @post;

    write_file "$mandir/+POST_INSTALL",
        join "\n",
        @post;
}

=head2 create_pkg

    $pkg->create_pkg($build);

Create a package of the given L<Build|CPAN::Package::Build>. The Build
must have been built and installed, and had
L<C<fixup_install>|CPAN::Package::Build/fixup_install> run on it. The
newly-created package will be registered in the
L<PkgDB|CPAN::Package::PkgDB>.

=cut

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
    $self->_write_scripts($build, $mandir);

    $self->_pkg($wrkdir, "create",
        -o  => $jail->jpath("pkg"),
        -r  => $jail->jpath($build->destdir),
        -m  => "manifest",
        -p  => "manifest/pkg-plist",
    );

    $jail->pkgdb->register_build($build);
}

1;

=head1 SEE ALSO

L<CPAN::Package>.

=head1 BUGS

Please report bugs to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.

