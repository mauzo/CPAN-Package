package CPAN::Package::Exception;

use warnings;
use strict;

use parent "CPAN::Package::Base";

for my $s (qw/ type info /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

sub BUILDARGS {
    my ($class, $conf, $type, $info) = @_;
    return {
        config  => $conf,
        type    => $type,
        info    => $info,
    };
}

sub throw { die $_[0] }

1;
