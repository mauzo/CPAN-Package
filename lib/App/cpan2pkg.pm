package App::cpan2pkg;

=head1 NAME

App::cpan2pkg - The implementation of L<cpan2pkg>.

=head1 SYNOPSIS

    use App::cpan2pkg;

    exit App::cpan2pkg->new(@ARGV)->run;

=cut

use 5.010;
use warnings;
use strict;
use autodie;

use parent "CPAN::Package::Base";

use CPAN::Package;
use Cwd             qw/abs_path/;
use Data::Dump      qw/pp/;
use File::Basename  qw/dirname/;
use File::Spec::Functions   qw/rel2abs/;
use Getopt::Long    qw/GetOptionsFromArray/;
use List::Util      qw/first/;
use Try::Tiny;
use YAML::XS        qw/LoadFile/;

=head1 DESCRIPTION

This module is the implementation of L<cpan2pkg>. It handles parsing the
command-line arguments, creating an appropriate L<CPAN::Package> object,
and building the modules specified on the command line.

=head1 ATTRIBUTES

These all have read-only accessors. Some are modified by other methods.

=head2 dist

=head2 build

The L<Build|CPAN::Package::Build> and L<Dist|CPAN::Package::Dist>
objects for the distribution currently being built. Both are cleared by
L</pop_mod>; C<build> is set by L</build_one_dist>, and C<dist> by
L</build_some_dists>.

=head2 jail

The L<Jail|CPAN::Package::Jail> we are working with.

=head2 log

The logfile we are writing to.

=head2 mod

The module we are currently working on. Set by L</pop_mod>.

=head2 mods

An arrayref containing the current list of modules still to be built.
This arrayref should not be manipulated directly, but with the
L</push_mods> and L</pop_mod> methods.

=head2 verbose

The verbosity passed on the command-line. This will be augmented by the
verbosity in the config file.

=cut

