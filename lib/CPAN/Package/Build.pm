package CPAN::Package::Build;

use 5.010;
use warnings;
use strict;
use autodie;

use parent "CPAN::Package::Base";

use Carp;
use Config;
use CPAN::Meta;
use CPAN::Meta::Requirements;
use File::Find::Rule;
use File::Find::Rule::DirectoryEmpty;
use File::Slurp             qw/read_dir/;
use File::Spec::Functions   qw/abs2rel/;
use File::Path              qw/remove_tree/;
use File::Temp              qw/tempdir/;
use List::Util              qw/first/;
use Makefile::Parser;
use Module::Metadata;

for my $m (qw/ jail dist wrkdir wrksrc destdir make meta /) {
    no strict "refs";
    *$m = sub { $_[0]{$m} };
}

sub post_install {
    my ($self, @new) = @_;
    my $pi = $self->{post_install} //= [];
    push @$pi, @new;
    wantarray ? @$pi : $pi;
}

sub BUILDARGS {
    my ($class, $config, $jail, $dist) = @_;
    return {
        config  => $config,
        jail    => $jail,
        dist    => $dist,
    };
}

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

    my $extra   = $conf->extradeps_for($self->dist->name)->{$phase};
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

sub satisfy_reqs {
    my ($self, $phase) = @_;

    my $config  = $self->config;
    my $pkg     = $self->jail->pkgtool;
    my $req     = $self->needed($phase);

    for my $d (@{$$req{pkg}}) {
        my $dist = $config->find(Dist =>
            name    => $$d{dist},
            version => $$d{distver},
        );
        $self->sayf(2, "Install package for %s", $dist->fullname);
        $pkg->install_my_pkgs($dist);
    }

    return map $$_{module}, @{$$req{needed}};
}

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

    @contents != 1 || ! -d $jail->hpath($wrksrc)
        and $conf->throw("Unpack", 
            "does not unpack into a single directory");

    $self->_set(wrksrc => $wrksrc);

    my $dest    = "$wrkdir/tmproot";
    mkdir $jail->hpath($dest);
    $self->_set(destdir => $dest);
    
    return $self;
}

sub configure_dist {
    my ($self) = @_;

    my $dist = $self->dist->name;
    $self->say(1, "Configuring $dist");

    my $jail = $self->jail;
    my $dest = $jail->jpath($self->destdir);
    $self->say(2, "Using dest [$dest]");

    my $work    = $self->wrksrc;
    my $conf    = $self->config;
    my $perl    = $conf->perl;

    if (-f $jail->hpath("$work/Build.PL")) {
        $jail->injail($work, $perl, "Build.PL", 
            "--destdir",            $dest,
            "--installdirs",        "site",
            # There is currently no satisfactory solution to the
            # site_bin problem. Since pkg won't let me install pkgs with
            # conflicting files, just punt for now with a real site_bin
            # directory.
            "--install_path",       "script=/opt/perl/site_bin",
            "--install_path",       "bin=/opt/perl/site_bin",
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
            "INSTALLSITESCRIPT=/opt/perl/site_bin",
            "INSTALLSITEBIN=/opt/perl/site_bin",
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

sub make_dist {
    my ($self, $target) = @_;

    $self->say(1, "\u${target}ing", $self->dist->name);

    my $parse = "_parse_${target}_target";
    my @targets = ($self->can($parse) && $self->$parse) || $target;

    $self->jail->injail($self->wrksrc, $self->make, @targets)
        or $self->config->throw("Build", "$target failed");
}

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

sub provides {
    my ($self) = @_;
    Module::Metadata->provides(
        dir     => $self->jail->hpath($self->destdir),
        prefix  => "",
        version => 2,
    );
}

1;

