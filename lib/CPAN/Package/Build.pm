package CPAN::Package::Build;

=head1 NAME

CPAN::Package::Build - Build a single distribution

=head1 SYNOPSIS

    my $build = CPAN::Package::Build->new($config, $jail, $dist);

    $build->unpack_dist;
    $build->configure_dist;
    $build->make_dist($_) for qw/build test install/;
    $build->fixup_install;

=head1 DESCRIPTION

An object of this class represents a build of a single distribution in a
single jail.

=cut

use 5.010;
use warnings;
use strict;
use autodie;

use Carp;
use Config;
use CPAN::Meta;
use CPAN::Meta::Requirements;
use Cwd                     qw/abs_path/;
use File::Find::Rule;
use File::Find::Rule::DirectoryEmpty;
use File::Slurp             qw/read_dir/;
use File::Path              qw/remove_tree/;
use File::Temp              qw/tempdir/;
use List::Util              qw/first/;
use Makefile::Parser;
use Module::Metadata;

use Moose;

extends "CPAN::Package::Base";

=head1 ATTRIBUTES

These all have read-only accessors, though some attributes are set as
part of the build process. All the paths are suitable to be passed to
L<hpath|CPAN::Package::Jail/hpath> or L<jpath|CPAN::Package::Jail/jpath>
of the C<jail>.

=head2 destdir

This is the temporary root directory to install the distribution under,
before packing it into a package. Set by L</unpack_dist>.

=cut

has destdir     => is => "rwp";

=head2 dist

The L<Dist|CPAN::Package::Dist> we are building.

=cut

has dist        => is => "rwp";

=head2 jail

The L<Jail|CPAN::Package::Jail> we are building in.

=cut

has jail        => is => "rwp";

=head2 make

This is the 'make' command to use, either F<./Build> or
C<$Config{make}>. Set by L</configure_dist>.

=cut

has make        => is => "rwp";

=head2 meta

This is the metadata read from F<{,MY}META.{json,yml}>. Set by
L</read_meta>.

=head2 has_meta

Returns true if a call to L</read_meta> has read valid metadata, false
otherwise.

=cut

has meta        => is => "rwp", predicate => 1;

=head2 name

The name of the distribution we are building. Set by L</read_meta>. This
is sanitised to only C<[-_a-zA-Z0-9]>.

=cut

sub name {
    my ($self) = @_;
    my $meta = $self->meta // $self->dist;
    $meta->name =~ s/[^-_a-zA-Z0-9]/_/gr;
}

=head2 version

The version of the distribution we are building. Set by L</read_meta>.
This is as specified in the metafile, so be careful: perl versions can
be weird.

=cut

sub version {
    my ($self) = @_;
    my $meta = $self->meta
        or $self->config->throw(Build => "no metadata for version");
    $meta->version;
}

=head2 wrkdir

This is the directory created for this build, containing C<wrksrc>,
C<destdir> and possibly other things. Set by L</unpack_dist>.

=cut

has wrkdir      => is => "rwp";

=head2 wrksrc

This is the directory the distribution unpacked into. Set by
L</unpack_dist>.

=cut

has wrksrc      => is => "rwp";

=head2 post_install

    my @post_install = $build->post_install;
    $build->post_install(@cmds);

The list of post-install commands this build needs to register with the
package created from it. Calling the accessor with arguments will push
additional commands onto the list. Normally set by L<<
->make_dist("install") |/make_dist >>.

=cut

has _post_install   => (
    is      => "ro",
    default => sub { [] },
);

sub post_install {
    my ($self, @new) = @_;
    my $pi = $self->_post_install;
    push @$pi, @new;
    wantarray ? @$pi : $pi;
}

=head1 METHODS

=head2 new

    my $build = CPAN::Package::Build->new($config, $jail, $dist);

C<new> is the constructor. C<$config> is a L<CPAN::Package>, C<$jail> is a
L<Jail|CPAN::Package::Jail>, and C<$dist> is a
L<Dist|CPAN::Package::Dist>.

=cut

sub BUILDARGS {
    my ($class, $config, $jail, $dist) = @_;
    return {
        config  => $config,
        jail    => $jail,
        dist    => $dist,
    };
}

=head2 read_meta

    my $meta = $build->read_meta("MYMETA");

Reads metadata from a file in C<wrksrc>, sets the C<meta> attribute, and
returns it. The argument is the basename of the metadata file to read,
normally F<META> before configuring and F<MYMETA> afterwards. Both
F<.json> and F<.yml> extensions will be tried.

