package t::All;

use strict;
use warnings;

use Exporter "import";

use Test::More;

use CPAN::Package::t;

use Cwd         qw/abs_path/;
use Data::Dump  qw/pp/;
use File::Path  qw/make_path remove_tree/;
use File::Slurp qw/read_file/;

our @EXPORT = (
    @Test::More::EXPORT,
    qw/abs_path pp read_file setup_ttmp mk_CPAN_Package/,
    qw/$TMP $MY $PERLVER/,
);

our $TMP        = abs_path "ttmp";
our $MY         = "$TMP/jail/cpan2pkg";
our $PERLVER    = ($^V =~ s/^v//r);

sub setup_ttmp {
    remove_tree $TMP;
    make_path map "$TMP/$_", qw(
        pkg pkgdb jail/cpan2pkg/pkg jail/cpan2pkg/repos
    );
}

my %perlV = (
    version         => $PERLVER,
    installbin      => "/usr/local/bin",
    installsitebin  => "/usr/local/bin",
);

sub mk_CPAN_Package {
    CPAN::Package::t->new(
        packages    => "$TMP/pkg",
        pkgdb       => "$TMP/pkgdb",
        su          => sub { $_[0]->system("SU", @_[1..$#_]) },
        t_output    => [
            [qr/^jls .* path$/,             "$TMP/jail\n"               ],
            [qr!/corelist !,                "Foo 1.01\nBar 2.02\n"      ],
            map [qr!/perl .*(?<= )-V:$_\b!, "$_='$perlV{$_}';\n"        ],
                keys %perlV,
        ],
    ) or die "Can't build CPAN::Package::t";
}

1;
