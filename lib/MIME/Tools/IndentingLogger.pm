package MIME::Tools::IndentingLogger;


=head1 NAME

MIME::Tools::IndentingLogger - wrap a logger in an indenting mechanism


=head1 SYNOPSIS

    ### Create the logger:
    $backend_logger = ...;   
    $logger = MIME::Tools::IndentingLogger->new($backend_logger);
    
    ### Change indentation level:
    $logger->level(+1);
    
    ### Log messages of various types (indents, then relays to backend):
    $logger->debug("about to open config file");
    $logger->warning("missing config file: must create");
    $logger->error("unable to create config file");


=head1 DESCRIPTION

Wrap any logger in an object which will automatically indent 
the given messages before passing them on.

This is useful in Parsing complex MIME entities: the 
logged messages can be indented based on how deeply they
are nested in the entity.


=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;
use Carp qw(croak);

use base qw(MIME::Tools::Logger);

#------------------------------

=item new LOGGER

I<Class method, constructor.>
Create a new logger around the given backend LOGGER.

=cut

sub new {
    my ($class, $backend) = @_;
    $backend or croak "need a legit backend logger";
    bless { 
	MTIL_Backend => $backend,
	MTIL_Indent  => '   ',
	MTIL_Level   => 0,
    }, $class;
}

#------------------------------

=item level [+1|-1]

I<Instance method.>
Alter/get current parsing level.

=cut

sub level {
    my ($self, $lvl) = @_;
    $self->{MTIL_Level} += $lvl if @_ > 1;
    $self->{MTIL_Level};
}

#------------------------------
#
# indent
#
# Instance method, private.
# Return indent for current parsing level.
#
sub indent {
    my ($self) = @_;
    $self->{MTIL_Indent} x $self->{MTIL_Level};
}

#------------------------------

=item debug MESSAGE...

=item warning MESSAGE...

=item error MESSAGE...

I<Instance methods, concrete overrides.>
Indent the given messages, then use the backend to log them.

=cut

sub debug { 
    my $self = shift;
    $self->{MTIL_Backend}->debug($self->indent, @_);
}

sub warning { 
    my $self = shift;
    $self->{MTIL_Backend}->warning($self->indent, @_);
}

sub error { 
    my $self = shift;
    $self->{MTIL_Backend}->error($self->indent, @_);
}

=back

=cut

1;


