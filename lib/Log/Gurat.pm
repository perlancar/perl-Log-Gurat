package Log::Gurat;

# DATE
# VERSION

#IFUNBUILT
use strict 'subs', 'vars';
use warnings;
#END IFUNBUILT

our $log_level = 'warn';

my %num_levels = (
    off     => 0,
    fatal   => 1,
    error   => 2,
    warn    => 3,
    info    => 4,
    debug   => 5,
    trace   => 6,
);

sub import {
    my $self = shift;

    my $wanted_num_level = $num_levels{$log_level};
    defined($wanted_num_level) or die "Unknown log level '$log_level'";

    my $caller = caller(0);

    for my $str_level (keys %num_levels) {
        my $num_level = $num_levels{$str_level};
        next unless $num_level > 0;
        #print "D:creating $caller\::is_$str_level\n";
        *{"$caller\::is_$str_level"} = $num_level <= $wanted_num_level ?
            sub {1} : sub() {0};
        if ($num_level <= $wanted_num_level) {
            *{"$caller\::log_$str_level"} = sub {
                print @_;
            };
            *{"$caller\::log_${str_level}f"} = sub {
                printf @_;
            };
        } else {
            # optimize away, this code is stolen from Exporter::ConditionalSubs.

            # due to loading of B::CallChecker and B::Generate, this causes some
            # startup cost, we only care about optimizing away when in
            # production, the cost of empty sub call is ~80ns (on a Core i5-2400
            # 3GHz) so it's only significant in a very tight loop
            if ($ENV{LOG_PRODUCTION}) {
                require B::CallChecker;
                require B::Generate;
                B::CallChecker::cv_set_call_checker(
                    \&{"$caller\::log_$str_level"},
                    sub { B::SVOP->new("const",0,!1) },
                    \!1,
                );
                B::CallChecker::cv_set_call_checker(
                    \&{"$caller\::log_${str_level}f"},
                    sub { B::SVOP->new("const",0,!1) },
                    \!1,
                );
            } else {
                # this won't be optimized away because it's not a constant sub
                # (note the lack of the () prototype)
                *{"$caller\::log_$str_level"} = sub {0};
                *{"$caller\::log_${str_level}f"} = sub {0};
            }
        }
    }
}


1;
# ABSTRACT: Yet another logging framework

=head1 SYNOPSIS

In your module (producer):

 package Foo;
 use Log::Gurat;

 # log a string
 log_error "an error occurred";

 # log a string and data using formatting filter
 log_debugf "arguments are: %s", \@_;

In your application:



=head1 DESCRIPTION

Another logging framework. Like L<Log::Any>, it separates producers and
consumers. Unlike L<Log::Any>, it uses plain functions (non-OO).

Some features:

=over

=item * Option to optimize away the logging statements when unnecessary:

 % perl -MLog::Gurat -MO=Deparse -e'log_warn "foo\n"; log_debug "bar\n"'
 log_warn("foo\n");
 log_debug("bar\n");
 -e syntax OK

 % LOG_PRODUCTION=1 perl -MLog::Gurat -MO=Deparse -e'log_warn "foo\n"; log_debug "bar\n"'
 log_warn("foo\n");
 '???';
 -e syntax OK

=item * Configurable levels via environment variables

=back


=head1 SEE ALSO

=cut
