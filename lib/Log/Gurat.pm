package Log::Gurat;

use 5.010;
use strict;
use warnings;

# VERSION

my %PATTERN_STYLES = (
    plain             => '%m',
    script_short      => '[%r] %m%n',
    script_long       => '[%d] %m%n',
    daemon            => '[pid %P] [%d] %m%n',
    syslog            => '[pid %p] %m',
);
for (keys %PATTERN_STYLES) {
    $PATTERN_STYLES{"cat_$_"} = "[cat %c]$PATTERN_STYLES{$_}";
    $PATTERN_STYLES{"loc_$_"} = "[loc %l]$PATTERN_STYLES{$_}";
}

my $init_args;
our $init_called;
my $is_daemon;

# poor man's version of 5.10's //
sub _ifdef {
    my ($a, $b) = @_;
    defined($a) ? $a : $b;
}

# m=multi, j=as json (except the last default)
sub _ifdefmj {
    require JSON;

    my $def = pop @_;
    for (@_) {
        return JSON::decode_json($_) if defined($_);
    }
    $def;
}

sub init {
    return if $init_called++;

    my ($args, $caller) = @_;
    $caller ||= caller();

    my $spec = _parse_opts($args, $caller);
    _init_log4perl($spec) if $spec->{log} && $spec->{init};
    $spec;
}

sub _gen_appender_config {
    my ($ospec, $apd_name, $filter) = @_;

    my $name = $ospec->{name};
    my $class;
    my $params = {};
    if ($name =~ /^dir/i) {
        $class = "Log::Dispatch::Dir";
        $params->{dirname}   = $ospec->{path};
        $params->{filename_pattern} = $ospec->{filename_pattern};
        $params->{max_size}  = $ospec->{max_size} if $ospec->{max_size};
        $params->{max_files} = $ospec->{histories}+1 if $ospec->{histories};
        $params->{max_age}   = $ospec->{max_age} if $ospec->{max_age};
    } elsif ($name =~ /^file/i) {
        $class = "Log::Dispatch::FileRotate";
        $params->{mode}  = 'append';
        $params->{filename} = $ospec->{path};
        $params->{size}  = $ospec->{size} if $ospec->{size};
        $params->{max}   = $ospec->{histories}+1 if $ospec->{histories};
        $params->{DatePattern} = $ospec->{date_pattern}
            if $ospec->{date_pattern};
        $params->{TZ} = $ospec->{tz} if $ospec->{tz};
    } elsif ($name =~ /^screen/i) {
        $class = "Log::Log4perl::Appender::" .
            ($ospec->{color} ? "ScreenColoredLevels" : "Screen");
        $params->{stderr}  = $ospec->{stderr} ? 1:0;
        $params->{"color.WARN"} = "bold blue"; # blue on black is so unreadable
    } elsif ($name =~ /^syslog/i) {
        $class = "Log::Dispatch::Syslog";
        $params->{mode}     = 'append';
        $params->{ident}    = $ospec->{ident};
        $params->{facility} = $ospec->{facility};
    } else {
        die "BUG: Unknown appender type: $name";
    }

    join(
        "",
        "log4perl.appender.$apd_name = $class\n",
        (map { "log4perl.appender.$apd_name.$_ = $params->{$_}\n" }
             grep {defined $params->{$_}} keys %$params),
        "log4perl.appender.$apd_name.layout = PatternLayout\n",
        "log4perl.appender.$apd_name.layout.ConversionPattern = $ospec->{pattern}\n",
        ($filter ? "log4perl.appender.$apd_name.Filter = $filter\n" : ""),
    );
}