Returns undef if the no appropriate file can be found, or if a file is
found but cannot be read by L<CPAN::Meta>. L</unpack_dist> must be
called first to unpack the tarball.

=cut

sub read_meta {
    my ($self, $file) = @_;

    my $wrksrc = $self->wrksrc
        or croak "read_meta needs an unpacked dist";

    for (map $self->jail->hpath("$wrksrc/$file.$_"), qw/json yml/) {
        -r or next;
        $self->say(3, "Reading metadata from $_");
        my $meta = CPAN::Meta->load_file($_)
            or return;
        $self->_set(meta => $meta);
        return $meta;
    }
    return;
}

=head2 needed

    my $deps = $build->needed($phase);

Reads the dependency specifications in the C<meta> attribute, and any
extra in the config's C<extradeps> attribute, and works out how to
satisfy the dependencies for C<$phase>, one of C<"configure">,
C<"build">, C<"test"> or C<"install">. The return value is a hashref
with the following keys:

=over 4

=item core

This is an arrayref of the hashrefs returned by L<< PkgDB->find_module
|CPAN::Package::PkgDB/find_module >>, indicating which requirements are
present in the core perl distribution.

=item pkg

This is another arrayref like C<core>, this time indicating which
requirements can be satisfied from already-built packages.

=item needed

This is another arrayref, indicating which requirements must be built
before we can proceed. These hashrefs have two keys: C<type>, which is
always C<"needed">, and C<module>, indicating the module required.

=back

If there are no configure-time dependencies specified, a dependency on
either ExtUtils::MakeMaker or Module::Build will be generated as
appropriate.

=cut

my %Phases = (
    configure   => [qw/configure/],
    build       => [qw/configure runtime build/],
    test        => [qw/configure runtime build test/],
    install     => [qw/runtime/],
);

sub needed {
    my ($self, $phase) = @_;

    my $conf    = $self->config;

    my $meta    = $self->meta;
    my $prereq  = $meta ? $meta->effective_prereqs
        : CPAN::Meta::Prereqs->new;
    my $cfreq   = $prereq->requirements_for("configure", "requires");

    if (!(() = $cfreq->required_modules)) {
        my $wrksrc  = $self->jail->hpath($self->wrksrc);
        my $maker   = -f "$wrksrc/Build.PL"
            ? "Module::Build" : "ExtUtils::MakeMaker";

        $self->say(2, "No configure requirements, assuming $maker");
        $cfreq->add_minimum($maker, 0);
    }

    my $req     = CPAN::Meta::Requirements->new;
    $req->add_requirements($prereq->requirements_for($_, "requires"))
        for @{$Phases{$phase}};

    my $extra   = $conf->extradeps_for($self->name)->{$phase};
    $req->add_string_requirement($_, $$extra{$_})
        for keys %$extra;

    my %mods;
    my $pkgdb   = $self->jail->pkgdb;
    for my $m ($req->required_modules) {
        my $dists = $pkgdb->find_module($m);
        my $d = first {
            $req->accepts_module($m, $$_{modver})
        } @$dists;

        $d //= {
            module  => $m,
            type    => "needed",
        };

        my $state = $$d{type};
        push @{$mods{$state}}, $d;

        my $ver = $req->requirements_for_module($m);
        $self->say(2, "Dep ($phase): $m $ver [$state]");
    }

    return \%mods;
}

=head2 satisfy_reqs

    my @mods = $build->satisfy_reqs($phase);

Attempt to satisfy the requirements for C<$phase> (as above), and return
a list of the C<"needed"> modules. Requirements of type C<"pkg"> will
have their packages installed. Returns a list of modules names for
modules which still need to be built.

=cut

sub satisfy_reqs {
    my ($self, $phase) = @_;

    my $config  = $self->config;
    my $pkg     = $self->jail->pkgtool;
    my $req     = $self->needed($phase);

    for my $d (@{$$req{pkg}}) {
        $self->sayf(2, "Install package for %s-%s", 
            $$d{dist}, $$d{distver});
        $pkg->install_my_pkgs({ 
            name    => $$d{dist},
            version => $$d{distver},
        });
    }

    return map $$_{module}, @{$$req{needed}};
}

=head2 deps_for_pkg

    my @deps = $build->deps_for_pkg;

Returns a list of hashrefs representing the runtime deps of the package
we are building. If there are unsatisfied deps it will throw a Needed
exception.

=cut

has deps_for_pkg => is => "lazy";

