use Module::Build;

Module::Build->new(
    module_name		=> "CPAN::Package",
    license		=> "bsd",
    configure_requires	=> {
	"Module::Build"	    => "0.38",
    },
    build_requires	=> {
	"Test::More"	    => "0.96",
    },
    requires            => {
        "CPAN::Meta"                => "0",
        "CPAN::Meta::Requirements"  => "0",
        "Capture::Tiny"             => "0.20",
        "Class::Load"               => "0",
        "DBI"                       => "0",
        "DBD::SQLite"               => "1.39",
        "File::Find::Rule::DirectoryEmpty"  => "0",
        "File::Find::Rule"          => "0",
        "File::Slurp"               => "9999.17",
        "HTTP::Tiny"                => "0",
        "List::MoreUtils"           => "0.33",
        "Makefile::Parser"          => "0",
        "Module::Metadata"          => "0",
        "Parse::CPAN::Meta"         => "0",
        "Scope::Guard"              => "0",
        "Try::Tiny"                 => "0",
        "YAML::XS"                  => "0",
        "parent"                    => "0",

        perl                        => "5.012000",
    },
    meta_merge		=> {
	resources   => {
	    repository => "http://github.com/mauzo/CPAN-Package",
	    bugtracker => "https://rt.cpan.org/Public/Dist/" .
		"Display.html?Name=CPAN-Package",
	},
    },
)->create_build_script;
