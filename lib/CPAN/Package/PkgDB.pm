package CPAN::Package::PkgDB;

=head1 NAME

CPAN::Package::PkgDB - Package database for CPAN::Package

=head1 SYNOPSIS

    my $db = CPAN::Package::PkgDB->new($config, $jail);

=head1 DESCRIPTION

L<CPAN::Package> maintains a database recording which distributions
we've built packages from and which modules they supply. This database
is a SQLite file named after the jail, kept under the config's C<pkgdb>
directory.

=cut

use 5.010;
use warnings;
use strict;

use parent "CPAN::Package::Base";

use Carp;
use DBI;

# echo -n CPAN::Package | cksum
# SQLite claims this is 32bit, but it's actually 31bit...
my $APPID   = 323737960;
my $DBVER   = 1;

=head1 ATTRIBUTES

These all have read-only accessors.

=head2 dbh

The L<DBI> database handle.

=head2 dbname

The full path to the database.

=head2 jail

The L<Jail|CPAN::Package::Jail> this is the database for.

=cut

for my $s (qw/ dbh jail dbname /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

=head1 METHODS

=head2 new

    my $db = CPAN::Package::PkgDB->new($config, $jail);
    my $db = $jail->pkgdb;

This is the constructor. This will open the database file, creating it
if necessary, and make sure the required tables are present. If the
database file exists and is not a CPAN::Package pkgdb, it will throw an
exception.

=cut

sub BUILDARGS {
    my ($class, $config, $jail) = @_;

    my $pkgdb   = $config->pkgdb;
    my $jname   = $jail->jname;
    my $dbname  = "$pkgdb/$jname";

    return {
        config  => $config,
        jail    => $jail,
        dbname  => $dbname,
    };
}

sub BUILD {
    my ($self) = @_;

    my $dbname  = $self->dbname; 
    my $dbh     = DBI->connect(
        "dbi:SQLite:$dbname", undef, undef, { 
            PrintError  => 0,
            RaiseError  => 1,
        },
    );
    $self->_set(dbh => $dbh);

    # this will croak for anything but an empty db
    $self->check_db_ver or $self->setup_db;
}

sub _select {
    my ($self, $sql) = @_;
    $self->dbh->selectrow_array($sql);
}

sub check_db_ver {
    my ($self) = @_;

    my $dbname = $self->dbname;

    my $appid = $self->_select("pragma application_id");
    defined $appid
        or die "CPAN::Package needs DBD::SQLite 1.39\n";

    unless ($appid == $APPID) {
        my $schema = $self->_select("pragma schema_version");

        # empty database
        $appid == 0 && $schema == 0 and return;

        croak sprintf 
            "%s is not a CPAN::Package pkgdb (appid %x)",
            $dbname, $appid;
    }
    
    my $dbver = $self->_select("pragma user_version");
    $dbver == $DBVER
        or croak "$dbname is the wrong version ($dbver vs $DBVER)";

    return 1;
}

sub _create_tables {
    my ($self) = @_;

    my $dbh = $self->dbh;

    # INTEGER PRIMARY KEY is SQLitish for 'serial' (or rather 'oid')...
    $dbh->do($_) for split /;/, <<SQL;
create table dist (
    id      integer     primary key,
    name    varchar     not null,
    version varchar     not null,
    type    varchar     not null,
    unique (name, version)
);
create table module (
    id      integer     primary key,
    name    varchar     not null,
    version varchar,
    dist    integer     not null references dist,
    unique (name, dist)
);
SQL
}

sub _register_core {
    my ($self, $perlver) = @_;

    my $dbh = $self->dbh;

    $dbh->do(<<SQL, undef, $perlver);
        insert into dist (name, version, type)
        values ('perl', ?, 'core')
SQL
    my $coreid = $dbh->selectrow_array("select last_insert_rowid()");

    require Module::CoreList;
    my $mods = $Module::CoreList::version{$]};
    for my $mod (keys %$mods) {
        my $ver = $$mods{$mod} // "0";
        $dbh->do(<<SQL, undef, $mod, $ver, $coreid);
            insert into module (name, version, dist)
            values (?, ?, ?)
SQL
    }

    $dbh->do(<<SQL, undef, $perlver, $coreid)
        insert into module (name, version, dist)
        values ('perl', ?, ?)
SQL
}

sub setup_db {
    my ($self) = @_;

    # just checking... 1.39 included SQLite 3.7.17 which has
    # application_id support.
    DBD::SQLite->VERSION(1.39);

    my $dbh = $self->dbh;

    $self->say(2, "Creating pkgdb");
    $dbh->begin_work;

    # pragma doesn't do placeholders
    $dbh->do("pragma application_id = $APPID");

    $self->_create_tables;
    $self->_register_core($]);

    $dbh->do("pragma user_version = $DBVER");

    $dbh->commit;
}

=head2 find_module

   my $dists = $db->find_module($mod);

Finds all the packages in the database which provide the given module.
Returns an arrayref of hashrefs with the following keys:

=over 4

=item C<dist>

The name of the distribution, without version. For C<core> distributions
this will be C<perl>.

=item C<distver>

The version of the distibution.

=item C<modver>

The version of the requested module provided by the distribution.

=item C<type>

This is either C<core> to indicate a module that is present in the core
perl installation, or C<pkg> to indicate a module we have already built
a package for.

=back

=cut

sub find_module {
    my ($self, $mod) = @_;

    # This assumes that 'type' sorts core before pkg
    $self->dbh->selectall_arrayref(
        <<SQL,
            select d.name dist, d.version distver, d.type, 
                m.version modver
            from module m join dist d on d.id = m.dist
            where m.name = ?
            order by d.type
SQL
        { Slice => {} },
        $mod,
    );
}

=head2 register_build

    $db->register_build($build);

Registers a new package in the database. C<$build> is the
L<Build|CPAN::Package::Build> used to build the package, from which the
name, version and provided modules will be extracted.

It is not possible to register the same distribution (same name and
version) twice. Attempting to do so will throw an exception.

=cut

sub register_build {
    my ($self, $build, $deps) = @_;

    my $dist    = $build->dist;
    my $mods    = $build->provides;

    my $dbh = $self->dbh;
    $dbh->begin_work;

    $dbh->do(
        <<SQL,
            insert into dist (name, version, type)
            values (?, ?, 'pkg')
SQL
        undef, $dist->name, $dist->version,
    );
    my $distid = $dbh->selectrow_array("select last_insert_rowid()");

    $self->sayf(3, "%s-%s provides:", $dist->name, $dist->version);

    while (my ($name, $m) = each %$mods) {
        $dbh->do(
            <<SQL,
                insert into module (name, version, dist)
                values (?, ?, ?)
SQL
            undef, $name, $$m{version}, $distid,
        );
        $self->say(3, "  $name $$m{version}");
    }

    $dbh->commit;
}

1;

=head1 SEE ALSO

L<CPAN::Package>, L<CPAN::Package::PkgTool>.

=head1 BUGS

Please report bugs to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>

Released under the 2-clause BSD licence.

