package MIME::Tools::NullLogger;


=head1 NAME

MIME::Tools::NullLogger - a logger that discards all messages


=head1 SYNOPSIS

    ### Creation:
    $logger = new MIME::Tools::NullLogger;
    
    ### Log messages of various types:
    $logger->debug("about to open config file");
    $logger->warning("missing config file: must create");
    $logger->error("unable to create config file");


=head1 DESCRIPTION

Just discards the messages received.

=cut

use strict;
use base qw(MIME::Tools::Logger);

sub new { bless {}, shift }

sub debug   { }
sub warning { }
sub error   { }

1;


