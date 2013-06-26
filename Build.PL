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
    meta_merge		=> {
	resources   => {
	    repository => "http://github.com/mauzo/CPAN-Package",
	    bugtracker => "https://rt.cpan.org/Public/Dist/" .
		"Display.html?Name=CPAN-Package",
	},
    },
)->create_build_script;
