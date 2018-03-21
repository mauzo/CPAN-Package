package CPAN::Package::Dist::Git;

use 5.012;
use warnings;

use Capture::Tiny   qw/capture_stdout/;

use Moose;

extends "CPAN::Package::Dist";

has repo    => is => "ro";
has ref     => is => "ro";
has rev     => is => "ro";

sub resolve {
    my ($class, $conf, $spec) = @_;

    my ($repo, $ref) = $spec =~ /^(.*\.git)(?:#(.*))?/
        or $conf->throw(Resolve => "can't resolve git repo '$spec'");
    $ref //= "master";

    my ($name) = $repo =~ m!([^/]+)/?\.git$!;

    my $rev = capture_stdout {
        $conf->system("git", "ls-remote", $repo, $ref)
            or $conf->throw(Resolve => 
                "can't contact git repo '$repo'");
    } 
        or $conf->throw(Resolve => 
            "can't find ref '$ref' in repo '$repo'");
    $rev =~ s/\s.*//s;

    my $ver = substr $rev, 0, 6;

    $class->new($conf,
        distfile    => "L/LO/LOCAL/$name-$ver.tar.gz",
        repo        => $repo,
        rev         => $rev,
        ref         => $ref,
    );
}

sub fetch {
    my ($self) = @_;

    my $conf    = $self->config;
    my $tar     = $self->make_tar_dir;
    my $repo    = $self->repo;
    my $ref     = $self->ref;
    my $ver     = substr $self->rev, 0, 6;
    my $name    = $self->name;

    $conf->say(1, "Fetching $repo \@$ver");

    $conf->system("git", "archive",
        "-o", $tar,
        "--remote=$repo",
        "--prefix=$name/",
        $ref,
    )
        or $conf->throw(Fetch => "can't fetch archive of '$repo \@$ver'");
}

1;
