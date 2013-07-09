package CPAN::Package::PkgDB;

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

for my $s (qw/ dbh jail dbname /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

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
