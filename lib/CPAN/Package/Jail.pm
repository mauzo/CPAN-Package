package CPAN::Package::Jail;

use 5.010;
use warnings;
use strict;
use autodie;

use parent "CPAN::Package::Base";

use File::Path      qw/make_path/;
use File::Slurp     qw/read_dir write_file/;

for my $m (qw/ name jname root running /) {
    no strict "refs";
    *$m = sub { $_[0]{$m} };
}

sub umount { @{ $_[0]{umount} } }

sub su {
    my ($self, @cmd) = @_;
    $self->config("su")->(@cmd);
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

sub BUILDARGS {
    my ($class, $config, $name) = @_;

    return {
        config  => $config,
        name    => $name,
        jname   => "$name-default",
        running => 0,
    };
}

sub start {
    my ($self) = @_;

    my $config  = $self->config;
    my $jname   = $self->jname;

    $self->su("poudriere", "jail", "-sj", $self->name);
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

sub pkgtool {
    my ($self) = @_;
    $self->{pkgtool} //= $self->config->find(PkgTool => $self);
}

sub pkgdb {
    my ($self) = @_;
    $self->{pkgdb} //= $self->config->find(PkgDB => $self);
}

sub stop {
    my ($self) = @_;

    for (map $self->hpath($_), $self->umount) {
        $self->su("umount", $_);
    }
    $self->su("poudriere", "jail", "-kj", $self->name);
    $self->_set(running => 0);
}

sub DESTROY {
    my ($self) = @_;
    $self->running and $self->stop;
}

1;
