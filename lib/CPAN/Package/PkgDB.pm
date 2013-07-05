package CPAN::Package::PkgDB;

use 5.010;
use warnings;
use strict;

use parent "CPAN::Package::Base";

use DBI;

my $DBVER   = 1;

for my $s (qw/ dbh jail /) {
    no strict "refs";
    *$s = sub { $_[0]{$s} };
}

sub BUILDARGS {
    my ($class, $config, $jail) = @_;

    return {
        config  => $config,
        jail    => $jail,
    };
}

sub BUILD {
    my ($self) = @_;

    my $pkgdb   = $self->config->pkgdb;
    my $jname   = $self->jail->jname;

    my $dbh     = DBI->connect(
        "dbi:SQLite:$pkgdb/$jname", undef, undef, { 
            PrintError  => 0,
            RaiseError  => 1,
        },
    );
    $self->_set(dbh => $dbh);

    my $dbver = eval {
        $dbh->selectrow_array("select version from pkgdb")
    } // 0;
    $dbver == $DBVER or $self->setup_db;
}

sub _create_tables {
    my ($self) = @_;

    my $dbh = $self->dbh;

    # INTEGER PRIMARY KEY is SQLitish for 'serial' (or rather 'oid')...
    $dbh->do($_) for split /;/, <<SQL;
create table pkgdb (
    version integer
);
create table dist (
    id      integer     primary key,
    name    varchar,
    version varchar,
    type    varchar,
    unique (name, version)
);
create table module (
    id      integer     primary key,
    name    varchar,
    version varchar,
    dist    integer     references dist,
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

    my $dbh = $self->dbh;

    say "===> Creating pkgdb";
    $dbh->begin_work;

    $self->_create_tables;
    $self->_register_core($]);

    $dbh->do(
        "insert into pkgdb (version) values (?)", 
        undef, $DBVER,
    );

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

sub register_dist {
    my ($self, $dist, $mods) = @_;

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

    say sprintf "===> %s-%s provides:", $dist->name, $dist->version;

    while (my ($name, $m) = each %$mods) {
        $dbh->do(
            <<SQL,
                insert into module (name, version, dist)
                values (?, ?, ?)
SQL
            undef, $name, $$m{version}, $distid,
        );
        say "====> $name $$m{version}";
    }

    $dbh->commit;
}

1;
