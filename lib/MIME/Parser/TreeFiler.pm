package MIME::Parser::TreeFiler;


=head1 NAME

MIME::Parser::TreeFiler - file messages into a directory tree


=head1 SYNOPSIS

    ### Place message parts in subdirectories of "/tmp/msgs":
    $filer = MIME::Parser::TreeFiler->new("/tmp/msgs");  
    $parser->filer($filer);


=head1 DESCRIPTION

This concrete subclass of MIME::Parser::Filer supports filing under 
a given directory, using one subdirectory per message, but with
all message parts in the same directory.


=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;
use base qw(MIME::Parser::Filer);
use Carp qw(carp);

use vars qw($GSubdirNo);
$GSubdirNo = 0;

#------------------------------

=item init BASEDIR

I<Instance method, initiallizer.>
Set the base directory which will contain the message directories.
If used, then each parse of begins by creating a new subdirectory
under BASEDIR where the actual parts of the message are placed.  

=cut

sub init {
    my ($self, $basedir) = @_;

    $self->SUPER::init();
    $self->{MPTF_BaseDir} = $self->cleanup_dir($basedir);
}

#------------------------------
#
# init_parse
#
# I<Instance method, override.>
# Prepare to start parsing a new message.
#
sub init_parse {
    my $self = shift;

    ### Invoke inherited method first!
    $self->SUPER::init_parse;

    ### Determine the subdirectory of ther base to use:
    my $subdir_name = $self->create_message_subdirectory_name;
    my ($subdir_path) = File::Spec->catfile($self->base_dir, $subdir_name);
    $self->logger->debug("subdir = $subdir_path");

    ### Remove and re-create the per-message output directory:
    (-d $subdir_path) or
	mkdir $subdir_path, 0700 or 
	    die "mkdir $subdir_path: $!\n";

    ### Add the per-message output directory to the purgeables:
    $self->purgeable($subdir_path);

    ### Remember it, in case anyone cares:
    $self->{MPTF_LastMessageDir} = $subdir_path;
    1;
}

#------------------------------

=item base_dir

I<Instance method.>
Return the base directory we were created with, which is the
parent of the directories created for each individual message.

=cut

sub base_dir {
    my $self = shift;
    $self->{MPTF_BaseDir};
}

#------------------------------

=item create_message_subdirectory_name

I<Instance method, for subclasses only.>
A new message is being parsed; synthesize a name of a new 
subdirectory under the "base_dir" where the message will be
placed.

The default creates a name like:

    msg-{unixtime}-{process id}-{sequence number}

If you don't like this, subclass and override.

=cut

sub create_message_subdirectory_name {
    my $self = shift;
    return "msg-".scalar(time)."-$$-".$GSubdirNo++;
}

#------------------------------

=item last_message_dir

I<Instance method.>
Return the last message directory set up by init_parse().
This lets you write code like this:

    $filer = new MIME::Parser::TreeFiler->("/tmp");
    $parser->filer($filer);
    ...
    $ent = eval { $parser->parse_open($msg); };   
    if (!$ent) {	 ### parse failed
	die "parse failed: garbage is in ".$parser->last_message_dir."\n";
	...
    } 
    else {               ### parse succeeded
	...do stuff...
    }

=cut

sub last_message_dir {
    my $self = shift;
    $self->{MPTF_LastMessageDir};
}

#------------------------------

=item output_dir HEAD

I<Instance method, override.>
Returns the output directory for the entity with the given HEAD;
this will be used by output_path() to create the full path
needed by the MIME::Parser.

=cut

sub output_dir {
    shift->last_message_dir;
}

=back

=cut

1;
