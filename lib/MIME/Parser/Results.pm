package MIME::Parser::Results;

=head1 NAME

MIME::Parser::Results - results of the last entity parsed


=head1 SYNOPSIS

Before reading further, you should see L<MIME::Parser> to make sure that 
you understand where this module fits into the grand scheme of things.
Go on, do it now.  I'll wait.

Ready?  Ok...

   ### Do parse, get results:
   my $entity = eval { $parser->parse(\*STDIN); };
   my $results  = $parser->results;
   
   ### Get all messages logged:
   @msgs = $results->msgs;
   
   ### Get messages of specific types (also tests if there were problems):
   $had_errors   = $results->errors;
   $had_warnings = $results->warnings;
    
   ### Get outermost header:
   $top_head  = $results->top_head;


=head1 DESCRIPTION

Results from the last MIME::Parser parse.


=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;

### Kit modules:
use MIME::Tools qw(:config :msgs);
use base qw(MIME::Tools::Logger);

#------------------------------

=item new

I<Constructor.>
Creates an empty results object.

=cut

sub new {
    bless {
	MPR_Msgs  => [],
	MPR_Level => 0,
	MPR_TopHead => undef,
    }, shift;
}

#------------------------------

=item msgs

I<Instance method.>  
Return all messages that we logged, in order.
Every message is a string beginning with its type followed by C<": ">; 
the current types are C<debug>, C<warning>, and C<error>.

Note that debug messages are only output if the toolkit is
configured for debugging.

=cut

sub msgs { 
    @{shift->{MPR_Msgs}};
}

#------------------------------

=item warnings

I<Instance method.>  
Return all warning messages that we logged, in order.
A convenience front-end onto msgs().

=cut

sub warnings { 
    grep /^warning: /, @{shift->{MPR_Msgs}};
}

#------------------------------

=item errors

I<Instance method.>  
Return all error messages that we logged, in order.
A convenience front-end onto msgs().

=cut

sub errors { 
    grep /^error: /, @{shift->{MPR_Msgs}};
}



#------------------------------

=item top_head

I<Instance method.>  
Return the topmost header, if we were able to read it.
This may be useful if the parse fails.

=cut

sub top_head { 
    my ($self, $head) = @_;
    $self->{MPR_TopHead} = $head if @_ > 1;
    $self->{MPR_TopHead};
}




#------------------------------
#
# PRIVATE: FOR USE DURING PARSING ONLY!
#

#------------------------------
#
# _msg TYPE, MESSAGE...
#
# Take a message.
#
sub _msg {
    my $self = shift;
    my $type = shift;
    my @args = map { defined($_) ? $_ : '<<undef>>' } @_;

    push @{$self->{MPR_Msgs}}, ($type.": ".join('', @args)."\n");
}

### The MIME::Tools::Logger interface
sub debug   { shift->_msg('debug',   @_) if $CONFIG{DEBUGGING}; }
sub warning { shift->_msg('warning', @_); }
sub error   { shift->_msg('error',   @_); }

=back

=cut

1;
__END__


=head1 AUTHOR

Eryq (F<eryq@zeegee.com>), ZeeGee Software Inc (F<http://www.zeegee.com>).

All rights reserved.  This program is free software; you can redistribute 
it and/or modify it under the same terms as Perl itself.


=head1 VERSION

$Revision: 6.106 $