sub _build_deps_for_pkg {
    my ($self) = @_;

    my $req = $self->needed("install");
}

=head2 unpack_dist

    $build->unpack_dist;

Unpacks the distribution's tarball, and sets C<wrkdir>, C<wrksrc> and
C<destdir>. The dist must have been fetched first, by calling L<<
Dist->fetch|CPAN::Package::Dist/fetch >>.

Throws an C<Unpack>-type L<exception|CPAN::Package::Exception> if the
unpacking fails.

=cut

sub unpack_dist {
    my ($self) = @_;

    my $conf = $self->config;
    my $jail = $self->jail;
    my $dist = $self->dist->name;

    my $wrkdir  = "build/$dist";
    my $work    = $jail->hpath($wrkdir);
    if (-e $work) {
        $self->say(2, "Cleaning old workdir");
        $conf->su("rm", "-rf", $work);
    }

    mkdir $work;
    $self->_set(wrkdir => $wrkdir);

    $self->say(1, "Unpacking $dist");

    # libarchive++
    $conf->system("tar", "-xf", $self->dist->tar, "-C", $work);

    my @contents    = read_dir $work;
    my $wrksrc      = "$wrkdir/$contents[0]";
    my $hwrksrc     = $jail->hpath($wrksrc);

    @contents != 1 || ! -d $hwrksrc
        and $conf->throw("Unpack", 
            "does not unpack into a single directory");

    $self->_set(wrksrc => $wrksrc);

    my $patch = abs_path $conf->patches . "/$dist.patch";
    if (-f $patch) {
        $self->say(2, "Patching $dist");
        $conf->system("patch",
            "-d", $hwrksrc, "-i", $patch, "-p1");
    }

    my $dest    = "$wrkdir/tmproot";
    mkdir $jail->hpath($dest);
    $self->_set(destdir => $dest);
    
    return $self;
}

=head2 configure_dist

    $build->configure_dist;

Run the dist's configure step, either F<Makefile.PL> or F<Build.PL>. The
build must have been unpacked first with L</unpack_dist>, and the
C<configure> requirements satisfied.

The distribution will be configured (with C<DESTDIR> or C<--destdir>) to
install under the build's C<destdir>, so the files that should be
packaged can be located. It will also use C<INSTALLDIRS=site>, so that
upgraded versions of core modules do not produce packages which conflict
with the core perl package. This requires that the perl in question be
configured so that C<site> comes before C<perl> in C<@INC>, which is the
default from 5.12 onwards, but earlier versions will have to have been
built with the right Configure options.

Throws a C<Configure> L<exception|CPAN::Package::Exception> if the
configure step fails. Throws a C<Skip> exception if the configure step
runs successfully but produces no F<Makefile>/F<Build>, indicating the
dist does not build on this system. Throws a C<Skip> exception if the
distribution has neither F<Makefile.PL> nor F<Build.PL>.

=cut

sub configure_dist {
    my ($self) = @_;

    my $dist = $self->name;
    $self->say(1, "Configuring $dist");

    my $jail = $self->jail;
    my $dest = $jail->jpath($self->destdir);
    $self->say(2, "Using dest [$dest]");

    my $work    = $self->wrksrc;
    my $conf    = $self->config;
    my $perl    = $conf->perl;

    my $inst    = $jail->_extra_inst_args;

    if (-f $jail->hpath("$work/Build.PL")) {
        $jail->injail($work, $perl, "Build.PL", 
            "--destdir",            $dest,
            "--installdirs",        "site",
            (%$inst ? map +(
                "--install_path",   "$_=$$inst{$_}",
            ), keys %$inst : ()),
        )
            or $conf->throw("Configure", "Build.PL failed");

        -f $jail->hpath("$work/Build")
            or $conf->throw("Skip", "No Build created");
        $self->_set(make => "./Build");
    }
    elsif (-f $jail->hpath("$work/Makefile.PL")) {
        $jail->injail($work, $perl, "Makefile.PL", 
            "DESTDIR=$dest",
            "INSTALLDIRS=site",
            (%$inst ? map +(
                "INSTALLSITE\U$_\E=$$inst{$_}",
            ), keys %$inst : ()),
        )
            or $conf->throw("Configure", "Makefile.PL failed");

        -f $jail->hpath("$work/Makefile")
            or $conf->throw("Skip", "No Makefile created");
        $self->_set(make => $Config{make});
    }
    else {
        $conf->throw("Skip", "don't know how to configure $dist");
    }
}

