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
use File::Temp              qw/tempdir/;
use Module::CoreList;
use Module::Metadata;

for my $m (qw/ jail dist wrkdir wrksrc destdir make meta /) {
    no strict "refs";
    *$m = sub { $_[0]{$m} };
}

sub read_meta {
    my ($self, $file) = @_;

    my $wrksrc = $self->wrksrc
        or croak "read_meta needs an unpacked dist";

    for (map $self->jail->hpath("$wrksrc/$file.$_"), qw/json yml/) {
        -r or next;
        say "===> Reading metadata from $_";
        my $meta = CPAN::Meta->load_file($_)
            or return;
        $self->_set(meta => $meta);
        return $meta;
    }
    return;
}

sub in_core {
    my ($perl, $mod) = @_;
    my $mods = $Module::CoreList::version{$perl};
    exists $$mods{$mod} and $$mods{$mod} // "0";
}

my %Phases = (
    configure   => [qw/configure/],
    build       => [qw/configure runtime build/],
    test        => [qw/configure runtime build test/],
    install     => [qw/runtime/],
);

sub needed {
    my ($self, $phase) = @_;

    my $prereq  = $self->meta->effective_prereqs;
    my $req = CPAN::Meta::Requirements->new;
    $req->add_requirements($prereq->requirements_for($_, "requires"))
        for @{$Phases{$phase}};

    my %mods;
    for my $m ($req->required_modules) {
        my $core = in_core $], $m;
        my $state =
            $core && $req->accepts_module($m, $core)    ? "core"    :
            "needed";
        say "===> Dep ($phase): $m [$state]";
        push @{$mods{$state}}, $m;
    }

    return \%mods;
}

sub unpack_dist {
    my ($self) = @_;

    my $jail = $self->jail;
    my $dist = $self->dist->name;

    my $wrkdir  = "build/$dist";
    my $work    = $jail->hpath($wrkdir);
    mkdir $work;
    $self->_set(wrkdir => $wrkdir);

    say "==> Unpacking $dist";

    # libarchive++
    system "tar", "-xf", $self->dist->tar, "-C", $work;

    my @contents    = read_dir $work;
    my $wrksrc      = "$wrkdir/$contents[0]";
    @contents != 1 || ! -d $jail->hpath($wrksrc)
        and die "$dist does not unpack into a single directory\n";
    $self->_set(wrksrc => $wrksrc);

    my $dest    = "$wrkdir/tmproot";
    mkdir $jail->hpath($dest);
    $self->_set(destdir => $dest);
    
    return $self;
}

sub configure_dist {
    my ($self) = @_;

    my $dist = $self->dist->name;
    say "==> Configuring $dist";

    my $jail = $self->jail;
    my $dest = $jail->jpath($self->destdir);
    say "===> Using dest [$dest]";

    my $work    = $self->wrksrc;
    my $perl    = $self->config("perl");

    if (-f $jail->hpath("$work/Build.PL")) {
        $jail->injail($work, $perl, "Build.PL", 
            "--destdir", $dest,
            "--installdirs", "site",
        );
        $self->_set(make => "./Build");
    }
    elsif (-f $jail->hpath("$work/Makefile.PL")) {
        $jail->injail($work, $perl, "Makefile.PL", 
            "DESTDIR=$dest",
            "INSTALLDIRS=site",
        );
        $self->_set(make => $Config{make});
    }
    else {
        die "Don't know how to configure $dist\n";
    }
}

sub make_dist {
    my ($self, $target) = @_;

    say "==> \u${target}ing " . $self->dist->name;
    $self->jail->injail($self->wrksrc, 
        $self->make, ($target eq "build" ? () : $target));
}

sub fixup_install {
    my ($self) = @_;

    my $FFR     = "File::Find::Rule";
    my $jail    = $self->jail;
    my $dest    = $self->destdir;
    my $hdest   = $jail->hpath($dest);
    my $jdest   = $jail->jpath($dest);
    my $su      = $self->config("su");

    $su->($^X, "-pi", "-es,\Q$jdest\E,,",
        $FFR->file->name(".packlist")->in($hdest));
    
    # Forget perllocal.pod for now. Ideally we'd fix it up in a
    # post-install script.
    $su->("rm", 
        $FFR->file->name("perllocal.pod")->in($hdest));

    while (my @e = $FFR->directoryempty->in($hdest)) {
        $su->("rmdir", @e);;
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

