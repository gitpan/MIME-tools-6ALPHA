package MIME::Tools::ToolkitLogger;


=head1 NAME

MIME::Tools::ToolkitLogger - a logger which uses Perl's warn() 


=head1 SYNOPSIS

    use MIME::Tools::ToolkitLogger;
    
    ### Creation:
    $logger = new MIME::Tools::ToolkitLogger;
    
    ### Log messages of various types:
    $logger->debug("about to open config file");
    $logger->warning("missing config file: must create");
    $logger->error("unable to create config file");


=head1 DESCRIPTION

This is the standard logger used by toolkit modules.


=over 4

=item debug() messages

These are printed directly to the STDERR, with a prefix of
C<"MIME-tools: debug">.

Debug message are only logged if you have turned
L</debugging> on in the MIME::Tools configuration.


=item warning() messages

These are logged by the standard Perl warn() mechanism
to indicate an unusual situation.
They all have a prefix of C<"MIME-tools: warning">.

Warning messages are only logged if C<$^W> is set true
and MIME::Tools is not configured to be L</quiet>.


=item error() messages

These are logged by the standard Perl warn() mechanism
to indicate that something actually failed.
They all have a prefix of C<"MIME-tools: error">.

Error messages are only logged if C<$^W> is set true
and MIME::Tools is not configured to be L</quiet>.

=back



=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;
use base qw(MIME::Tools::Logger);
use MIME::Tools;

#------------------------------

=item new [PREFIX]

I<Class method, constructor.>
Create the logger. 

The PREFIX, if given, precedes all messages; it makes it easier
to filter based on the toolkit.  
If given, the string should end in colon and space.
The default is "MIME-tools: ".

=cut

sub new {
    my $class = shift;
    my $prefix = shift || "MIME-tools: ";
    bless {
	MTWL_Prefix => $prefix,
	MTWL_Debugging => 0,
    }, $class;
}

#------------------------------

=item debug MESSAGE...

I<Instance method, concrete override.>
Output a debug message directly to STDERR.
Does nothing if debugging() was set false (the default).

=cut

sub debug {
    my $self = shift;
    return if !$MIME::Tools::CONFIG{DEBUGGING};
   
    print STDERR $self->{MTWL_Prefix}, "debug: ", @_, "\n";
}

#------------------------------

=item warning MESSAGE...

I<Instance method, concrete override.>
Output a warning message, using Perl's warn().

=cut

sub warning {
    my $self = shift;
    return if !$^W || $MIME::Tools::CONFIG{QUIET};

    warn $self->{MTWL_Prefix}, "warning: ", @_, "\n";
}

#------------------------------

=item error MESSAGE...

I<Instance method, concrete override.>
Output an error message, using Perl's warn().

=cut

sub error {
    my $self = shift;
    return if !$^W || $MIME::Tools::CONFIG{QUIET};

    warn $self->{MTWL_Prefix}, "error: ", @_, "\n";
}


=back


=head1 NOTES

All outgoing messages are automatically newline-terminated.

This really could be broken out into two classes: one which 
just logs to warn(), and a wrapper which consults MIME::Tools
configuration before doing anything.



=head1 SEE ALSO

See L<MIME::Tools::Logger> to learn about our superclass,
and how loggers work.

See L<MIME::Tools> for more information on configuring the
toolkit options which affect this module, particularly
debugging() and quiet().

See L<perlvar> for details on $^W.

=cut

1;
