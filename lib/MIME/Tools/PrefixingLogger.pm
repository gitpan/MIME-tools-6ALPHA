package MIME::Tools::PrefixingLogger;


=head1 NAME

MIME::Tools::PrefixingLogger - wrap a logger in an prefixing mechanism


=head1 SYNOPSIS

    ### Create the logger:
    $backend_logger = ...;   
    $logger = MIME::Tools::PrefixingLogger->new($backend_logger);
    
    ### Change prefix (comments show sample of subsequent logged messages):
    $logger->push_prefix("1");           ### 1: message...
    $logger->push_prefix("A");           ### 1: A: message...
    $logger->pop_prefix;                 ### 1: message...
    $logger->push_prefix("B");           ### 1: B: message...
    
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
	MTPL_Backend => $backend,
	MTPL_Head => '',
	MTPL_List => [],
	MTPL_Tail => ': ',
	MTPL_Sep  => ': ',
    }, $class;
}

#------------------------------

=item push_prefix PREFIX

I<Instance method.>
Push the given PREFIX.

=cut

sub push_prefix {
    my ($self, $prefix) = @_;
    delete $self->{MTPL_Prefix};  ### clear cache

    push @{$self->{MTPL_List}}, $prefix;
}

#------------------------------

=item pop_prefix 

I<Instance method.>
Pop the topmost prefix, and return it.

=cut

sub pop_prefix {
    my ($self) = @_;   
    delete $self->{MTPL_Prefix};  ### clear cache

    return pop @{$self->{MTPL_List}};
}

#------------------------------
#
# prefix
#
# Instance method, private.
# Return the catenated prefix.
#
sub prefix {
    my ($self) = @_;
    defined($self->{MTPL_Prefix}) or 
	$self->{MTPL_Prefix} = ($self->{MTPL_Head} . 
				join($self->{MTPL_Sep}, @{$self->{MTPL_List}}).
				$self->{MTPL_Tail});
    $self->{MTPL_Prefix};
}

#------------------------------

=item debug MESSAGE...

=item warning MESSAGE...

=item error MESSAGE...

I<Instance methods, concrete overrides.>
Prefix the given messages, then use the backend to log them.

=cut

sub debug { 
    my $self = shift;
    $self->{MTPL_Backend}->debug($self->prefix, @_);
}

sub warning { 
    my $self = shift;
    $self->{MTPL_Backend}->warning($self->prefix, @_);
}

sub error { 
    my $self = shift;
    $self->{MTPL_Backend}->error($self->prefix, @_);
}

=back

=cut

1;