sub _gen_l4p_config {
    my ($spec) = @_;

    my $filters_str = join(
        "",
        "log4perl.filter.FilterOFF = Log::Log4perl::Filter::LevelRange\n",
        "log4perl.filter.FilterOFF.LevelMin = TRACE\n",
        "log4perl.filter.FilterOFF.LevelMax = FATAL\n",
        "log4perl.filter.FilterOFF.AcceptOnMatch = false\n",
        "\n",
        map {join(
            "",
            "log4perl.filter.Filter$_ = Log::Log4perl::Filter::LevelRange\n",
            "log4perl.filter.Filter$_.LevelMin = $_\n",
            "log4perl.filter.Filter$_.LevelMax = FATAL\n",
            "log4perl.filter.Filter$_.AcceptOnMatch = true\n",
            "\n",
        )} qw(FATAL ERROR WARN INFO DEBUG), # TRACE
    );

    my %levels; # key = output name; value = { cat => level, ... }
    my %cats;   # list of categories
    my %ospecs; # key = oname; this is just a shortcut to get ospec

    # 1. list all levels for each category and output
    for my $ospec (@{ $spec->{dir} },
                   @{ $spec->{file} },
                   @{ $spec->{screen} },
                   @{ $spec->{syslog} }) {
        my $oname = $ospec->{name};
        $ospecs{$oname} = $ospec;
        $levels{$oname} = {};
        my %seen_cats;
        if ($ospec->{category_level}) {
            while (my ($cat0, $level) = each %{ $ospec->{category_level} }) {
                my @cat = _extract_category($ospec, $cat0);
                for my $cat (@cat) {
                    next if $seen_cats{$cat}++;
                    $cats{$cat}++;
                    $levels{$oname}{$cat} = $level;
                }
            }
        }
        if ($spec->{category_level}) {
            while (my ($cat0, $level) = each %{ $spec->{category_level} }) {
                my @cat = _extract_category($ospec, $cat0);
                for my $cat (@cat) {
                    next if $seen_cats{$cat}++;
                    $cats{$cat}++;
                    $levels{$oname}{$cat} = $level;
                }
            }
        }
        my @cat = _extract_category($ospec);
        for my $cat (@cat) {
            next if $seen_cats{$cat}++;
            $cats{$cat}++;
            $levels{$oname}{$cat} = $ospec->{level};
        }
    }
    #print Dumper \%levels; exit;

    my $find_olevel = sub {
        my ($oname, $cat) = @_;
        my $olevel = $levels{$oname}{''};
        my @c = split /\./, $cat;
        for (my $i=0; $i<@c; $i++) {
            my $c = join(".", @c[0..$i]);
            if ($levels{$oname}{$c}) {
                $olevel = $levels{$oname}{$c};
            }
        }
        $olevel;
    };

    # 2. determine level for each category (which is the minimum level of all
    # appenders for that category)
    my %cat_configs; # key = cat, value = [catlevel, apdname, ...]
    my $add_str = '';
    my $apd_str = '';
    for my $cat0 (sort {$a cmp $b} keys %cats) {
        $add_str .= "log4perl.additivity.$cat0 = 0\n" unless $cat0 eq '';
        my @cats = ($cat0);
        # since we don't use additivity, we need to add supercategories ourselves
        while ($cat0 =~ s/\.[^.]+$//) { push @cats, $cat0 }
        for my $cat (@cats) {
            my $cat_level;
            for my $oname (keys %levels) {
                my $olevel = $find_olevel->($oname, $cat);
                next unless $olevel;
                $cat_level = _ifdef($cat_level, $olevel);
                $cat_level = _min_level($cat_level, $olevel);
            }
            $cat_configs{$cat} = [uc($cat_level)];
            #next if $cat_level eq 'off';
        }
    }
    #print Dumper \%cat_configs; exit;

    # 3. add appenders for each category
    my %generated_appenders; # key = apdname, just a memory hash
    for my $cat (keys %cat_configs) {
        my $cat_level = $cat_configs{$cat}[0];
        for my $oname (keys %levels) {
            my $ospec = $ospecs{$oname};
            my $olevel = $find_olevel->($oname, $cat);
            #print "D:oname=$oname, cat=$cat, olevel=$olevel, cat_level=$cat_level\n";
            my $apd_name;
            my $filter;
            if ($olevel ne $cat_level &&
                    _min_level($olevel, $cat_level) eq $cat_level) {
                # we need to filter the appender, since the category level is
                # lower than the output level
                $apd_name = $oname . "_" . uc($olevel);
                $filter = "Filter".uc($olevel);
            } else {
                $apd_name = $oname;
            }
            unless ($generated_appenders{$apd_name}++) {
                $apd_str .= _gen_appender_config($ospec, $apd_name, $filter).
                    "\n";
            }
            push @{ $cat_configs{$cat} }, $apd_name;
        }
    }
    #print Dumper \%cat_configs; exit;

    # 4. write out log4perl category line
    my $cat_str = '';
    for my $cat (sort {$a cmp $b} keys %cat_configs) {
        my $l = $cat eq '' ? '' : ".$cat";
        $cat_str .= "log4perl.logger$l = ".join(", ", @{ $cat_configs{$cat} })."\n";
    }

    join(
        "",
        "# filters\n", $filters_str,
        "# categories\n", $cat_str, $add_str, "\n",
        "# appenders\n", $apd_str,
    );
}

sub _init_log4perl {
    require Log::Log4perl;

    my ($spec) = @_;

    # create intermediate directories for dir
    for (@{ $spec->{dir} }) {
        my $dir = _dirname($_->{path});
        make_path($dir) if length($dir) && !(-d $dir);
    }

    # create intermediate directories for file
    for (@{ $spec->{file} }) {
        my $dir = _dirname($_->{path});
        make_path($dir) if length($dir) && !(-d $dir);
    }

    my $config_str = _gen_l4p_config($spec);
    if ($spec->{dump}) {
        require Data::Dumper;
        print "Log::Any::App configuration:\n",
            Data::Dumper->new([$spec])->Terse(1)->Dump;
        print "Log4perl configuration: <<EOC\n", $config_str, "EOC\n";
    }

    Log::Log4perl->init(\$config_str);
    Log::Any::Adapter->set('Log4perl');
}

sub _basename {
    my $path = shift;
    my ($vol, $dir, $file) = File::Spec->splitpath($path);
    $file;
}

sub _dirname {
    my $path = shift;
    my ($vol, $dir, $file) = File::Spec->splitpath($path);
    $dir;
}

# we separate args and opts, because we need to export logger early
# (BEGIN), but configure logger in INIT (to be able to detect
# existence of other modules).

sub _parse_args {
    my ($args, $caller) = @_;
    $args = _ifdef($args, []); # if we don't import(), we never get args

    my $i = 0;
    while ($i < @$args) {
        my $arg = $args->[$i];
        do { $i+=2; next } if $arg =~ /^-(\w+)$/;
        if ($arg eq '$log') {
            _export_logger($caller);
        } else {
            die "Unknown arg '$arg', valid arg is '\$log' or -OPTS";
        }
        $i++;
    }
}

sub _parse_opts {
    require File::HomeDir;

    my ($args, $caller) = @_;
    $args = _ifdef($args, []); # if we don't import(), we never get args
    _debug("parse_opts: args = [".join(", ", @$args)."]");

    my $i = 0;
    my %opts;
    while ($i < @$args) {
        my $arg = $args->[$i];
        do { $i++; next } unless $arg =~ /^-(\w+)$/;
        my $opt = $1;
        die "Missing argument for option $opt" unless $i++ < @$args-1;
        $arg = $args->[$i];
        $opts{$opt} = $arg;
        $i++;
    }

    my $spec = {};

    $spec->{log} = $ENV{LOG} // 1;
    if (defined $opts{log}) {
        $spec->{log} = $opts{log};
        delete $opts{log};
    }
    # exit as early as possible if we are not doing any logging
    goto END_PARSE_OPTS unless $spec->{log};

    $spec->{name} = _basename($0);
    if (defined $opts{name}) {
        $spec->{name} = $opts{name};
        delete $opts{name};
    }

    $spec->{level_flag_paths} = [File::HomeDir->my_home, "/etc"];
    if (defined $opts{level_flag_paths}) {
        $spec->{level_flag_paths} = $opts{level_flag_paths};
        delete $opts{level_flag_paths};
    }

    $spec->{level} = _set_level("", "", $spec);
    if (!$spec->{level} && defined($opts{level})) {
        $spec->{level} = _check_level($opts{level}, "-level");
        _debug("Set general level to $spec->{level} (from -level)");
    } elsif (!$spec->{level}) {
        $spec->{level} = "warn";
        _debug("Set general level to $spec->{level} (default)");
    }
    delete $opts{level};

    $spec->{category_alias} = _ifdefmj($ENV{LOG_CATEGORY_ALIAS}, {});
    if (defined $opts{category_alias}) {
        die "category_alias must be a hashref"
            unless ref($opts{category_alias}) eq 'HASH';
        $spec->{category_alias} = $opts{category_alias};
        delete $opts{category_alias};
    }

    if (defined $opts{category_level}) {
        die "category_level must be a hashref"
            unless ref($opts{category_level}) eq 'HASH';
        $spec->{category_level} = {};
        for (keys %{ $opts{category_level} }) {
            $spec->{category_level}{$_} =
                _check_level($opts{category_level}{$_}, "-category_level{$_}");
        }
        delete $opts{category_level};
    }

    $spec->{init} = 1;
    if (defined $opts{init}) {
        $spec->{init} = $opts{init};
        delete $opts{init};
    }

    $spec->{daemon} = 0;
    if (defined $opts{daemon}) {
        $spec->{daemon} = $opts{daemon};
        $is_daemon = $opts{daemon};
        delete $opts{daemon};
    }

    $spec->{dump} = $ENV{LOGANYAPP_DEBUG};
    if (defined $opts{dump}) {
        $spec->{dump} = 1;
        delete $opts{dump};
    }

    $spec->{file} = [];
    _parse_opt_file($spec, _ifdef($opts{file}, ($0 ne '-e' ? 1:0)));
    delete $opts{file};

    $spec->{dir} = [];
    _parse_opt_dir($spec, _ifdef($opts{dir}, 0));
    delete $opts{dir};

    $spec->{screen} = [];
    _parse_opt_screen($spec, _ifdef($opts{screen}, !_is_daemon()));
    delete $opts{screen};

    $spec->{syslog} = [];
    _parse_opt_syslog($spec, _ifdef($opts{syslog}, _is_daemon()));
    delete $opts{syslog};

    if (keys %opts) {
        die "Unknown option(s) ".join(", ", keys %opts)." Known opts are: ".
            "log, name, level, category_level, category_alias, dump, init, ".
                "file, dir, screen, syslog";
    }

  END_PARSE_OPTS:
    #use Data::Dumper; print Dumper $spec;
    $spec;
}

sub _is_daemon {
    if (defined $is_daemon) { return $is_daemon }
    if (defined $main::IS_DAEMON) { return $main::IS_DAEMON }

    my $res =
        $INC{"App/Daemon.pm"} ||
        $INC{"Daemon/Easy.pm"} ||
        $INC{"Daemon/Daemonize.pm"} ||
        $INC{"Daemon/Generic.pm"} ||
        $INC{"Daemonise.pm"} ||
        $INC{"Daemon/Simple.pm"} ||
        $INC{"HTTP/Daemon.pm"} ||
        $INC{"IO/Socket/INET/Daemon.pm"} ||
        $INC{"Mojo/Server/Daemon.pm"} ||
        $INC{"MooseX/Daemonize.pm"} ||
        $INC{"Net/Daemon.pm"} ||
        $INC{"Net/Server.pm"} ||
        $INC{"Proc/Daemon.pm"} ||
        $INC{"Proc/PID/File.pm"} ||
        $INC{"Win32/Daemon/Simple.pm"}
            ;
    if (defined $res) { return $res }
    0;
}

sub _parse_opt_OUTPUT {
    my (%args) = @_;
    my $kind = $args{kind};
    my $default_sub = $args{default_sub};
    my $postprocess = $args{postprocess};
    my $spec = $args{spec};
    my $arg = $args{arg};

    return unless $arg;

    if (!ref($arg) || ref($arg) eq 'HASH') {
        my $name = uc($kind).(@{ $spec->{$kind} }+0);
        local $dbg_ctx = $name;
        push @{ $spec->{$kind} }, $default_sub->($spec);
        $spec->{$kind}[-1]{name} = $name;
        if (!ref($arg)) {
            # leave every output parameter as is
        } else {
            for my $k (keys %$arg) {
                for ($spec->{$kind}[-1]) {
                    exists($_->{$k}) or die "Invalid $kind argument: $k, please".
                        " only specify one of: " . join(", ", sort keys %$_);
                    $_->{$k} = $k eq 'level' ?
                        _check_level($arg->{$k}, "-$kind") : $arg->{$k};
                    _debug("Set level of $kind to $_->{$k} (spec)")
                        if $k eq 'level';
                }
            }
        }
        $spec->{$kind}[-1]{main_spec} = $spec;
        _set_pattern($spec->{$kind}[-1], $kind);
        $postprocess->(spec => $spec, ospec => $spec->{$kind}[-1])
            if $postprocess;
    } elsif (ref($arg) eq 'ARRAY') {
        for (@$arg) {
            _parse_opt_OUTPUT(%args, arg => $_);
        }
    } else {
        die "Invalid argument for -$kind, ".
            "must be a boolean or hashref or arrayref";
    }
}

sub _set_pattern_style {
    my ($x) = @_;
    ($ENV{LOG_SHOW_LOCATION} ? 'loc_':
         $ENV{LOG_SHOW_CATEGORY} ? 'cat_':'') . $x;
}

sub _default_file {
    require File::HomeDir;

    my ($spec) = @_;
    my $level = _set_level("file", "file", $spec);
    if (!$level) {
        $level = $spec->{level};
        _debug("Set level of file to $level (general level)");
    }
    return {
        level => $level,
        category_level => _ifdefmj($ENV{FILE_LOG_CATEGORY_LEVEL},
                                   $ENV{LOG_CATEGORY_LEVEL},
                                   $spec->{category_level}),
        path => $> ? File::Spec->catfile(File::HomeDir->my_home, "$spec->{name}.log") :
            "/var/log/$spec->{name}.log", # XXX and on Windows?
        max_size => undef,
        histories => undef,
        date_pattern => undef,
        tz => undef,
        category => '',
        pattern_style => _set_pattern_style('daemon'),
        pattern => undef,
    };
}

sub _parse_opt_file {
    my ($spec, $arg) = @_;

    if (!ref($arg) && $arg && $arg !~ /^(1|yes|true)$/i) {
        $arg = {path => $arg};
    }

    _parse_opt_OUTPUT(
        kind => 'file', default_sub => \&_default_file,
        spec => $spec, arg => $arg,
        postprocess => sub {
            my (%args) = @_;
            my $spec  = $args{spec};
            my $ospec = $args{ospec};
            if ($ospec->{path} =~ m!/$!) {
                my $p = $ospec->{path};
                $p .= "$spec->{name}.log";
                _debug("File path ends with /, assumed to be dir, ".
                           "final path becomes $p");
                $ospec->{path} = $p;
            }
        },
    );
}

sub _default_dir {
    require File::HomeDir;

    my ($spec) = @_;
    my $level = _set_level("dir", "dir", $spec);
    if (!$level) {
        $level = $spec->{level};
        _debug("Set level of dir to $level (general level)");
    }
    return {
        level => $level,
        category_level => _ifdefmj($ENV{DIR_LOG_CATEGORY_LEVEL},
                                   $ENV{LOG_CATEGORY_LEVEL},
                                   $spec->{category_level}),
        path => $> ? File::Spec->catfile(File::HomeDir->my_home, "log", $spec->{name}) :
            "/var/log/$spec->{name}", # XXX and on Windows?
        max_size => undef,
        max_age => undef,
        histories => undef,
        category => '',
        pattern_style => _set_pattern_style('plain'),
        pattern => undef,
        filename_pattern => undef,
    };
}

sub _parse_opt_dir {
    my ($spec, $arg) = @_;

    if (!ref($arg) && $arg && $arg !~ /^(1|yes|true)$/i) {
        $arg = {path => $arg};
    }

    _parse_opt_OUTPUT(
        kind => 'dir', default_sub => \&_default_dir,
        spec => $spec, arg => $arg,
    );
}

sub _default_screen {
    my ($spec) = @_;
    my $level = _set_level("screen", "screen", $spec);
    if (!$level) {
        $level = $spec->{level};
        _debug("Set level of screen to $level (general level)");
    }
    return {
        color => _ifdef($ENV{COLOR}, (-t STDOUT)),
        stderr => 1,
        level => $level,
        category_level => _ifdefmj($ENV{SCREEN_LOG_CATEGORY_LEVEL},
                                   $ENV{LOG_CATEGORY_LEVEL},
                                   $spec->{category_level}),
        category => '',
        pattern_style => _set_pattern_style('script_short'),
        pattern => undef,
    };
}

sub _parse_opt_screen {
    my ($spec, $arg) = @_;
    _parse_opt_OUTPUT(
        kind => 'screen', default_sub => \&_default_screen,
        spec => $spec, arg => $arg,
    );
}

sub _default_syslog {
    my ($spec) = @_;
    my $level = _set_level("syslog", "syslog", $spec);
    if (!$level) {
        $level = $spec->{level};
        _debug("Set level of syslog to $level (general level)");
    }
    return {
        level => $level,
        category_level => _ifdefmj($ENV{SYSLOG_LOG_CATEGORY_LEVEL},
                                   $ENV{LOG_CATEGORY_LEVEL},
                                   $spec->{category_level}),
        ident => $spec->{name},
        facility => 'daemon',
        pattern_style => _set_pattern_style('syslog'),
        pattern => undef,
        category => '',
    };
}

sub _parse_opt_syslog {
    my ($spec, $arg) = @_;
    _parse_opt_OUTPUT(
        kind => 'syslog', default_sub => \&_default_syslog,
        spec => $spec, arg => $arg,
    );
}

sub _set_pattern {
    my ($s, $name) = @_;
    _debug("Setting $name pattern ...");
    unless (defined($s->{pattern})) {
        die "BUG: neither pattern nor pattern_style is defined ($name)"
            unless defined($s->{pattern_style});
        die "Unknown pattern style for $name `$s->{pattern_style}`, ".
            "use one of: ".join(", ", keys %PATTERN_STYLES)
            unless defined($PATTERN_STYLES{ $s->{pattern_style} });
        $s->{pattern} = $PATTERN_STYLES{ $s->{pattern_style} };
        _debug("Set $name pattern to `$s->{pattern}` ".
                   "(from style `$s->{pattern_style}`)");
    }
}

sub _extract_category {
    my ($ospec, $c) = @_;
    my $c0 = _ifdef($c, $ospec->{category});
    my @res;
    if (ref($c0) eq 'ARRAY') { @res = @$c0 } else { @res = ($c0) }
    # replace alias with real value
    for (my $i=0; $i<@res; $i++) {
        my $c1 = $res[$i];
        my $a = $ospec->{main_spec}{category_alias}{$c1};
        next unless defined($a);
        if (ref($a) eq 'ARRAY') {
            splice @res, $i, 1, @$a;
            $i += (@$a-1);
        } else {
            $res[$i] = $a;
        }
    }
    for (@res) {
        s/::/./g;
        # $_ = lc; # XXX do we need this?
    }
    @res;
}

sub _cat2apd {
    my $cat = shift;
    $cat =~ s/[^A-Za-z0-9_]+/_/g;
    $cat;
}

sub _check_level {
    my ($level, $from) = @_;
    $level =~ /^(off|fatal|error|warn|info|debug|trace)$/i
        or die "Unknown level (from $from): $level";
    lc($1);
}

sub _set_level {
    my ($prefix, $which, $spec) = @_;
    #use Data::Dumper; print Dumper $spec;
    my $p_ = $prefix ? "${prefix}_" : "";
    my $P_ = $prefix ? uc("${prefix}_") : "";
    my $F_ = $prefix ? ucfirst("${prefix}_") : "";
    my $pd = $prefix ? "${prefix}-" : "";
    my $pr = $prefix ? qr/$prefix(_|-)/ : qr//;
    my ($level, $from);

    my @label2level =([trace=>"trace"], [debug=>"debug"],
                      [verbose=>"info"], [quiet=>"error"]);

    _debug("Setting ", ($which ? "level of $which" : "general level"), " ...");
  SET:
    {
        if ($INC{"App/Options.pm"}) {
            my $key;
            for (qw/log_level loglevel/) {
                $key = $p_ . $_;
                _debug("Checking \$App::options{$key}: ", _ifdef($App::options{$key}, "(undef)"));
                if ($App::options{$key}) {
                    $level = _check_level($App::options{$key}, "\$App::options{$key}");
                    $from = "\$App::options{$key}";
                    last SET;
                }
            }
            for (@label2level) {
                $key = $p_ . $_->[0];
                _debug("Checking \$App::options{$key}: ", _ifdef($App::options{$key}, "(undef)"));
                if ($App::options{$key}) {
                    $level = $_->[1];
                    $from = "\$App::options{$key}";
                    last SET;
                }
            }
        }

        my $i = 0;
        _debug("Checking \@ARGV ...");
        while ($i < @ARGV) {
            my $arg = $ARGV[$i];
            $from = "cmdline arg $arg";
            if ($arg =~ /^--${pr}log[_-]?level=(.+)/) {
                _debug("\$ARGV[$i] looks like an option to specify level: $arg");
                $level = _check_level($1, "ARGV $arg");
                last SET;
            }
            if ($arg =~ /^--${pr}log[_-]?level$/ and $i < @ARGV-1) {
                _debug("\$ARGV[$i] and \$ARGV[${\($i+1)}] looks like an option to specify level: $arg ", $ARGV[$i+1]);
                $level = _check_level($ARGV[$i+1], "ARGV $arg ".$ARGV[$i+1]);
                last SET;
            }
            for (@label2level) {
                if ($arg =~ /^--${pr}$_->[0](=(1|yes|true))?$/i) {
                    _debug("\$ARGV[$i] looks like an option to specify level: $arg");
                    $level = $_->[1];
                    last SET;
                }
            }
            $i++;
        }

        for (qw/LOG_LEVEL LOGLEVEL/) {
            my $key = $P_ . $_;
            _debug("Checking environment variable $key: ", _ifdef($ENV{$key}, "(undef)"));
            if ($ENV{$key}) {
                $level = _check_level($ENV{$key}, "ENV $key");
                $from = "\$ENV{$key}";
                last SET;
            }
        }
        for (@label2level) {
            my $key = $P_ . uc($_->[0]);
            _debug("Checking environment variable $key: ", _ifdef($ENV{$key}, "(undef)"));
            if ($ENV{$key}) {
                $level = $_->[1];
                $from = "\$ENV{$key}";
                last SET;
            }
        }

        for my $dir (@{$spec->{level_flag_paths}}) {
            for (@label2level) {
                my $filename = "$dir/$spec->{name}." . $P_ . "log_level";
                my $exists = -f $filename;
                my $content;
                if ($exists) {
                    open my($f), $filename;
                    $content = <$f>;
                    chomp($content) if defined($content);
                    close $f;
                }
                _debug("Checking level flag file content $filename: ",
                       (defined($content) ? $content : "(undef)"));
                if (defined $content) {
                    $level = _check_level($content,
                                          "level flag file $filename");
                    $from = $filename;
                    last SET;
                }

                $filename = "$dir/$spec->{name}." . $P_ . uc($_->[0]);
                $exists = -e $filename;
                _debug("Checking level flag file $filename: ",
                       ($exists ? "EXISTS" : 0));
                if ($exists) {
                    $level = $_->[1];
                    $from = $filename;
                    last SET;
                }
            }
        }

        no strict 'refs';
        for ("${F_}Log_Level", "${P_}LOG_LEVEL", "${p_}log_level",
             "${F_}LogLevel",  "${P_}LOGLEVEL",  "${p_}loglevel") {
            my $varname = "main::$_";
            _debug("Checking variable \$$varname: ", _ifdef($$varname, "(undef)"));
            if ($$varname) {
                $from = "\$$varname";
                $level = _check_level($$varname, "\$$varname");
                last SET;
            }
        }
        for (@label2level) {
            for my $varname (
                "main::$F_" . ucfirst($_->[0]),
                "main::$P_" . uc($_->[0])) {
                _debug("Checking variable \$$varname: ", _ifdef($$varname, "(undef)"));
                if ($$varname) {
                    $from = "\$$varname";
                    $level = $_->[1];
                    last SET;
                }
            }
        }
    }

    _debug("Set ", ($which ? "level of $which" : "general level"), " to $level (from $from)") if $level;
    return $level;
}

# return the lower level (e.g. _min_level("debug", "INFO") -> INFO
sub _min_level {
    my ($l1, $l2) = @_;
    my %vals = (OFF=>99,
                FATAL=>6, ERROR=>5, WARN=>4, INFO=>3, DEBUG=>2, TRACE=>1);
    $vals{uc($l1)} > $vals{uc($l2)} ? $l2 : $l1;
}

sub _export_logger {
    my ($caller) = @_;
    my $log_for_caller = Log::Any->get_logger(category => $caller);
    my $varname = "$caller\::log";
    no strict 'refs';
    *$varname = \$log_for_caller;
}

sub _debug {
    return unless $ENV{LOGANYAPP_DEBUG};
    print $dbg_ctx, ": " if $dbg_ctx;
    print @_, "\n";
}

sub import {
    my ($self, @args) = @_;
    my $caller = caller();
    _parse_args(\@args, $caller);
    $init_args = \@args;
}

{
    no warnings;
    # if we are loaded at run-time, it's too late to run INIT blocks, so user
    # must call init() manually. but sometimes this is what the user wants. so
    # shut up perl warning.
    INIT {
        my $caller = caller();
        init($init_args, $caller);
    }
}

1;
# ABSTRACT: Yet another logging framework (Log::Any, CLI apps)

=head1 SYNOPSIS

Use via Log::Any::App (1.00 and newer):

 # in your script.pl
 use Log::Any::App '$log';
 $log->warn("blah ...");
 if ($log->is_debug) { ... }

 # or, in command line
 % perl -MLog::Any::App -MModuleThatUsesLogAny -e'...'

See L<Log::Any::App> for more details.


=head1 DESCRIPTION

Log::Gurat, or Gurat for short, is... yes, yet another logging framework. It is
designed for command-line scripts/daemons and to work with L<Log::Any> and
L<Log::Any::App>. It has the following design goals: easy configuration
(optional, using hash instead of config files, Perlish), low startup overhead,
flexibility (changing levels and categories on the fly).

B<Logging>.

Logging is the activity of sending a message to the logger.

What is logged? Usually

What for? Debugging, audit, ...

B<Levels>.

There is the general level. Per output level. Per-category level.

L<Categories>.

Dot-separated. Tree/hierarchical.

L<Outputs>.

An output can be given a default per-output level that overrides the general
level.

A log message can be

=head1 AVAILABLE OUTPUTS

=head2 L<Log::Gurat::Output::Screen>

=head2 L<Log::Gurat::Output::Syslog>

=head2 L<Log::Gurat::Output::File>

Using L<File::Write::Rotate> which is a simpler and leaner version of
L<Log::Dispatch::FileRotate>.

=head2 L<Log::Gurat::Output::Dir>

=head2 L<Log::Gurat::Output::LogDispatch>

=head2 Others

See CPAN for other outputs that might be available.


=head1 METHODS

=head2 Log::Gurat->new(%args) => OBJ

Create new logger object. Known arguments:

=over

=item * config => HASH

Logging configuration. See C<config()> for more details.

=back

=head2 $log->config(\%config)

(Re-)configure logging. Configuration has

=over

=item * level => STR

Set general level. Default level is 'off', which means not to do any logging.

=item * category_levels => HASH

Can be used to change the levels of some category.

For example to shut up some noisy modules.

Or to debug a certain module only.

=item * category_aliases => HASH

=back


=head1 FAQ

=head2 Why yet another logging framework? Why not Log4perl?

I know. I actually do not really want to have to write another logging
framework. I have used L<Log::Log4perl> for years, and then L<Log::Any> (using
the Log4perl backend, via L<Log::Any::App> for easy [non-]configuration).

=head2 Why not Log::Log4perl?

Mainly because of its configuration syntax. Also, although not super-heavy, I
want a leaner alternative to Log::Log4perl + L<Log::Dispatch::FileRotate>. Thus,
Gurat and L<File::Write::Rotate>.

=head2 init(\@args)

This is the actual function that implements the setup and configuration of
logging. You normally need not call this function explicitly (but see below), it
will be called once in an INIT block. In fact, when you do:

 use Log::Any::App 'a', 'b', 'c';

it is actually passed as:

 init(['a', 'b', 'c']);

You will need to call init() manually if you require Log::Any::App at runtime,
in which case it is too late to run INIT block. If you want to run Log::Any::App
in runtime phase, do this:

 require Log::Any::App;
 Log::Any::App::init(['a', 'b', 'c']);

Arguments to init can be one or more of:

=over 4

=item -name => STRING

Change the program name. Default is taken from $0.

=item -level_flag_paths => ARRAY OF STRING

Edit level flag file locations. The default is [$homedir, "/etc"].

=item -category_alias => {ALIAS=>CATEGORY, ...}

Create category aliases so the ALIAS can be used in place of real categories in
each output's category specification. For example, instead of doing this:

 init(
     -file   => [category=>[qw/Foo Bar Baz/], ...],
     -screen => [category=>[qw/Foo Bar Baz/]],
 );

you can do this instead:

 init(
     -category_alias => {-fbb => [qw/Foo Bar Baz/]},
     -file   => [category=>'-fbb', ...],
     -screen => [category=>'-fbb', ...],
 );

You can also specify this from the environment variable LOG_CATEGORY_ALIAS using
JSON encoding, e.g.

 LOG_CATEGORY_ALIAS='{"-fbb":["Foo","Bar","Baz"]}'

=item -category_level => {CATEGORY=>LEVEL, ...}

Specify per-category level. Categories not mentioned on this will use the
general level (-level). This can be used to increase or decrease logging on
certain categories/modules.

You can also specify this from the environment variable LOG_CATEGORY_LEVEL using
JSON encoding, e.g.

 LOG_CATEGORY_LEVEL='{"-fbb":"off"}'

=item -file => 0 | 1|yes|true | PATH | {opts} | [{opts}, ...]

Specify output to one or more files, using L<Log::Dispatch::FileRotate>.

If the argument is a false boolean value, file logging will be turned off. If
argument is a true value that matches /^(1|yes|true)$/i, file logging will be
turned on with default path, etc. If the argument is another scalar value then
it is assumed to be a path. If the argument is a hashref, then the keys of the
hashref must be one of: C<level>, C<path>, C<max_size> (maximum size before
rotating, in bytes, 0 means unlimited or never rotate), C<histories> (number of
old files to keep, excluding the current file), C<date_pattern> (will be passed
to DatePattern argument in FileRotate's constructor), C<tz> (will be passed to
TZ argument in FileRotate's constructor), C<category> (a string of ref to array
of strings), C<category_level> (a hashref, similar to -category_level),
C<pattern_style> (see L<"PATTERN STYLES">), C<pattern> (Log4perl pattern).

If the argument is an arrayref, it is assumed to be specifying multiple files,
with each element of the array as a hashref.

How Log::Any::App determines defaults for file logging:

If program is a one-liner script specified using "perl -e", the default is no
file logging. Otherwise file logging is turned on.

If the program runs as root, the default path is C</var/log/$NAME.log>, where
$NAME is taken from B<$0> (or C<-name>). Otherwise the default path is
~/$NAME.log. Intermediate directories will be made with L<File::Path>.

If specified C<path> ends with a slash (e.g. "/my/log/"), it is assumed to be a
directory and the final file path is directory appended with $NAME.log.

Default rotating behaviour is no rotate (max_size = 0).

Default level for file is the same as the global level set by B<-level>. But
App::options, command line, environment, level flag file, and package variables
in main are also searched first (for B<FILE_LOG_LEVEL>, B<FILE_TRACE>,
B<FILE_DEBUG>, B<FILE_VERBOSE>, B<FILE_QUIET>, and the similars).

You can also specify category level from environment FILE_LOG_CATEGORY_LEVEL.

=item -dir => 0 | 1|yes|true | PATH | {opts} | [{opts}, ...]

Log messages using L<Log::Dispatch::Dir>. Each message is logged into separate
files in the directory. Useful for dumping content (e.g. HTML, network dumps, or
temporary results).

If the argument is a false boolean value, dir logging will be turned off. If
argument is a true value that matches /^(1|yes|true)$/i, dir logging will be
turned on with defaults path, etc. If the argument is another scalar value then
it is assumed to be a directory path. If the argument is a hashref, then the
keys of the hashref must be one of: C<level>, C<path>, C<max_size> (maximum
total size of files before deleting older files, in bytes, 0 means unlimited),
C<max_age> (maximum age of files to keep, in seconds, undef means unlimited).
C<histories> (number of old files to keep, excluding the current file),
C<category>, C<category_level> (a hashref, similar to -category_level),
C<pattern_style> (see L<"PATTERN STYLES">), C<pattern> (Log4perl pattern),
C<filename_pattern> (pattern of file name).

If the argument is an arrayref, it is assumed to be specifying multiple
directories, with each element of the array as a hashref.

How Log::Any::App determines defaults for dir logging:

Directory logging is by default turned off. You have to explicitly turn it on.

If the program runs as root, the default path is C</var/log/$NAME/>, where $NAME
is taken from B<$0>. Otherwise the default path is ~/log/$NAME/. Intermediate
directories will be created with File::Path. Program name can be changed using
C<-name>.

Default rotating parameters are: histories=1000, max_size=0, max_age=undef.

Default level for dir logging is the same as the global level set by B<-level>.
But App::options, command line, environment, level flag file, and package
variables in main are also searched first (for B<DIR_LOG_LEVEL>, B<DIR_TRACE>,
B<DIR_DEBUG>, B<DIR_VERBOSE>, B<DIR_QUIET>, and the similars).

You can also specify category level from environment DIR_LOG_CATEGORY_LEVEL.

=item -screen => 0 | 1|yes|true | {opts}

Log messages using L<Log::Log4perl::Appender::ScreenColoredLevels>.

If the argument is a false boolean value, screen logging will be turned off. If
argument is a true value that matches /^(1|yes|true)$/i, screen logging will be
turned on with default settings. If the argument is a hashref, then the keys of
the hashref must be one of: C<color> (default is true, set to 0 to turn off
color), C<stderr> (default is true, set to 0 to log to stdout instead),
C<level>, C<category>, C<category_level> (a hashref, similar to
-category_level), C<pattern_style> (see L<"PATTERN STYLE">), C<pattern>
(Log4perl string pattern).

How Log::Any::App determines defaults for screen logging:

Screen logging is turned on by default.

Default level for screen logging is the same as the global level set by
B<-level>. But App::options, command line, environment, level flag file, and
package variables in main are also searched first (for B<SCREEN_LOG_LEVEL>,
B<SCREEN_TRACE>, B<SCREEN_DEBUG>, B<SCREEN_VERBOSE>, B<SCREEN_QUIET>, and the
similars).

Color can also be turned on/off using environment variable COLOR (if B<color>
argument is not set).

You can also specify category level from environment SCREEN_LOG_CATEGORY_LEVEL.

=item -syslog => 0 | 1|yes|true | {opts}

Log messages using L<Log::Dispatch::Syslog>.

If the argument is a false boolean value, syslog logging will be turned off. If
argument is a true value that matches /^(1|yes|true)$/i, syslog logging will be
turned on with default level, ident, etc. If the argument is a hashref, then the
keys of the hashref must be one of: C<level>, C<ident>, C<facility>,
C<category>, C<category_level> (a hashref, similar to -category_level),
C<pattern_style> (see L<"PATTERN STYLES">), C<pattern> (Log4perl pattern).

How Log::Any::App determines defaults for syslog logging:

If a program is a daemon (determined by detecting modules like L<Net::Server> or
L<Proc::PID::File>, or by checking if -daemon or $main::IS_DAEMON is true) then
syslog logging is turned on by default and facility is set to C<daemon>,
otherwise the default is off.

Ident is program's name by default ($0, or C<-name>).

Default level for syslog logging is the same as the global level set by
B<-level>. But App::options, command line, environment, level flag file, and
package variables in main are also searched first (for B<SYSLOG_LOG_LEVEL>,
B<SYSLOG_TRACE>, B<SYSLOG_DEBUG>, B<SYSLOG_VERBOSE>, B<SYSLOG_QUIET>, and the
similars).

You can also specify category level from environment SYSLOG_LOG_CATEGORY_LEVEL.

=item -dump => BOOL

If set to true then Log::Any::App will dump the generated Log4perl config.
Useful for debugging the logging.

=back


=head1 PATTERN STYLES

Log::Any::App provides some styles for Log4perl patterns. You can specify
C<pattern_style> instead of directly specifying C<pattern>. example:

 use Log::Any::App -screen => {pattern_style=>"script_long"};

 Name           Description                        Example output
 ----           -----------                        --------------
 plain          The message, the whole message,    Message
                and nothing but the message.
                Used by dir logging.

                Equivalent to pattern: '%m'

 script_short   For scripts that run for a short   [234] Message
                time (a few seconds). Shows just
                the number of milliseconds. This
                is the default for screen.

                Equivalent to pattern:
                '[%r] %m%n'

 script_long    Scripts that will run for a        [2010-04-22 18:01:02] Message
                while (more than a few seconds).
                Shows date/time.

                Equivalent to pattern:
                '[%d] %m%n'

 daemon         For typical daemons. Shows PID     [pid 1234] [2010-04-22 18:01:02] Message
                and date/time. This is the
                default for file logging.

                Equivalent to pattern:
                '[pid %P] [%d] %m%n'

 syslog         Style suitable for syslog          [pid 1234] Message
                logging.

                Equivalent to pattern:
                '[pid %p] %m'

For each of the above there are also C<cat_XXX> (e.g. C<cat_script_long>) which
are the same as XXX but with C<[cat %c]> in front of the pattern. It is used
mainly to show categories and then filter by categories. You can turn picking
default pattern style with category using environment variable
LOG_SHOW_CATEGORY.

And for each of the above there are also C<loc_XXX> (e.g. C<loc_syslog>) which
are the same as XXX but with C<[loc %l]> in front of the pattern. It is used to
show calling location (file, function/method, and line number). You can turn
picking default pattern style with location prefix using environment variable
LOG_SHOW_LOCATION.

If you have a favorite pattern style, please do share them.


=head2 How do I create extra logger objects?

The usual way as with Log::Any:

 my $other_log = Log::Any->get_logger(category => $category);


=head1 SEE ALSO

Alternative logging frameworks: L<Log::Log4perl> (one of the most popular ones),
L<Log::Dispatchouli> (also seems to be popular, too simplistic and inflexible
for my taste), L<Log::Dispatch> (does not have the concept of categories, but
offers a lot of output choices; note that these outputs can be used by Gurat
using L<Log::Gurat::Output::LogDispatch>).

L<Log::Any>, a "meta" logging framework. Gurat is meant to be used with
Log::Any. You produce logs in your modules with Log::Any, and when you want to
display the logs in the outputs, you use Gurat (usually via L<Log::Any::App>).

L<Log::Any::App>, to be used in command-line scripts/daemons, to
(auto-)configure Gurat with some nice defaults.

=cut
