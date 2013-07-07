package CPAN::Package::Dist;

use 5.010;
use warnings;
use strict;
use autodie;

use parent "CPAN::Package::Base";

use Encode              qw/decode/;
use File::Basename      qw/dirname/;
use File::Path          qw/make_path/;
use Parse::CPAN::Meta;

my $Ext = qr/\.tar(?:\.gz|\.bz2|\.xz)|\.t(?:gz|bz|xz)|\.zip$/;

for my $m (qw/name version distfile tar/) {
    no strict "refs";
    *$m = sub { $_[0]{$m} };
}

sub fullname { join "-", map $_[0]->$_, qw/name version/ }

sub resolve {
    my ($class, $conf, $spec) = @_;

    my $distfile;
    if ($spec =~ m!^([A-Z])([A-Z])([A-Z]+)/(.*)!) {
        $distfile = "$1/$1$2/$1$2$3/$4";
    }
    else {
        my $rs = $conf->http->get("$$conf{metadb}/$spec");
        $$rs{success}  or die "can't resolve module '$spec'\n";
        
        my $meta = Parse::CPAN::Meta->load_yaml_string(
            decode "utf8", $$rs{content}
        )               or die "can't parse meta for '$spec'\n";
        $distfile = $$meta{distfile};
    }

    my ($name, $version) = $distfile =~
            m!^ .*/ ([-A-Za-z0-9_+]+) - ([^-]+) $Ext $!x
        or die "Can't parse distfile name '$distfile'\n";
    
    return {
        config      => $conf,
        name        => $name,
        version     => $version,
        distfile    => $distfile,
    };
}

sub BUILDARGS {
    my ($class, $conf, %args) = @_;

    if (my $spec = $args{spec}) {
        return $class->resolve($conf, $spec);
    }

    return {
        %args,
        config  => $conf,
    };
}


sub fetch {
    my ($self) = @_;

    my $dist    = $self->distfile;
    my $conf    = $self->config;

    my $path    = "$$conf{dist}/$dist";
    my $url     = "$$conf{cpan}/authors/id/$dist";

    $self->say(1, "Fetching $dist");

    make_path dirname $path;

    my $rs = $conf->http->mirror($url, $path);
    unless ($$rs{success}) {
        $self->say(1, "!!! Fetch failed: $$rs{reason}");
        return;
    }
    $$rs{status} == 304 and $self->say(2, "Already fetched");

    $self->_set(tar => $path);
    return $path;
}

1;
