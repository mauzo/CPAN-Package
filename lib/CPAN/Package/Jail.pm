package CPAN::Package::Jail;

=head1 NAME

CPAN::Package::Jail - A build environment for CPAN::Package

=head1 SYNOPSIS

    my $jail = CPAN::Package::Jail->new($config, $name);
    $jail->start;
    $jail->injail(".", "ls", "-l");
    $jail->stop;

=head1 DESCRIPTION

L<CPAN::Package> performs its builds inside a jail, to prevent them from
interfering with the running system. Objects of this class represent
these jails. Currently the only supported type of jail is a FreeBSD jail
managed by B<poudriere>, but I hope to support other types of jail
(plain BSD jails, ordinary chroot jails, &c.) in future.

=cut

use 5.010;
use warnings;
use strict;
use autodie;

use Capture::Tiny   qw/capture_stdout/;
use File::Path      qw/make_path/;
use File::Slurp     qw/read_dir write_file/;
use Data::Dump qw/pp/;

use Moo;

extends "CPAN::Package::Base";

=head1 ATTRIBUTES

All of these have read-only accessors.

=head2 jname

The internal name of the jail, as used by the jail manipulation
commands.

=cut

has jname   => is => "ro";

=head2 name

The name of the jail, as supplied to C<new>.

=cut

has name    => is => "ro";

=head2 pkgtool

    my $pkg = $jail->pkgtool;

A L<PkgTool|CPAN::Package::PkgTool> for this jail.

=cut

has pkgtool => (
    is      => "lazy",
    builder => sub { $_[0]->config->find(PkgTool => $_[0]) },
);

=head2 pkgdb

    my $pkgdb = $jail->pkgdb;

A L<PkgDB|CPAN::Package::PkgDB> for this jail.

=cut

has pkgdb => (
    is      => "lazy",
    builder => sub { $_[0]->config->find(PkgDB => $_[0]) },
);

has _pset    => is => "ro";

=head2 root

The root directory of the jail in the host filesystem. This may not be
set until after L</start> has been called.

=cut

has root    => is => "rwp";

=head2 running

A boolean which indicates whether or not the jail is running. Jails
start not running. This will not track external changes to the jail's
state.

=cut

has running => is => "rwp";

=head2 umount

A list of mountpoints which need to be unmounted when the jail is
stopped.

=cut

has umount => (
    is      => "rwp",
    reader  => "_umount",
    default => sub { [] },
);

sub umount { @{ $_[0]->_umount } }

=begin private

=head2 _extra_inst_args

A hashref containing any extra install directory locations we should
use. The keys are locations (C<bin>, C<script> &c.) and the values are
paths.

=cut

has _extra_inst_args    => is => "lazy";

sub _build__extra_inst_args {
    my ($self)  = @_;

    my %install;
    for my $dir (qw/bin script/) {
        my ($core, $site) = $self->perl_V("install$dir", "installsite$dir");
        if ($core eq $site) {
            # There is currently no satisfactory solution to the site_bin
            # problem. Since pkg won't let me install pkgs with conflicting
            # files, just punt for now with a real site_bin directory.
            $install{$dir} = $core =~ s[/(?!.*/)][/site_]r;
            $self->warn(<<W);
INSTALLSITE\U$dir\E is set equal to INSTALL\U$dir\E. Changing it to
W
            $self->warnf(<<W, $install{$dir});
[%s] to avoid conflicts.
W
        }
    }

    \%install;
}

=head2 _perlV

A cache for C<perl -V>.

=cut

has _perlV  => (
    is      => "ro",
    lazy    => 1,
    default => sub { +{} },
);

has _pname  => is => "ro";

=end private

=head1 METHODS

=head2 new

    my $jail = CPAN::Package::Jail->new($config, $name);

This is the constructor. C<$name> should be the name as C<poudriere jail
-j> understands it; C<jname> will be set to C<"$name-default">.

=cut

sub BUILDARGS {
    my ($class, $config, $name) = @_;

    my $conf    = $config->config("Jail", $name) // {};
    my $set     = $conf->{set};
    my $pname   = $conf->{pname} // $name;

    return {
        config  => $config,
        name    => $name,
        jname   => "$pname-default" . ($set ? "-$set" : ""),
        _pname  => $pname,
        running => 0,
        _pset    => $set,
    };
}

=head2 su

    $jail->su(@cmd);

This simply forwards to L<< C<< $jail->config->su >>|CPAN::Package/su >>.

=cut

sub su {
    my ($self, @cmd) = @_;
    $self->config->su(@cmd);
}

sub perl_V {
    my ($self, @opt) = @_;

    my $cache   = $self->_perlV;
    my @need    = grep !exists $cache->{$_}, @opt;

    if (@need) {
        my $perl    = $self->config("perl");

        my $V = capture_stdout {
            $self->injail("", $perl, map "-V:$_", @need);
        };
        $$cache{$1} = $2 while $V =~ /^(\w+)='([^'\n]+)';$/gmsa;
    }

    @$cache{@opt};
}

