package App::cpan2pkg;

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

for my $s (qw/ jail mod mods dist build verbose /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

for my $h (qw/ tried failed /) {
    no strict "refs";
    *$h = sub {
        my ($self, $mod, $set) = @_;
        my $hash = $self->{$h} //= {};
        @_ < 2 and return sort keys %$hash;
        @_ > 2 and $hash->{$mod} = $set;
        $hash->{$mod};
    };
}

sub push_mods {
    my ($self, @mods) = @_;
    my $mods = $self->{mods} //= [];
    push @$mods, reverse @mods;
}

sub pop_mod {
    my ($self) = @_;
    my $mod = pop @{ $self->mods };
    $self->_set(mod => $mod);
    $self->_set($_ => undef) for qw/dist build/;
    $mod;
}

sub BUILDARGS {
    my ($class, @argv) = @_;
    
    Getopt::Long::Configure qw/bundling/;
    GetOptionsFromArray \@argv, \my %opts, qw/
        jail|j=s
        verbose|v:+
        config|f=s
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
    $yaml->{redirect_stdh}  //= 1;

    $self->jail or $self->_set(jail => delete $yaml->{jail});
    
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

sub check_reqs {
    my ($self, $phase) = @_;

    my $conf    = $self->config;
    my $build   = $self->build;

    if (my @needed = $build->satisfy_reqs($phase)) {
        if (my $fail = first { $self->failed($_) } @needed) {
            $conf->throw("Fail", "Already failed to build $fail");
        }
        $conf->throw("Needed", \@needed);
    }
};

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

sub build_failed {
    my ($self, $ex) = @_;

    my $conf = $self->config;
    my $type = $ex->type;
    my $info = $ex->info;
    my $name = $self->dist->name;

    if ($type eq "Needed") {
        $conf->say(1, "Deferring $name");
        $self->tried($name, 0);
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

sub build_some_dists {
    my ($self) = @_;

    my $conf = $self->config;

    while (my $mod = $self->pop_mod) {
        my $dist        = $conf->find(Dist => spec => $mod);
        my $distname    = $dist->name;
        $self->_set(dist => $dist);

        try {
            if ($self->tried($distname)) {
                $conf->throw("Skip", "Already tried $distname");
                next;
            }
            $self->tried($distname, 1);

            $self->build_one_dist;
        }
        catch {
            eval { $_->isa("CPAN::Package::Exception") }
                or $_ = $conf->find(Exception =>
                    type    => "Fail",
                    info    => $_,
                );

            $self->build_failed($_);
        };
    }
}

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

    if (my @failed = $self->failed) {
        $Conf->say(1, "Failed to build:");
        $Conf->say(1, "  $_") for @failed;
    }

    $jail->injail("", "sh", "-c", "$ENV{SHELL} >/dev/tty 2>&1");

    $jail->stop;
}

1;
