package MIME::Parser::FlatFiler;


=head1 NAME

MIME::Parser::FlatFiler - file into a single directory


=head1 SYNOPSIS

    ### Place message parts in "/tmp/msgparts":
    $filer = MIME::Parser::FlatFiler->new("/tmp/msgparts");  
    $parser->filer($filer);


=head1 DESCRIPTION

This concrete subclass of MIME::Parser::Filer supports filing 
all files of all parsed messages into a single given directory.


=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;
use base qw(MIME::Parser::Filer);

#------------------------------

=item init DIRECTORY

I<Instance method, initiallizer.>
Set the directory where all files will go.

=cut

sub init {
    my ($self, $dir) = @_;

    $self->SUPER::init();
    $self->{MPFF_Dir} = $self->cleanup_dir($dir);
}

#------------------------------

=item output_dir HEAD

I<Instance method, concrete override.>
Return the output directory where the files go.
With this simple filer class, this never changes.

=cut

sub output_dir {
    shift->{MPFF_Dir};
}

=back

=cut


1;
