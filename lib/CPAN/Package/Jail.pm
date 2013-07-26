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

use parent "CPAN::Package::Base";

use File::Path      qw/make_path/;
use File::Slurp     qw/read_dir write_file/;

=head1 ATTRIBUTES

All of these have read-only accessors.

=head2 config

The L<CPAN::Package> we are using.

=head2 jname

The internal name of the jail, as used by the jail manipulation
commands.

=head2 name

The name of the jail, as supplied to C<new>.

=head2 root

The root directory of the jail in the host filesystem. This may not be
set until after L</start> has been called.

=head2 running

A boolean which indicates whether or not the jail is running. Jails
start not running. This will not track external changes to the jail's
state.

=cut

for my $m (qw/ name jname root running /) {
    no strict "refs";
    *$m = sub { $_[0]{$m} };
}

sub umount { @{ $_[0]{umount} } }

=head1 METHODS

=head2 new

    my $jail = CPAN::Package::Jail->new($config, $name);

This is the constructor. C<$name> should be the name as C<poudriere jail
-j> understands it; C<jname> will be set to C<"$name-default">.

=cut

sub BUILDARGS {
    my ($class, $config, $name) = @_;

    return {
        config  => $config,
        name    => $name,
        jname   => "$name-default",
        running => 0,
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

    $self->say(1, "Starting jail $name");

    $self->su("poudriere", "jail", "-sj", $name);
    $self->_set(running => 1);

    chomp(my $root = qx/jls -j $jname path/);
    $self->_set(root => $root);

    $self->mount_tmpfs($self->hpath(""));
    mkdir $self->hpath("build");

    my $pkg = "$$config{packages}/$jname";
    $self->mount_nullfs("w", $pkg, $self->hpath("pkg"));
    $self->_set(pkg => $pkg, umount => ["pkg", ""]);

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

=head2 pkgtool

    my $pkg = $jail->pkgtool;

Returns a L<PkgTool|CPAN::Package::PkgTool> for this jail.

=cut

sub pkgtool {
    my ($self) = @_;
    $self->{pkgtool} //= $self->config->find(PkgTool => $self);
}

=head2 pkgdb

    my $pkgdb = $jail->pkgdb;

Returns a L<PkgDB|CPAN::Package::PkgDB> for this jail.

=cut

sub pkgdb {
    my ($self) = @_;
    $self->{pkgdb} //= $self->config->find(PkgDB => $self);
}

=head2 stop

    $jail->stop;

Stops the jail and unmounts any filesystems we mounted when we started
it.

=cut

sub stop {
    my ($self) = @_;

    $self->sayf(1, "Stopping jail %s", $self->name);

    for (map $self->hpath($_), $self->umount) {
        $self->su("umount", $_);
    }
    $self->su("poudriere", "jail", "-kj", $self->name);
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

