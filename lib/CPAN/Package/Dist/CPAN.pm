package CPAN::Package::Dist::CPAN;

use 5.012;
use warnings;

use parent "CPAN::Package::Dist";

use Encode              qw/decode/;
use File::Basename      qw/basename/;
use Parse::CPAN::Meta;

my $A = qr/[A-Z]/;

sub _resolve_mod {
    my ($class, $conf, $spec) = @_;

    my $rs = $conf->http->get("$$conf{metadb}/$spec");
    $$rs{success} or $conf->throw(Resolve =>
        "can't resolve module '$spec'");
    
    my $meta = Parse::CPAN::Meta->load_yaml_string(
        decode "utf8", $$rs{content}
    ) or $conf->throw(Resolve => "can't parse meta for '$spec'");

    return $$meta{distfile};
}

sub resolve {
    my ($class, $conf, $spec) = @_;

    my $distfile;
    if ($spec =~ m!^($A)/(\1$A)/\2$A+/!) {
        $distfile = $spec;
    }
    elsif ($spec =~ m!^($A)($A)($A+)/(.*)!) {
        $distfile = "$1/$1$2/$1$2$3/$4";
    }
    elsif ($spec !~ /[^\w:]/) {
        $distfile = $class->_resolve_mod($conf, $spec);
    }
    else {
        $conf->throw(Resolve => 
            "can't resolve '$spec' as a CPAN dist");
    }

    $class->new($conf,
        distfile    => $distfile,
    );
}

sub fetch {
    my ($self) = @_;

    my $conf    = $self->config;
    my $dist    = $self->distfile;
    my $path    = $self->make_tar_dir;
    my $url     = "$$conf{cpan}/authors/id/$dist";

    $self->say(1, "Fetching $dist");

    my $rs = $conf->http->mirror($url, $path);
    $$rs{success} or $conf->throw(Fetch =>
        "Fetch for $dist failed: $$rs{reason}");
    $$rs{status} == 304 and $self->say(2, "Already fetched");
}

1;
