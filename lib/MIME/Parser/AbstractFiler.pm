package MIME::Parser::AbstractFiler;

=head1 NAME

MIME::Parser::AbstractFiler - manage file-output of the parser


=head1 SYNOPSIS

Before reading further, you should see L<MIME::Parser> to make sure that 
you understand where this module fits into the grand scheme of things.
Go on, do it now.  I'll wait.

Ready?  Ok... now read L<"DESCRIPTION"> below, and everything else
should make sense.



=head1 DESCRIPTION


=head2 How this class is used when parsing

When a MIME::Parser decides that it wants to output a file to disk,
it uses its "Filer" object -- an instance of a MIME::Parser::AbstractFiler 
subclass -- to determine where to put the file.  

Every parser has a single Filer object, which it uses for all
parsing.  You can get the Filer for a given $parser like this:

    $filer = $parser->filer;

At the beginning of each C<parse()>, the filer's internal state
is reset by the parser: 

    $parser->filer->init_parse;

The parser can then get a path for each entity in the message
by handing that entity's header (a MIME::Head) to the filer 
and having it do the work, like this:

    $new_file = $parser->filer->output_path($head);

Since it's nice to be able to clean up after a parse (especially
a failed parse), the parser tells the filer when it has actually 
used a path:

    $parser->filer->purgeable($new_file);

Then, if you want to clean up the files which were created for a
particular parse (and also any directories that the Filer created),
you would do this:

    $parser->filer->purge;



=head2 Writing your own subclasses

The main concrete subclass of this class is B<MIME::Parser::Filer>,
which provides a lot of practical logic.  You should subclass 
that class; see there for details.

In general, though, the only method you have to 
override is L<output_path()|/output_path>:

    $filer->output_path($head);

This method is invoked by MIME::Parser when it wants to put a 
decoded message body in an output file.  The method should return a 
path to the file to create.  Failure is indicated by throwing an 
exception.

The path returned by C<output_path()> should be "ready for open()":
any necessary parent directories need to exist at that point.
These directories can be created by the Filer, if course, and they
should be marked as B<purgeable()> if a purge should delete them.



=head1 PUBLIC INTERFACE


=over 4

=cut

use strict;

### Kit modules:
use MIME::Tools::NullLogger;
use File::Path qw(rmtree);
use Carp qw(croak);

#------------------------------

=item new INITARGS...

I<Class method, constructor.>
Create a new outputter for the given parser.
Any subsequent arguments are given to init(), which subclasses should
override for their own use (the default init does nothing).

=cut

sub new {
    my ($class, @initargs) = @_;
    my $self = bless {}, $class;
    $self->init(@initargs);
    $self;
}

sub init {
    my $self = shift;
    $self->purgeable([]);
}

#------------------------------

=item logger

I<Instance method.>
Set/get a MIME::Tools::Logger object to tally 
any interesting messages.  

=cut

sub logger {
    return $MIME::Tools::LOG;
}

#------------------------------

=item init_parse

I<Instance method.>
Prepare to start parsing a new message.
Subclasses should always be sure to invoke the inherited method.

=cut

sub init_parse {
    my $self = shift;
}

#------------------------------

=item output_path HEAD

I<Instance method, abstract.>
Given a MIME::Head for a file to be extracted, come up with a good
output pathname for the extracted file.  This is the only method
you need to subclass.

=cut

sub output_path {
    my ($self, $head) = @_;
    croak "abstract method output_path() must be implemented";
}

#------------------------------

=item purge

I<Instance method, final.>
Purge all files/directories created by the last parse.
This method simply goes through the purgeable list in reverse order 
(see L</purgeable>) and removes all existing files/directories in it.
You should not need to override this method.

=cut

sub purge {
    my ($self) = @_;
    foreach my $path (reverse @{$self->{MPAF_Purgeable}}) {
	(-e $path) or next;   ### must check: might delete DIR before DIR/FILE 
	rmtree($path, 0, 1);
	(! -e $path) or $self->logger->warning("unable to purge: $path");
    }
    1;
}

#------------------------------

=item purgeable [PATH]

I<Instance method, final.>
Add PATH to the list of "purgeable" files/directories (those which
will be removed if you do a C<purge()>).
You should not need to override this method.

If PATH is not given, the "purgeable" list is returned.
This may be used for more-sophisticated purging.

As a special case, invoking this method with a PATH that is an
arrayref will replace the purgeable list with a copy of the
array's contents, so [] may be used to clear the list.

Note that the "purgeable" list is cleared when a parser begins a 
new parse; therefore, if you want to use purge() to do cleanup,
you I<must> do so I<before> starting a new parse!

=cut

sub purgeable {
    my ($self, $path) = @_;
    return @{$self->{MPAF_Purgeable}} if (@_ == 1);   

    if (ref($path)) { $self->{MPAF_Purgeable} = [ @$path ]; }
    else            { push @{$self->{MPAF_Purgeable}}, $path; }
    1;
}

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