sub mount_tmpfs {
    my ($self, $on) = @_;
    $self->su("mkdir", "-p", $on);
    $self->su("mount", "-t", "tmpfs", "-o", "mode=777", "tmpfs", $on);
}

sub mount_nullfs {
    my ($self, $mode, $dir, $on) = @_;
    $self->su("mkdir", "-p", $dir, $on);
    $self->su("mount", "-t", "nullfs", "-$mode", $dir, $on);
}

=head2 hpath

=head2 jpath

    my $hpath   = $jail->hpath($path);
    my $jpath   = $jail->jpath($path);

These methods make a path suitable for use on the host system or within
the jail respectively. Starting the jail will have created a suitable
temporary directory for us to work in; C<$path> will be interpreted
relative to this directory.

=cut

sub jpath { "/cpan2pkg/$_[1]" }
sub hpath { $_[0]->root . $_[0]->jpath($_[1]) }

sub _injail_sh { <<'SH' }
#!/bin/sh

set -e

export LC_ALL=C TZ=UTC

export PERL5_CPAN_IS_RUNNING=$$
export PERL5_CPANPLUS_IS_RUNNING=$$
export PERL_MM_USE_DEFAULT=1

export ABI_FILE=/usr/lib/crt1.o
export REPOS_DIR=/cpan2pkg/repos

cd "$1"
shift

exec "$@"
SH

=head2 start

    $jail->start

Start the jail. In addition to starting the jail itself, this method
will create a tmpfs at F</cpan2pkg> inside the jail, with the following
contents:

=over 4

=item F<build>

The directory in which L<wrkdirs|CPAN::Package::Build/wrkdir> are
located.

=item F<injail>

A shell script used for running programs inside the jail.

=item F<pkg>

A nullfs mount of the L<packages directory|CPAN::Package/packages> for
this jail.

=back

along with possibly other things created by the
L<PkgTool|CPAN::Package::PkgTool/setup_jail>.

=cut

sub start {
    my ($self) = @_;

    my $config  = $self->config;
    my $jname   = $self->jname;
    my $name    = $self->name;
    my $pname   = $self->_pname;
    my $set     = $self->_pset;

    if ($self->running) {
        $self->say(3, "Jail $name already running");
        return;
    }

    $self->say(1, "Starting jail $name");

    $self->su( "poudriere", "jail", "-s",
        "-j", $pname, 
        ($set ? ("-z", $set) : ()),
    );
    $self->_set(running => 1);

    my $root = capture_stdout {
        $config->system("jls", "-j", $jname, "path");
    };
    chomp $root;
    $self->_set(root => $root);

    $self->mount_tmpfs($self->hpath(""));
    mkdir $self->hpath("build");

    my $pkg = $config->packages . "/$jname";
    $self->mount_nullfs("w", $pkg, $self->hpath("pkg"));
    $self->_set(umount => ["pkg", ""]);

    write_file $self->hpath("injail"), $self->_injail_sh;

    $self->pkgtool->setup_jail;

    return $self;
}

=head1 injail

    $jail->injail($dir, @cmd);

Run a command inside the jail. C<$dir> is the working directory to use,
and will be passed through L<jpath>. C<@cmd> is the command, as a list;
there will be no splitting on whitespace.

This uses B<jexec>, which requires root, so it will run the command via
L</su>.

=cut

sub injail {
    my ($self, $dir, @cmd) = @_;

    my $cwd     = $self->jpath($dir);
    my $cmd     = 
        join " ",
        map /["'`(){}<>| \t*?!\$\\;#]/
            ? qq/"/ . s/(["`\$\\])/\\$1/gr . qq/"/ 
            : $_,
        @cmd;
    $self->say(3, "Running '$cmd' in $cwd");

    $self->su("jexec", $self->jname, 
        "/bin/sh", $self->jpath("injail"), $cwd,
        @cmd);
}

=head2 stop

    $jail->stop;

Stops the jail and unmounts any filesystems we mounted when we started
it.

=cut

sub stop {
    my ($self) = @_;

    my $set = $self->_pset;

    $self->sayf(1, "Stopping jail %s", $self->name);

    for (map $self->hpath($_), $self->umount) {
        $self->su("umount", $_);
    }
    $self->su("poudriere", "jail", "-k",
        "-j", $self->_pname,
        ($set ? ("-z", $set) : ()),
    );
    $self->_set(running => 0);
}

=head2 DESTROY

The destructor will stop the jail if it is running.

=cut

sub DESTROY {
    my ($self) = @_;
    $self->running and $self->stop;
}

1;

=head1 SEE ALSO

L<CPAN::Package>.

=head1 BUGS

Please report bugs to L<bug-CPAN-Package@rt.cpan.org>

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>

Released under the 2-clause BSD licence.