sub _parse_build_target { 
    $_[0]->make ne "./Build" && "all";
}

sub _parse_install_target {
    my ($self) = @_;

    $self->make eq "./Build" and return;

    my $jail    = $self->jail;
    my $wrksrc  = $self->wrksrc;
    my $dest    = $jail->jpath($self->destdir);

    # MP uses while (<>) without localising $_
    local $_;
    my $M = Makefile::Parser->new;
    $M->parse($jail->hpath("$wrksrc/Makefile"))
        # if we can't parse it, just assume 'install' will work
        or return;

    my @cmds;
    if (my $t = $M->target("doc_site_install")) {
        push @cmds, $t->commands;
    }

    my $t = $M->target("install") or return;
    if (my @d = grep !/^(?:doc|pure)_install$/, $t->depends) {
        push @cmds, map $M->target($_)->commands, @d;
    }

    for (@cmds) {
        no warnings "uninitialized";
        # MP doesn't always expand variable properly
        1 while s/\$\((\w+)\)/$M->var($1)/gea;
        s/^[-@]{0,2} *//;
        s/\Q$dest//g;
    }

    $self->post_install(@cmds);

    # just do the standard install steps
    return "pure_install";
}

=head2 make_dist

    $build->make_dist($target);

Invoke a 'make' step for the build. C<$target> should be one of
C<"build">, C<"test">, C<"install">, or some other target the
distribution is known to support. Throws a C<Build>
L<exception|CPAN::Package::Exception> if the build step fails.

Before calling the build tool, this method will check if the Build
object supports a method C<"_parse_${target}_target">. If it does, this
method will be called, and the list of targets returned will be invoked
instead of the original. The following 'parse' methods are implemented
by default:

=over 4

=item build

This simply returns C<all> instead of C<build> if we are using a
F<Makefile>, since that is the standard name in that case.

=item install

For F<Makefile> builds only, this will attempt to parse the F<Makefile>
and extract the commands for any targets run by C<install> in addition
to C<pure_install>. If this succeeds, those commands will be appended to
the C<post_install> attribute for the package builder to use later, and
C<pure_install> will be returned as the target to build.

This parsing process is currently rather crude, but it is sufficient for
both the standard F<perllocal.pod> adjustments and the post-install
steps typically used by L<XML::SAX> modules.

=back

=cut

sub make_dist {
    my ($self, $target) = @_;

    $self->say(1, "\u${target}ing", $self->name, " ", $self->version);

    my $parse = "_parse_${target}_target";
    my @targets = ($self->can($parse) && $self->$parse) || $target;

    $self->jail->injail($self->wrksrc, $self->make, @targets)
        or $self->config->throw("Build", "$target failed");
}

=head2 fixup_install

    $build->fixup_install;

This runs any post-install cleanup that needs to occur before the build
is packaged. The build must have been compiled and installed into
C<destdir>. Currently this consists of

=over 4

=item *

Removing the C<destdir> from any paths in the F<.packlist> file.

=item *

Deleting F<perllocal.pod> to avoid unnecessary package conflicts. For
MakeMaker builds the post-install mechanism will ensure F<perllocal.pod>
gets updated anyway; for Module::Build builds this will not happen.

=item *

Removing any empty directories.

=back

=cut

sub fixup_install {
    my ($self) = @_;

    my $FFR     = "File::Find::Rule";
    my $jail    = $self->jail;
    my $dest    = $self->destdir;
    my $hdest   = $jail->hpath($dest);
    my $jdest   = $jail->jpath($dest);
    my $config  = $self->config;

    my @plists  = $FFR->file->name(".packlist")->in($hdest);
    @plists and $config->su($^X, "-pi", "-es,\Q$jdest\E,,", @plists);
    
    # Forget perllocal.pod for now. Ideally we'd fix it up in a
    # post-install script.
    $config->su("rm", "-f",
        $FFR->file->name("perllocal.pod")->in($hdest));

    while (my @e = $FFR->directoryempty->in($hdest)) {
        $config->su("rmdir", @e);;
    }
}

=head2 provides

    my $modules = $build->provides;

This runs L<< Module::Metadata->provides|Module::Metadata/provides >>
against C<destdir>, and returns the result.

=cut

sub provides {
    my ($self) = @_;
    Module::Metadata->provides(
        dir     => $self->jail->hpath($self->destdir),
        prefix  => "",
        version => 2,
    );
}

1;

=head1 SEE ALSO

L<CPAN::Package>

=head1 BUGS

Please report to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.
