package MIME::Tools::Logger;


=head1 NAME

MIME::Tools::Logger - an abstract logger of messages


=head1 SYNOPSIS

    ### Log messages of various types:
    $logger->debug("about to open config file");
    $logger->warning("missing config file: must create");
    $logger->error("unable to create config file");


=head1 DESCRIPTION

Lots of things happen in parsing MIME messages, and a good
reporting mechanism is very useful.  This class defines
the abstract interface.


=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;
use Carp qw(croak);


#------------------------------

=item debug MESSAGE...

I<Instance method, abstract.>
Log a debugging message.  
The MESSAGE should I<not> be newline-terminated.
Generally, one would not see such messages operationally.

=cut

sub debug { croak "debug() must be overridden"; }

#------------------------------

=item warning MESSAGE...

I<Instance method, abstract.>
Log a message describing an unusual situation.
The MESSAGE should I<not> be newline-terminated.

Note that this is not the same as just using Perl's warn() facility
(though a concrete subclass may choose to do that).

=cut

sub warning { croak "warning() must be overridden"; }

#------------------------------

=item error MESSAGE...

I<Instance method, abstract.>
Log a message describing a problem.
The MESSAGE should I<not> be newline-terminated.

Usually, such messages signal points at which exceptions are
(or would be) thrown.

=cut

sub error { croak "error() must be overridden"; }

=back

=cut

1;