for my $s (qw/ jail log mod mods dist build verbose /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

=head1 METHODS

=head2 new

    my $app = App::cpan2pkg->new(@ARGV);

This is the constructor. It should be passed C<@ARGV>, or some
equivalent array of arguments, which it will parse with L<Getopt::Long>.
See L<cpan2pkg> for documentation of the arguments accepted.

Once the command-line arguments have been parsed, this will open and
parse the config file, open the log filehandle, and construct the
L<CPAN::Package> and L<Jail|CPAN::Package::Jail> objects which will be
used for the build.

This method is also responsible for converting the contents of the
configuration file into suitable arguments for L<< CPAN::Package->new
|CPAN::Package/new >>, so it will convert the C<dist>, C<pkg>, C<pkgdb>
and C<log> attributes into absolute paths, and convert the C<su>
attribute into a subref. It will also set C<redirect_stdh> so that the
build output goes to the logfile.

=cut

sub BUILDARGS {
    my ($class, @argv) = @_;
    
    Getopt::Long::Configure qw/bundling/;
    GetOptionsFromArray \@argv, \my %opts, qw/
        config|f=s
        jail|j=s
        log|l=s
        verbose|v:+
    /;

    # reverse so we pop them off in the right order
    $opts{mods} = [reverse @argv];

    \%opts;
}

sub BUILD {
    my ($self) = @_;

    my $conf    = $self->config;
    my $yaml    = LoadFile $conf;

    $yaml->{verbose}        += $self->verbose;
    $yaml->{redirect_stdh}  = 1;

    $self->jail or $self->_set(jail => delete $yaml->{jail});
    $self->log  and $yaml->{log} = $self->log;
    
    my @su = split " ", $yaml->{su};
    $yaml->{su} = sub {
        my ($conf, @cmd) = @_;
        $conf->system(@su, @cmd);
    };

    my $cwd     = dirname abs_path $conf;
    for (qw/ dist pkg pkgdb log /) {
        my $rel = $yaml->{$_} or next;
        my $abs = rel2abs $rel, $cwd;
        $yaml->{$_} = $abs;
    }

    $conf       = CPAN::Package->new(%$yaml);
    $self->_set(config => $conf);

    my $jail    = $self->jail;
    $self->_set(jail => $conf->find(Jail => $jail));
}

=head2 tried

=head2 failed

    my $tried = $app->tried($dist);
    $app->tried($dist, 1);
    my @tried = $app->tried;

These manage the list of modules we have tried and failed to build,
respectively. With one argument, both return a boolean indicating if the
given dist has been tried; with two, both set the status of the given
dist. With no arguments they return a sorted list of all modules tried
or failed.

C<tried> is keyed by distfile, to avoid ambiguity. C<failed> has entries
for both distfiles and modules, since some modules fail because they
can't be resolved.

=cut

for my $h (qw/ mod_tried dist_tried failed /) {
    no strict "refs";
    *$h = sub {
        my ($self, $key, $set) = @_;

        my $hash = $self->{$h} //= {};
        @_ < 2 and return sort keys %$hash;
        
        if (@_ > 2) {
            $hash->{$key} = $set;
            $self->config->sayf(3, "Marking %s(%s): %s", 
                $h, $key, $set);
        }
        $hash->{$key};
    };
}

=head2 push_mods

    $app->push_mods(@mods);

Add modules to the list to be built. This is a push, meaning the modules
added will be tried before those already on the list, but they will be
tried in the order they are given.

=cut

sub push_mods {
    my ($self, @mods) = @_;
    my $mods = $self->{mods} //= [];
    push @$mods, reverse @mods;
}

=head2 pop_mod

    my $mod = $app->pop_mod;

Pop the first module off the list, set the C<mod> attribute, and clear
the C<dist> and C<build> attributes.

=cut

sub pop_mod {
    my ($self) = @_;
    my $mod = pop @{ $self->mods };
    $self->_set(mod => $mod);
    $self->_set($_ => undef) for qw/dist build/;
    $mod;
}

=head2 check_reqs

    $app->check_reqs($phase);

Checks that all the dependencies of the current build are available.
C<$phase> specifies the phase of the build to check for (see
L<CPAN::Meta::Prereqs>). If any are missing, throws a C<Needed>
L<exception|CPAN::Package::Exception> containing the list of modules
needed. If any have already been tried and failed, throws a C<Fail>
exception.

This requires C<< $app->build >> to be set, the build to be unpacked,
and the build metadata to be set.

=cut

sub check_reqs {
    my ($self, $phase) = @_;

    my $conf    = $self->config;
    my $build   = $self->build;

    if (my @needed = $build->satisfy_reqs($phase)) {
        if (my $done = first { $self->mod_tried($_) } @needed) {
            $conf->throw("Fail", "Already tried to build $done");
        }
        $conf->throw("Needed", \@needed);
    }
};

=head2 build_one_dist

    $app->build_one_dist;

Builds the current C<< $app->dist >>. This creates a
L<Build|CPAN::Package::Build> object, runs through the steps to build
the distribution, and turns it into a package.

=cut

sub build_one_dist {
    my ($self) = @_;

    my $dist    = $self->dist;
    my $jail    = $self->jail;
    my $pkg     = $jail->pkgtool;

    $dist->fetch;

    my $build = $self->config->find(Build => $jail, $dist);
    $self->_set(build => $build);
    $build->unpack_dist;
    $build->read_meta("META");

    $self->check_reqs("configure");
    $build->configure_dist;
    $build->read_meta("MYMETA");

    $self->check_reqs("build");
    $build->make_dist($_) for qw/build install/;
    $build->fixup_install;

    $pkg->create_pkg($build);
}

=head2 build_failed

    $app->build_failed($exception);

This method is called when a build fails by throwing an exception.
C<$exception> should be a L<CPAN::Package::Exception>, and
C<build_failed> will attempt to recover.

=cut

sub build_failed {
    my ($self, $ex) = @_;

    my $conf = $self->config;
    my $type = $ex->type;
    my $info = $ex->info;
    my $dist = $self->dist;
    my $name = $dist ? $dist->name : $self->mod;

    if ($type eq "Needed") {
        $conf->say(1, "Deferring $name");
        $self->dist_tried($dist->distfile, 0);
        $self->mod_tried($self->mod, 0);
        $self->push_mods(@$info, $self->mod);
    }
    elsif ($type eq "Skip") {
        $conf->say(1, "Skipping $name");
        $conf->say(2, "  $info");
    }
    else {
        $self->failed($name, 1);
        $conf->say(1, "$name failed");
        $conf->say(2, "  $type ($info)");
    }
}

=head2 build_some_dists

    $app->build_some_dists;

Run through the list of modules in C<< $app->mods >>, resolve each to a
L<Dist|CPAN::Package::Dist>, build that dist with L</build_one_dist>,
and handle any exceptions thrown by the build. This is the main build
loop.

=cut

sub build_some_dists {
    my ($self) = @_;

    my $conf = $self->config;

    while (my $mod = $self->pop_mod) {
        try {
            $self->mod_tried($mod)
                and $conf->throw(Skip => "already tried $mod");
            $self->mod_tried($mod, 1);

            my $dist        = $conf->resolve_dist($mod);
            my $distname    = $dist->name;
            $self->_set(dist => $dist);

            $self->dist_tried($dist->distfile)
                and $conf->throw("Skip", "Already tried $distname");
            $self->dist_tried($dist->distfile, 1);

            $self->build_one_dist;
        }
        catch {
            eval { $_->isa("CPAN::Package::Exception") }
                or $_ = $conf->find(Exception => Fail => $_);

            $self->build_failed($_);
        };
    }
}

=head2 run

    $app->run;

This starts the jail, installs the initial list of packages, calls
L</build_some_dists> to do the builds, and cleans up afterwards. Returns
an exit code.

=cut

sub run {
    my ($self) = @_;

    local $SIG{INT} = sub {
        warn "Interrupt, exiting\n";
        exit 0;
    };

    my $Conf    = $self->config;
    my $jail    = $self->jail;
    my $pkg     = $jail->pkgtool;
    my $pkgdb   = $jail->pkgdb;

    $jail->start;
    $pkg->install_sys_pkgs($Conf->initpkgs);

    $self->build_some_dists;

    my @failed = $self->failed;
    if (@failed) {
        $Conf->say(1, "Failed to build:");
        $Conf->say(1, "  $_") for @failed;
    }

    $jail->injail("", "sh", "-c", "$ENV{SHELL} >/dev/tty 2>&1");

    $jail->stop;

    return @failed ? 1 : 0;
}

1;

=head1 BUGS

This module is part of L<CPAN::Package>, so please report any bugs to
L<bug-CPAN-Package@rt.cpan.org>.

=head1 SEE ALSO

L<cpan2pkg>, L<CPAN::Package>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.


