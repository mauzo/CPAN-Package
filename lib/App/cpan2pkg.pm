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

    $opts{mods} = \@argv;

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

    while (my $mod = $self->pop_mod) {
        my $dist        = $Conf->find(Dist => spec => $mod);
        my $distname    = $dist->name;
        $self->_set(dist => $dist);

        try {
            if ($self->tried($distname)) {
                $Conf->throw("Skip", "Already tried $distname");
                next;
            }
            $self->tried($distname, 1);

            $dist->fetch;

            my $build = $Conf->find(Build => $jail, $dist);
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
        catch {
            unless (eval { $_->isa("CPAN::Package::Exception") }) {
                $Conf->say(1, "$distname failed");
                $Conf->say(2, "  $_");
                return;
            }
            
            my $type = $_->type;
            my $info = $_->info;

            if ($type eq "Needed") {
                $Conf->say(1, "Defer $distname");
                $self->tried($distname, 0);
                $self->push_mods(@$info, $mod);
            }
            elsif ($type eq "Skip") {
                $Conf->say(1, "Skip $distname");
                $Conf->say(2, "  $info");
            }
            else {
                $self->failed($distname, 1);
                $Conf->say(1, "$distname failed");
                $Conf->say(2, "  $type ($info)");
            }
        };
    }

    if (my @failed = $self->failed) {
        $Conf->say(1, "Failed to build:");
        $Conf->say(1, "  $_") for @failed;
    }

    $jail->injail("", "sh", "-c", "$ENV{SHELL} >/dev/tty 2>&1");

    $jail->stop;
}

1;
