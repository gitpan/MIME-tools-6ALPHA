package MIME::Parser;


=head1 NAME

MIME::Parser - experimental class for parsing MIME streams


=head1 SYNOPSIS

Before reading further, you should see L<MIME::Tools> to make sure that
you understand where this module fits into the grand scheme of things.
Go on, do it now.  I'll wait.

Ready?  Ok...

=head2 Basic usage examples

    ### Create a new parser object:
    my $parser = new MIME::Parser;

    ### Tell it where to put things:
    $parser->output_under("/tmp");

    ### Parse an input filehandle:
    $entity = $parser->parse(\*STDIN);

    ### Congratulations: you now have a (possibly multipart) MIME entity!
    $entity->dump_skeleton;          # for debugging


=head2 Examples of input

    ### Parse from filehandles:
    $entity = $parser->parse(\*STDIN);
    $entity = $parser->parse(IO::File->new("some command|");

    ### Parse from any object that supports getline() and read():
    $entity = $parser->parse($myHandle);

    ### Parse an in-core MIME message:
    $entity = $parser->parse_data($message);

    ### Parse an MIME message in a file:
    $entity = $parser->parse_open("/some/file.msg");

    ### Parse an MIME message out of a pipeline:
    $entity = $parser->parse_open("gunzip - < file.msg.gz |");

    ### Parse already-split input (as "deliver" would give it to you):
    $entity = $parser->parse_two("msg.head", "msg.body");


=head2 Examples of output control

    ### Keep parsed message bodies in core (default outputs to disk):
    $parser->output_to_core(1);

    ### Output each message body to a one-per-message directory:
    $parser->output_under("/tmp");

    ### Output each message body to the same directory:
    $parser->output_dir("/tmp");

    ### Change how nameless message-component files are named:
    $parser->output_prefix("msg");


=head2 Examples of error recovery

    ### Normal mechanism:
    eval { $entity = $parser->parse(\*STDIN) };
    if ($@) {
	$results  = $parser->results;
	$decapitated = $parser->last_head;  ### get last top-level head
    }

    ### Ultra-tolerant mechanism:
    $parser->ignore_errors(1);
    $entity = eval { $parser->parse(\*STDIN) };
    $error = ($@ || $parser->last_error);

    ### Cleanup all files created by the parse:
    eval { $entity = $parser->parse(\*STDIN) };
    ...
    $parser->filer->purge;


=head2 Examples of parser options

    ### Parse contained "message/rfc822" objects as nested MIME streams?
    $parser->extract_nested_messages(0);    ### default is true

    ### Look for uuencode in "text" messages, and extract it?
    $parser->extract_uuencode(1);           ### default is false

    ### Should we forgive normally-fatal errors?
    $parser->ignore_errors(0);              ### default is true


=head2 Miscellaneous examples

    ### Convert a Mail::Internet object to a MIME::Entity:
    @lines = (@{$mail->header}, "\n", @{$mail->body});
    $entity = $parser->parse_data(\@lines);



=head1 DESCRIPTION

You can inherit from this class to create your own subclasses
that parse MIME streams into MIME::Entity objects.


=head1 PUBLIC INTERFACE

=cut

#------------------------------

# We require the new FileHandle methods, and a non-buggy version
# of FileHandle->new_tmpfile:
require 5.004;

### Pragmas:
use strict;

### Built-in modules:
use FileHandle ();
use IO::Wrap;
use IO::Scalar       1.117;
use IO::ScalarArray  1.114;
use IO::Lines        1.108;
use IO::File;
use IO::InnerFile;
use File::Spec;
use File::Path;
use Config qw(%Config);
use Carp;

### Kit modules:
use MIME::Tools qw(:config :utils :msgs tmpopen );
use MIME::Head;
use MIME::Body;
use MIME::Entity;
use MIME::Decoder;
use MIME::Parser::Reader;
use MIME::Parser::Filer;
use MIME::Parser::FlatFiler;
use MIME::Parser::TreeFiler;
use MIME::Parser::Results;
use MIME::Parser::UURedoer;
use MIME::Tools::IndentingLogger;
use MIME::Tools::PrefixingLogger;
use MIME::Tools::NullLogger;



#============================================================
#
# A special kind of inner file that we can virtually print to.
#
package MIME::Parser::InnerFile;

use base qw(IO::InnerFile);

sub print {
    shift->add_length(length(join('', @_)));
}

sub PRINT  {
    shift->{LG} += length(join('', @_));
}




#============================================================

package MIME::Parser;


#------------------------------
#
# GLOBALS...
#
#------------------------------

### The package version, both in 1.23 style *and* usable by MakeMaker:
use vars qw($VERSION);
$VERSION = substr q$Revision: 6.106 $, 10;


#------------------------------
#
# CONSTANTS...
#
#------------------------------

### Message classifications:
my $CLASS_MULTIPART  = 'multipart';   # unencoded body is a MIME multipart body
my $CLASS_SINGLEPART = 'singlepart';  # unencoded body is a re-parseable msg
my $CLASS_MESSAGE    = 'message';     # unencoded body is anything else

### Reader end-of-stream types:
my $EOS_CLOSE = 'CLOSE';
my $EOS_DELIM = 'DELIM';

### Extract-nested options:
my $EXTRACT_NEST    = 'NEST';
my $EXTRACT_REPLACE = 'REPLACE';


#------------------------------------------------------------

=head2 Construction

=over 4

=cut

#------------------------------

=item new ARGS...

I<Class method.>
Create a new parser object.
Once you do this, you can then set up various parameters
before doing the actual parsing.  For example:

    my $parser = new MIME::Parser;
    $parser->output_dir("/tmp");
    $parser->output_prefix("msg1");
    my $entity = $parser->parse(\*STDIN);

Any arguments are passed into C<init()>.
Don't override this in your subclasses; override init() instead.

=cut

sub new {
    my $self = bless {}, shift;
    $self->init(@_);
}

#------------------------------

=item init ARGS...

I<Instance method.>
Initiallize a new MIME::Parser object.
This is automatically sent to a new object; you may want to override it.
If you override this, you I<must> invoke the inherited method.

=cut

sub init {
    my $self = shift;



    ###
    ### More-or-less constants:
    ###

    ### What should be classified as a parseable message?
    $self->{MP_ClassifyAsMessage} = {
	"message/rfc822"           => 1,
	"application/x-pkcs7-mime" => 1,
    };

    ### Effective type for multipart messages with bad boundary:
    $self->{MP_EffectiveTypeForBadBound} = 
	"application/x-unparseable-multipart";

    ### Class name for the default factory method implementations:
    $self->{MP_DefaultFactoryClass} = {
	Head   => 'MIME::Head',
	Entity => 'MIME::Entity',
    };



    ###
    ### Simple settings:
    ###

    ### Core attributes:
    $self->{MP_DecodeHeaders}   = 0;
    $self->{MP_ExtractNested}   = $EXTRACT_NEST,
    $self->{MP_ExtractEncoded}  = 1;
    $self->{MP_TmpRecycling}    = 1;
    $self->{MP_TmpToCore}       = 0;
    $self->{MP_IgnoreErrors}    = 1;
    $self->{MP_UseInnerFiles}   = 0;



    ###
    ### Helper objects:
    ###

    ### Our expert on where to put files (same as $self->output_dir(".")):
    $self->{MP_Filer} = undef;  ### init below

    ### Re-parsers of encoded information (e.g., to find/extract uucode): 
    $self->{MP_Redoers} = [];



    ###
    ### Per-parse information:
    ###

    ### Results of the last parse:
    $self->{MP_Results} = undef;    

    ### Tasks yet to be done for this parse:
    $self->{MP_ToDo} = [];

    ### Reuseable temp file (only if TmpRecycling is true):
    $self->{MP_Tmp} = undef;



    ###
    ### Default setup:
    ###

    ### Our expert on where to put files (same as $self->output_dir(".")):
    $self->output_dir(".");


    $self;
}

#------------------------------

=item init_parse

I<Instance method.>
Invoked automatically whenever one of the top-level parse() methods
is called, to reset the parser to a "ready" state.

Note: this method will clear the list of "purgeable" files/directories
from the previous parse, so if you want to clean up as you go,
you'd better purge() immediately after each parse().

=cut

sub init_parse {
    my $self = shift;

    ### Clear the results:
    $self->{MP_Results} = new MIME::Parser::Results;

    ### Re-init the filer:
    $self->{MP_Filer}->purgeable([]);   ### too late now, kids!
    $self->{MP_Filer}->init_parse();

    ### Clear the TO-DO list:
    $self->{MP_ToDo} = [];
    1;
}

=back

=cut





#------------------------------------------------------------

=head2 Altering how messages are parsed

=over 4

=cut

#------------------------------
#
# =item decode_headers [YESNO]
#
# I<Instance method.>
# Controls whether the parser will attempt to decode all the MIME headers
# (as per RFC-1522) the moment it sees them.  B<This is not advisable
# for two very important reasons:>
#
# =over
#
# =item *
#
# B<It screws up the extraction of information from MIME fields.>
# If you fully decode the headers into bytes, you can inadvertently
# transform a parseable MIME header like this:
#
#     Content-type: text/plain; filename="=?ISO-8859-1?Q?Hi=22Ho?="
#
# into unparseable gobbledygook; in this case:
#
#     Content-type: text/plain; filename="Hi"Ho"
#
# =item *
#
# B<It is information-lossy.>  An encoded string which contains
# both Latin-1 and Cyrillic characters will be turned into a binary
# mishmosh which simply can't be rendered.
#
# =back
#
# B<History.>
# This method was once the only out-of-the-box way to deal with attachments
# whose filenames had non-ASCII characters.  However, since MIME-tools 5.4xx
# this is no longer necessary.
#
# B<Parameters.>
# If YESNO is true, decoding is done.  However, you will get a warning
# unless you use one of the special "true" values:
#
#    "I_NEED_TO_FIX_THIS"
#           Just shut up and do it.  Not recommended.
#           Provided only for those who need to keep old scripts functioning.
#
#    "I_KNOW_WHAT_I_AM_DOING"
#           Just shut up and do it.  Not recommended.
#           Provided for those who REALLY know what they are doing.
#
# If YESNO is false (the default), no attempt at decoding will be done.
# With no argument, just returns the current setting.
# B<Remember:> you can always decode the headers I<after> the parsing
# has completed (see L<MIME::Head::decode()|MIME::Head/decode>), or
# decode the words on demand (see L<MIME::Words>).
#
# =cut

sub decode_headers {
    my ($self, $yesno) = @_;
    if (@_ > 1) {
	$self->{MP_DecodeHeaders} = $yesno;
	if ($yesno) {
	    if (($yesno eq "I_KNOW_WHAT_I_AM_DOING") ||
		($yesno eq "I_NEED_TO_FIX_THIS")) {
		### ok
	    }
	    else {
		$self->logger->warning
		    ("as of 5.4xx, decode_headers() should NOT be ".
		     "set true... if you are doing this to make sure ".
		     "that non-ASCII filenames are translated, ".
		     "that's now done automatically; for all else, ".
		     "use MIME::Words.");
	    }
	}
    }
    $self->{MP_DecodeHeaders};
}


#------------------------------

=item extract_encoded_messages OPTION

I<Instance method.>
Some MIME messages will contain a part of type C<message/*>
or C<multipart/*> which has been erroneously encoded (the RFCs
state that the only valid Content-transfer-encodings for these
types are 7bit, 8bit, and binary).

If you set this option true (the default is false), then
the parser will B<re-parse> encoded bodies after decoding them.
For example:

    1. We encounter a base64-encoded multipart/mixed, so we...
       a. Decode the body as though it were an ordinary message part,
       b. Open a temporary handle on the decoded body,
       c. Parse the decoded body like an ordinary message,
    2. And finally, continue with the rest of the original message.

B<This is an expensive operation,> and you should really
only use it if you need the maximum amount of tolerance
or if you understand the risks:

=over 4

=item *

With this option set true, the same data may be
parsed multiple times.  For example, a base64-encoded
multipart may itself contain base64-encoded multiparts
which need to be reparsed, and so on, so the same patch
of data may be parsed and re-parsed many times.

=item *

The current implementation does a breadth-first parsing/decoding,
which means that arbitrarily-nested messages don't consume
arbitrary resources.

=back

=cut

sub extract_encoded_messages {
    my ($self, $option) = @_;
    $self->{MP_ExtractEncoded} = $option;
}

#------------------------------

=item extract_nested_messages OPTION

I<Instance method.>
Some MIME messages will contain a part of type C<message/rfc822>:
literally, the text of an embedded mail/news/whatever message.
This option controls whether (and how) we parse that embedded message.

If the OPTION is false, we treat such a message just as if it were a
C<text/plain> document, without attempting to decode its contents.

If the OPTION is true (the default), the body of the C<message/rfc822>
part is parsed by this parser, creating an entity object.
What happens then is determined by the actual OPTION:

=over 4

=item NEST or 1

The default setting.
The contained message becomes the sole "part" of the C<message/rfc822>
entity (as if the containing message were a special kind of
"multipart" message).
You can recover the sub-entity by invoking the L<parts()|MIME::Entity/parts>
method on the C<message/rfc822> entity.

=item REPLACE

The contained message replaces the C<message/rfc822> entity, as though
the C<message/rfc822> "container" never existed.

B<Warning:> notice that, with this option, all the header information
in the C<message/rfc822> header is lost.  This might seriously bother
you if you're dealing with a top-level message, and you've just lost
the sender's address and the subject line.  C<:-/>.

=back

I<Thanks to Andreas Koenig for suggesting this method.>

=cut

sub extract_nested_messages {
    my ($self, $option) = @_;
    $self->{MP_ExtractNested} = $option if (@_ > 1);
    $self->{MP_ExtractNested};
}

sub parse_nested_messages {
    usage_warning "parse_nested_messages() is now extract_nested_messages()";
    shift->extract_nested_messages(@_);
}

#------------------------------

=item extract_uuencode [YESNO]

I<Instance method, convenience.>
Setting this true is equivalent to:

    $self->redoer('extract_uuencode', new MIME::Parser::UURedoer);

If set true (which is the default as of 5.5x), then whenever we
are confronted with a message whose effective content-type is
"text/plain" and whose encoding is 7bit/8bit/binary, we scan the
encoded body to see if it contains uuencoded data (generally given
away by a "begin XXX" line).

If it does, we explode the uuencoded message into a multipart,
where the text before the first "begin XXX" becomes the first part,
and all "begin...end" sections following become the subsequent parts.
The filename (if given) is accessible through the normal means.

=cut

sub extract_uuencode {
    my ($self, $yesno) = @_;
    my $redoer = ($yesno ? new MIME::Parser::UURedoer : undef);
    $self->redoer('extract_uuencode', $redoer);
}

#------------------------------

=item ignore_errors [YESNO]

I<Instance method.>
Controls whether the parser will attempt to ignore normally-fatal
errors, treating them as warnings and continuing with the parse.

If YESNO is true (the default), many syntax errors are tolerated.
If YESNO is false, fatal errors throw exceptions.
With no argument, just returns the current setting.

=cut

sub ignore_errors {
    my ($self, $yesno) = @_;
    $self->{MP_IgnoreErrors} = $yesno if (@_ > 1);
    $self->{MP_IgnoreErrors};
}

#------------------------------

=item redoer NAME, REDOER

I<Instance method.>
Add/remove a "redoer". See L<MIME::Parser::Redoer>.
Also see L<extract_uuencode()|/extract_uuencode>.

A REDOER of undef removes it.
Redoers are triggered in the order they are added.

=cut

sub redoer {
    my ($self, $name, $redoer) = @_;

    ### Remove existing, if any:
    $self->{MP_Redoers} = [grep { $_->[0] ne $name } @{$self->{MP_Redoers}}];

    ### Add new to the end:
    push @{$self->{MP_Redoers}}, [$name, $redoer]  if $redoer;
}





#------------------------------
#
# PARSING...
#
#------------------------------

#------------------------------
#
# process_preamble PARAMHASH...
#
# I<Instance method.>
# Dispose of a multipart message's preamble.
# The PARAMHASH can contain:
#
#    In      => required: the input filehandle
#    Reader  => required: the MIME::Parser::Reader to use
#    Entity  => required: the entity to store the info in
#
sub process_preamble {
    my ($self, %p) = @_;
    $self->logger->debug("process_preamble");

    ### Get parameters:
    my $in  = $p{In}     || internal_error "missing param: In";
    my $rdr = $p{Reader} || internal_error "missing param: Reader";
    my $ent = $p{Entity} || internal_error "missing param: Entity";

    ### Sanity:
    ($rdr->depth > 0) or internal_error "non-positive depth";

    ### Parse preamble, and store in entity:
    my @saved;
    $rdr->read_lines($in, \@saved);
    $ent->preamble(\@saved);
    1;
}

#------------------------------
#
# process_epilogue PARAMHASH...
#
# I<Instance method.>
# Dispose of a multipart message's epilogue.
# The PARAMHASH can contain:
#
#    In      => required: the input filehandle
#    Reader  => required: the MIME::Parser::Reader to use
#    Entity  => required: the entity to store the info in
#
sub process_epilogue {
    my ($self, %p) = @_;
    $self->logger->debug("process_epilogue");

    ### Get parameters:
    my $in  = $p{In}     || internal_error "missing param: In";
    my $rdr = $p{Reader} || internal_error "missing param: Reader";
    my $ent = $p{Entity} || internal_error "missing param: Entity";

    ### Parse epilogue, and store in entity:
    my @saved;
    $rdr->read_lines($in, \@saved);
    $ent->epilogue(\@saved);
    1;
}

#------------------------------
#
# process_to_bound PARAMHASH...
#
# I<Instance method.>
# Dispose of the next chunk into the given output stream OUT.
# The PARAMHASH can contain:
#
#    In      => required: the input filehandle
#    Out     => required: the output filehandle
#    Reader  => required: the MIME::Parser::Reader to use
#
sub process_to_bound {
    my ($self, %p) = @_;
    $self->logger->debug("process_to_bound");

    ### Get parameters:
    my $in  = $p{In}     || internal_error "missing param: In";
    my $out = $p{Out}    || internal_error "missing param: Out";
    my $rdr = $p{Reader} || internal_error "missing param: Reader";

    ### Parse:
    my $bm = benchmark {
	$rdr->read_chunk($in, $out);
    };
    $self->logger->debug("benchmark: process_to_bound: $bm") if $bm;
    1;
}

#------------------------------
# 
# quote_header \@HEADERLINES
#
# Class method.  
# Summarize the given header.
#
sub quote_header {
    my ($class, $lines) = @_;
    "\n".join('', map { "\t$_" } @$lines)."\n";
}

#------------------------------
#
# process_header PARAMHASH...
#
# I<Instance method.>
# Process and return the next header.
# The PARAMHASH can contain:
#
#    In      => required: the input filehandle
#    Reader  => required: the MIME::Parser::Reader to use
#    NoBody  => optional: ref to scalar; set true if truncation was detected
#
sub process_header {
    my ($self, %p) = @_;
    $self->logger->debug("process_header");

    ### Get parameters:
    my $in  = $p{In}     || internal_error "missing param: In";
    my $rdr = $p{Reader} || internal_error "missing param: Reader";
    my $no_body = $p{NoBody};

    ### Parse and save the (possibly empty) header, up to andq including the
    ###    blank line that terminates it:
    my $head = $self->new_head;

    ### Read the lines of the header.
    my @headlines;
    my $hdr_rdr = $rdr->spawn;
    $hdr_rdr->add_terminator("");
    $hdr_rdr->add_terminator("\r");           ### sigh
    $hdr_rdr->read_lines($in, \@headlines);
    foreach (@headlines) { s/[\r\n]+\Z/\n/ }  ### fold

    ### Did we end properly?
    my $hdr_eos_type = $hdr_rdr->eos_type;
    if ($hdr_eos_type ne 'DONE') {

	### Note:
	###    An unexpected end of header can happen inside multiparts when
	###    the boundary is doubled; i.e., the boundary appears on two 
	###    consecutive lines.  
	$$no_body = 1 if $no_body;
	$self->fail(Error => "unexpected end of header",
		    Class => 'SeveredHead',
		    Header => $self->quote_header(\@headlines),
		    EOSToken => $hdr_rdr->eos,
		    EOSType  => $hdr_rdr->eos_type);
    }

    ### Cleanup bogus header lines.
    ###    Some folks like to parse mailboxes, so the header will start
    ###    with "From " or ">From ".  Tolerate this by removing both kinds
    ###    of lines silently (can't we use Mail::Header for this, and try
    ###    and keep the envelope?).  Ditto for POP.
    while (@headlines) {
	if    ($headlines[0] =~ /^>?From /) {    ### mailbox
	    $self->logger->warning("skipping bogus mailbox 'From ' line");
	    shift @headlines;
	}
	elsif ($headlines[0] =~ /^\+OK/) {       ### POP3 status line
	    $self->logger->warning("skipping bogus POP3 '+OK' line");
	    shift @headlines;
	}
	else { last }
    }

    ### Extract the header (note that zero-size headers are admissible!):
    $head->extract(\@headlines);
    if (@headlines) {
	$self->fail(Error => "couldn't parse header",
		    Class => 'BadHead',
		    ProblemNear => $self->quote_header(\@headlines));
    }

    ### If desired, auto-decode the header as per RFC-1522.
    ###    This shouldn't affect non-encoded headers; however, it will decode
    ###    headers with international characters.  WARNING: currently, the
    ###    character-set information is LOST after decoding.
    $head->decode($self->{MP_DecodeHeaders}) if $self->{MP_DecodeHeaders};

    ### If this is the top-level head, save it:
    $self->results->top_head($head) if !$self->results->top_head;

    return $head;
}

#------------------------------
#
# process_multipart PARAMHASH...
#
# I<Instance method.>
# Process the multipart body.
# The PARAMHASH can contain:
#
#    In      => required: the input filehandle
#    Reader  => required: the MIME::Parser::Reader to use
#    Entity  => required: the entity to store the info in
#
# This method assumes that the IN data is non-encoded,
# regardless of the content-transfer-encoding.  This is
# to support graceful re-parsing.
#
# Returns the state.
#
sub process_multipart {
    my ($self, %p) = @_;
    $self->logger->debug("process_multipart");

    ### Get parameters:
    my $in  = $p{In}     || internal_error "missing param: In";
    my $rdr = $p{Reader} || internal_error "missing param: Reader";
    my $ent = $p{Entity} || internal_error "missing param: Entity";
    my $head = $ent->head;


    ### Get actual type and subtype from the header:
    my ($type, $subtype) = (split('/', $head->mime_type), "");

    ### Set the default type for subparts.
    ###    If this was a type "multipart/digest", then the RFCs say we
    ###    should default the parts to have type "message/rfc822".
    ###    Thanks to Carsten Heyl for suggesting this.
    my $retype = (($subtype eq 'digest') ? 'message/rfc822' : '');

    ### Get the boundaries for the parts:
    my $bound = $head->multipart_boundary;
    if (!defined($bound) || ($bound =~ /[\r\n]/)) {
	$self->fail(Error => ("multipart boundary is missing, or else it ".
			      "contains carriage-return and/or linefeed"),
		    Class => 'BadBound',
		    Boundary => $bound);
	$ent->effective_type($self->{MP_EffectiveTypeForBadBound});
	return $self->process_singlepart(In=>$in, Reader=>$rdr, Entity=>$ent);
    }
    my $part_rdr = $rdr->spawn->add_boundary($bound);

    ### Prepare to parse:
    my $eos_type;
    my $more_parts;

    ### Parse preamble...
    $self->process_preamble(In     => $in, 
			    Reader => $part_rdr,
			    Entity => $ent);

    ### ...and look at how we finished up:
    $eos_type = $part_rdr->eos_type;
    if    ($eos_type eq $EOS_DELIM) {
	$more_parts = 1;
    }
    elsif ($eos_type eq $EOS_CLOSE) {
	$self->logger->warning("empty multipart message\n");
	$more_parts = 0; }
    else  {
	$self->fail(Error => ("unexpected end of preamble".
			      " [in multipart message]"),
		    Class => 'SeveredPreamble',
		    EOSToken => $part_rdr->eos,
		    EOSType  => $part_rdr->eos_type);
	return 1;
    }

    ### Parse parts:
    my $partno = 0;
    my $part;
    while ($more_parts) {
	++$partno;
	$self->logger->debug("parsing part $partno...");

	### Parse the next part, and add it to the entity...
	my $part = $self->process_part(In      => $in,
				       Reader  => $part_rdr,
				       Retype  => $retype,
				       PartNum => $partno);
	$ent->add_part($part);

	### ...and look at how we finished up:
	$eos_type = $part_rdr->eos_type;
	if    ($eos_type eq $EOS_DELIM) {
	    $more_parts = 1;
	}
	elsif ($eos_type eq $EOS_CLOSE) {
	    $more_parts = 0;
	}
	else {
	    $self->fail(Error => ("unexpected end of parts before epilogue".
				  " [in multipart message]"),
			Class => 'SeveredParts',
			VirtualEOF => $part_rdr->eos);
	    return 1;
	}
    }

    ### Parse epilogue...
    ###    (note that we use the *parent's* reader here, which does not
    ###     know about the boundaries in this multipart!)
    $self->process_epilogue(In     => $in,
			    Reader => $rdr,
			    Entity => $ent);

    ### ...and there's no need to look at how we finished up!
    1;
}

#------------------------------
#
# process_singlepart PARAMHASH...
#
# I<Instance method.>
# Process the singlepart body.  
# The PARAMHASH can contain:
#
#    In      => required: the input filehandle
#    Reader  => required: the MIME::Parser::Reader to use
#    Entity  => required: the entity to store the info in
#
# Returns true.
#
sub process_singlepart {
    my ($self, %p) = @_;
    $self->logger->debug("process_singlepart");

    ### Get parameters:
    my $in  = $p{In}     || internal_error "missing param: In";
    my $rdr = $p{Reader} || internal_error "missing param: Reader";
    my $ent = $p{Entity} || internal_error "missing param: Entity";
    my $head = $ent->head;

    ### Obtain a filehandle for reading the encoded information:
    ###    We have two different approaches, based on whether or not we
    ###    have to contend with boundaries.
    my $ENCODED;             ### handle
    my $can_shortcut = !$rdr->has_bounds;
    if ($can_shortcut) {
	$self->logger->debug("taking shortcut");

	$ENCODED = $in;
	$rdr->eos('EOF');   ### be sure to bogus-up the reader state to EOF:
    }
    else {

	### Can we read real fast?
	if ($self->{MP_UseInnerFiles} &&
	    $in->can('seek') && $in->can('tell')) {
	    $self->logger->debug("using inner file");
	    $ENCODED = MIME::Parser::InnerFile->new($in, $in->tell, 0);
	}
	else {
	    $self->logger->debug("using temp file");
	    $ENCODED = $self->new_tmpfile($self->{MP_Tmp});
	    $self->{MP_Tmp} = $ENCODED if $self->tmp_recycling;
	}

	### Read encoded body until boundary (or EOF)...
	$self->process_to_bound(In=>$in, Reader=>$rdr, Out=>$ENCODED);

	### ...and look at how we finished up.
	###     If we have bounds, we want DELIM or CLOSE.
	###     Otherwise, we want EOF (and that's all we'd get, anyway!).
	if ($rdr->has_bounds) {
	    my $eos_type = $rdr->eos_type;
	    if (($eos_type ne $EOS_DELIM) and ($eos_type ne $EOS_CLOSE)) {

		$self->fail(Error => ("part didn't end with expected boundary".
				      " [in multipart message]"),
			    Class => 'UnexpectedBound',
			    EOSToken => $rdr->eos,
			    EOSType  => $rdr->eos_type);
	    }
	}

	### Flush and rewind encoded buffer, so we can read it:
	$ENCODED->flush;
	$ENCODED->seek(0, 0);
    }

    ### Get a content-decoder to decode this part's encoding:
    my $encoding = $head->mime_encoding;
    my $decoder = new MIME::Decoder $encoding;
    if (!$decoder) {
	$self->logger->warning
	    ("Unsupported encoding '$encoding': using 'binary'... \n".
	     "The entity will have an effective MIME type of \n".
	     "application/octet-stream.");  ### as per RFC-2045
	$ent->effective_type('application/octet-stream');
	$decoder = new MIME::Decoder 'binary';
    }

    ### Open a new bodyhandle for outputting the data.
    ###    If this fails, we MUST throw an exception: there's no sensible
    ###    way to continue.
    my $body = $self->new_body_for($head) || 
	die "unable to create body for head\n"; 
    $body->binmode(1);  ### unless textual_type($ent->effective_type);

    ### Decode and save the body (using the decoder):
    my $DECODED = $body->open("w") || die "body not opened: $!\n";
    eval {
	$decoder->decode($ENCODED, $DECODED); 
    }; $@ and $self->fail(Class => 'DecoderFailed',
			  Error => $@);
    $DECODED->close;

    ### Success!  Remember where we put stuff:
    $ent->bodyhandle($body);


    ### The decoded singlepart may actually contain embedded containers
    ### of a non-standard format; e.g., a text/plain which actually
    ### contains uuencoded data.  Create/enqueue a task to deal with it.
    ###
    ### Be aware that this task can gut and replace the core of the
    ### given entity (since entities reference other entities, this is
    ### the simplest approach).
    ###
    ### Lexical variables frozen into the closure:
    ###
    ###    $ent      the entity this method was given
    ###    $body     its bodyhandle (for convenience)
    ###
    $self->enqueue_task("redo singlepart", sub {
	my $_self = shift;

 	### For each installed redoer...
 	foreach my $r (@{$_self->{MP_Redoers}}) {
 	    my ($name, $redoer) = @$r;
 	    $_self->logger->debug("trying redoer: $name");
 
 	    ### Try out this redoer, catching exceptions:
 	    #$_self->logger->push_prefix($name);
 	    my $new = eval { $redoer->redo($body->open("r"), $ent, $_self); };
 	    #$_self->logger->pop_prefix;

	    ### If we caught an exception, just log it and move on:
 	    if ($@) {         ### failed hard
		$_self->fail(Class => 'RedoerFailed',
			     Error => "redoer '$name' failed: $@");
 		next;
 	    }
 	    elsif ($new) {    ### it worked!
 		$_self->logger->debug("matched redoer: $name");
 		%$ent = %$new;
 		last;
 	    }
 	}
    });

    ### Done!
    1;
}

#------------------------------
#
# process_message PARAMHASH...
#
# I<Instance method.>
# Process the singlepart body.
#
#    In      => required: the input filehandle
#    Reader  => required: the MIME::Parser::Reader to use
#    Entity  => required: the entity to store the info in
#
#
# This method assumes that the IN data is non-encoded,
# regardless of the content-transfer-encoding.  This is
# to support graceful re-parsing.
#
# Returns true.
#
sub process_message {
    my ($self, %p) = @_;
    $self->logger->debug("process_message");

    ### Get parameters:
    my $in  = $p{In}     || internal_error "missing param: In";
    my $rdr = $p{Reader} || internal_error "missing param: Reader";
    my $ent = $p{Entity} || internal_error "missing param: Entity";
    my $head = $ent->head;

    ### Parse the message:
    my $msg = $self->process_part(In=>$in, Reader=>$rdr);

    ### How to handle nested messages?
    if ($self->extract_nested_messages eq $EXTRACT_REPLACE) {
	%$ent = %$msg;          ### "REPLACE" does shallow replace
	%$msg = ();
    }
    else {                      ### "NEST" or generic 1:
	$ent->bodyhandle(undef);
	$ent->add_part($msg);
    }
    1;
}

#------------------------------
#
# process_part PARAMHASH...
#
# I<Instance method.>
# The real back-end engine.
# See the documentation up top for an overview of the algorithm.
# The PARAMHASH can contain:
#
#    In      => required: the input filehandle
#    Reader  => optional: the MIME::Parser::Reader to use
#    Retype  => optional: retype this part to the given content-type
#    PartNum => optional: 1-based number of this part
#
# Return the entity.
# Fatal exception on failure.
#
sub process_part {
    my ($self, %p) = @_;
    $self->logger->debug("process_part");

    ### Get parameters:
    my $in      = $p{In}     || internal_error "missing param: In";
    my $rdr     = $p{Reader} || MIME::Parser::Reader->new;
    my $retype  = $p{Retype};
    my $partnum = $p{PartNum} || 1;

    ### Start logging:
    #$self->logger->push_prefix("part $partnum");

    ### Create a new entity:
    my $ent = $self->new_entity;

    ### Parse and add the header:
    my $no_body; 
    my $head = $self->process_header(In     => $in, 
				     Reader => $rdr,
				     NoBody => \$no_body);
    $ent->head($head);

    ### Tweak the content-type based on context from our parent...
    ### For example, multipart/digest messages default to type message/rfc822:
    $head->mime_type($retype) if $retype;

    ### The header may have been terminated unexpectedly by a 
    ### multipart boundary, in which case, it has no body. 
    if ($no_body) {
	$self->logger->warning("unexpected end of header; assuming no body");
	$ent->bodyhandle(new MIME::Body::InCore);
	return $ent;
    }

    ### Unencoded bodies may be processed according to MIME type;
    ### Encoded bodies must first be processed as singleparts:
    my $classify = $self->classify_body($head);
    if ($head->mime_encoding =~ /^(7bit|8bit|binary)$/) {

	### Classify... how should we parse it?
	if    ($classify eq $CLASS_MULTIPART) {
	    $self->process_multipart(  In=>$in, Reader=>$rdr, Entity=>$ent);
	}
	elsif ($classify eq $CLASS_MESSAGE) {
	    $self->process_message(    In=>$in, Reader=>$rdr, Entity=>$ent);
	}
	elsif ($classify eq $CLASS_SINGLEPART) {
	    $self->process_singlepart( In=>$in, Reader=>$rdr, Entity=>$ent);
	}
	else {
	    internal_error "unknown classification '$classify'";
	}
    }
    else {                         ### encoded body:

	### First, decode:
	$self->process_singlepart(In=>$in, Reader=>$rdr, Entity=>$ent);

	### Should we (and can we) re-parse this encoded part?
	if (($classify ne $CLASS_SINGLEPART) and $self->{MP_ExtractEncoded}) {

	    ### Create and enqueue a task for re-parsing it.
	    ###
	    ### Lexical variables frozen into the closure:
	    ###
	    ###    $ent       the entity this method was given
	    ###    $classify  the classificaitons
	    ###
	    $self->enqueue_task("reparse encoded container", sub {
		my $_self = shift;
 
 		### Set up input, etc.
 		my $re_in = $ent->bodyhandle->open('r');
 		my $re_rdr = MIME::Parser::Reader->new;
 
 		### Handle by classification:
 		if    ($classify eq $CLASS_MULTIPART) {
 		    $_self->process_multipart(In     => $re_in, 
					      Reader => $re_rdr, 
					      Entity => $ent);
 		}
 		elsif ($classify eq $CLASS_MESSAGE) {
 		    $_self->process_message(  In     => $re_in, 
					      Reader => $re_rdr,
					      Entity => $ent);
 		}
 		else {
 		    internal_error "bad classification '$classify'";
 		}
 
 		### Cleanup:
 		$re_in->close;
 	    });
 	}
    }

    ### Done (we hope!):
    #$self->logger->pop_prefix();
    return $ent;
}

#------------------------------
#
# classify_body HEAD
#
# Instance method, private.
# Classify the [unencoded] contents of a message as one of these:
#
#    "multipart"   the unencoded body is a MIME multipart body
#    "message"     the unencoded body is a re-parseable "message/*" document
#    "singlepart"  the unencoded body is anything else (e.g., "text/html")
#
# Notice that we only classify as "message" if we are allowed to
# extract nested messages; otherwise, it's just a [flat] singlepart.
#
sub classify_body {
    my ($self, $head) = @_;

    ### Get the MIME type and subtype:
    my ($type, $subtype) = (split('/', $head->mime_type), '');
    my $fulltype = "$type/$subtype";
    $self->logger->debug("classify_body: type = $type, subtype = $subtype");

    ### Handle, according to the MIME type:
    if ($type eq 'multipart') {
	return $CLASS_MULTIPART;
    }
    elsif ($self->extract_nested_messages) {
	return ($self->{MP_ClassifyAsMessage}{$fulltype}
		? $CLASS_MESSAGE 
		: $CLASS_SINGLEPART);
    }
    else {
	return $CLASS_SINGLEPART;
    }
}

#------------------------------
#
# enqueue_task NAME, SUBREF
#
# Enqueue a task to perform.
# The task should not include the $self in the closure: instead, 
# it shoudl receive it as 0th argument (like a method): this is prevent
# memory leaks.  For example:
#
#     $self->enqueue_task("say hello", sub {
#         my $_self = shift;
#         print "Hello world!\n";
#     });
#
sub enqueue_task {
    my ($self, $name, $subref) = @_;
    $self->logger->debug("ENQUEUE TASK: $name");
    push @{$self->{MP_ToDo}}, [$name, $subref];
}

#------------------------------
#
# dequeue_task
#
# Dequeue and perform the next task;
# Returns true if there were tasks, false if no tasks remain.
#
sub dequeue_task {
    my ($self) = @_;
    my ($name, $subref) = @{ shift(@{$self->{MP_ToDo}}) || [] };
    $subref or return undef;
    $self->logger->debug("RUN TASK: $name");
    #$self->logger->push_prefix($name);
    &$subref($self);
    #$self->logger->pop_prefix;
    1;
}



=back

=head2 Parsing an input source

=over 4

=cut

#------------------------------

=item parse_data DATA

I<Instance method.>
Parse a MIME message that's already in core.
You may supply the DATA in any of a number of ways...

=over 4

=item *

B<A scalar> which holds the message.

=item *

B<A ref to a scalar> which holds the message.  This is an efficiency hack.

=item *

B<A ref to an array of scalars.>  They are treated as a stream
which (conceptually) consists of simply concatenating the scalars.

=back

Returns the parsed MIME::Entity on success.
Throws exception on failure.

=cut

sub parse_data {
    my ($self, $data) = @_;

    ### Get data as a scalar:
    my $io;
  switch: while(1) {
      (!ref($data)) and do {
	  $io = new IO::Scalar \$data; last switch;
      };
      (ref($data) eq 'SCALAR') and do {
	  $io = new IO::Scalar $data; last switch;
      };
      (ref($data) eq 'ARRAY') and do {
	  $io = new IO::ScalarArray $data; last switch;
      };
      croak "parse_data: wrong argument ref type: ", ref($data);
  }

    ### Parse!
    return $self->parse($io);
}

#------------------------------

=item parse INSTREAM

I<Instance method.>
Takes a MIME-stream and splits it into its component entities.

The INSTREAM can be given as a readable FileHandle, an IO::File,
a globref filehandle (like C<\*STDIN>),
or as I<any> blessed object conforming to the IO:: interface
(which minimally implements getline() and read()).

Returns the parsed MIME::Entity on success.
Throws exception on failure.

=cut

sub parse {
    my $self = shift;
    my $in = wraphandle(shift);    ### coerce old-style filehandles to objects
    my $entity;
    local $/ = "\n";    ### just to be safe

    ### Init:
    $self->init_parse;

    ### Set up logging:
    local $MIME::Tools::LOG = $self->{MP_Results};
	

    ### Create initial task:
    ###
    ### Lexical variables frozen into the closure:
    ###
    ###    $in       the input handle
    ###    $entity   the lvalue where the entity should be placed
    ###
    $self->enqueue_task("initial processing", sub {
	my $_self = shift;

	($entity) = $_self->process_part(In=>$in, PartNum=>1);
    });

    ### Dispatch tasks until done:
    1 while ($self->dequeue_task);
    $entity;
}

### Backcompat:
sub read {
    shift->parse(@_);
}
sub parse_FH {
    shift->parse(@_);
}

#------------------------------

=item parse_open EXPR

I<Instance method.>
Convenience front-end onto C<parse()>.
Simply give this method any expression that may be sent as the second
argument to open() to open a filehandle for reading.

Returns the parsed MIME::Entity on success.
Throws exception on failure.

=cut

sub parse_open {
    my ($self, $expr) = @_;
    my $ent;

    my $io = IO::File->new($expr) or die "couldn't open $expr: $!\n";
    $ent = $self->parse($io);
    $io->close;
    $ent;
}

### Backcompat:
sub parse_in {
    usage_warning "parse_in() is now parse_open()";
    shift->parse_open(@_);
}

#------------------------------

=item parse_two HEADFILE, BODYFILE

I<Instance method.>
Convenience front-end onto C<parse_open()>, intended for programs
running under mail-handlers like B<deliver>, which splits the incoming
mail message into a header file and a body file.
Simply give this method the paths to the respective files.

B<Warning:> it is assumed that, once the files are cat'ed together,
there will be a blank line separating the head part and the body part.

B<Warning:> new implementation slurps files into line array
for portability, instead of using 'cat'.  May be an issue if
your messages are large.

Returns the parsed MIME::Entity on success.
Throws exception on failure.

=cut

sub parse_two {
    my ($self, $headfile, $bodyfile) = @_;
    my @lines;
    foreach my $file ($headfile, $bodyfile) {
	open IN, "<$file" or die "open $file: $!";
	push @lines, <IN>;
	close IN;
    }
    return $self->parse_data(\@lines);
}

=back

=cut




#------------------------------------------------------------

=head2 Specifying output destination

B<Warning:> in 5.212 and before, this was done by methods
of MIME::Parser.  However, since many users have requested
fine-tuned control over how this is done, the logic has been split
off from the parser into its own class, MIME::Parser::Filer
Every MIME::Parser maintains an instance of a MIME::Parser::Filer
subclass to manage disk output (see L<MIME::Parser::Filer> for details.)

The benefit to this is that the MIME::Parser code won't be
confounded with a lot of garbage related to disk output.
The drawback is that the way you override the default behavior
will change.

For now, all the normal public-interface methods are still provided,
but many are only stubs which create or delegate to the underlying
MIME::Parser::Filer object.

=over 4

=cut

#------------------------------

=item filer [FILER]

I<Instance method.>
Get/set the FILER object used to manage the output of files to disk.
This will be some subclass of L<MIME::Parser::Filer|MIME::Parser::Filer>.

=cut

sub filer {
    my ($self, $filer) = @_;
    if (@_ > 1) {
	$self->{MP_Filer} = $filer;   ### will set logger in init_parse()
    }
    $self->{MP_Filer};
}

#------------------------------

=item output_dir DIRECTORY...

I<Instance method.>
Causes messages to be filed directly into the given DIRECTORY.
It does this by setting the underlying L<filer()|/filer> to
a new instance of MIME::Parser::FlatFiler, and passing the arguments
into that class' new() method.

B<Note:> Since this method replaces the underlying
filer, you must invoke it I<before> doing changing any attributes
of the filer, like the output prefix; otherwise those changes
will be lost.

=cut

sub output_dir {
    my ($self, @init) = @_;
    (@_ > 1) or croak "missing arguments";
    $self->filer(MIME::Parser::FlatFiler->new(@init));
}

#------------------------------

=item output_under BASEDIR...

I<Instance method.>
Causes messages to be filed directly into subdirectories of the given
BASEDIR, one subdirectory per message.  It does this by setting the
underlying L<filer()|/filer> to a new instance of MIME::Parser::TreeFiler,
and passing the arguments into that class' new() method.

B<Note:> Since this method replaces the underlying
filer, you must invoke it I<before> doing changing any attributes
of the filer, like the output prefix; otherwise those changes
will be lost.

=cut

sub output_under {
    my ($self, @init) = @_;
    (@_ > 1) or croak "missing arguments";
    $self->filer(MIME::Parser::TreeFiler->new(@init));
}

#------------------------------

=item output_to_core YESNO

I<Instance method.>
Normally, instances of this class output all their decoded body
data to disk files (via MIME::Body::File).  However, you can change
this behaviour by invoking this method before parsing:

If YESNO is false (the default), then all body data goes
to disk files.

If YESNO is true, then all body data goes to in-core data structures
This is a little risky (what if someone emails you an MPEG or a tar
file, hmmm?) but people seem to want this bit of noose-shaped rope,
so I'm providing it.
Note that setting this attribute true I<does not> mean that parser-internal
temporary files are avoided!  Use L<tmp_to_core()|/tmp_to_core> for that.

With no argument, returns the current setting as a boolean.

=cut

sub output_to_core {
    my ($self, $yesno) = @_;
    if (@_ > 1) {
	$yesno = 0 if ($yesno and $yesno eq 'NONE');
	$self->{MP_FilerToCore} = $yesno;
    }
    $self->{MP_FilerToCore};
}

#------------------------------

=item tmp_recycling [YESNO]

I<Instance method.>
Normally, tmpfiles are created when needed during parsing, and
destroyed automatically when they go out of scope.  But for efficiency,
you might prefer for your parser to attempt to rewind and reuse the
same file until the parser itself is destroyed.

If YESNO is true (the default), we allow recycling;
tmpfiles persist until the parser itself is destroyed.
If YESNO is false, we do not allow recycling;
tmpfiles persist only as long as they are needed during the parse.
With no argument, just returns the current setting.

=cut

sub tmp_recycling {
    my ($self, $yesno) = @_;
    $self->{MP_TmpRecycling} = $yesno if (@_ > 1);
    $self->{MP_TmpRecycling};
}

#------------------------------

=item tmp_to_core [YESNO]

I<Instance method.>
Should L<new_tmpfile()|/new_tmpfile> create real temp files, or
use fake in-core ones?  Normally we allow the creation of temporary
disk files, since this allows us to handle huge attachments even when
core is limited.

If YESNO is true, we implement new_tmpfile() via in-core handles.
If YESNO is false (the default), we use real tmpfiles.
With no argument, just returns the current setting.

=cut

sub tmp_to_core {
    my ($self, $yesno) = @_;
    $self->{MP_TmpToCore} = $yesno if (@_ > 1);
    $self->{MP_TmpToCore};
}

#------------------------------

=item use_inner_files [YESNO]

I<Instance method.>
If you are parsing from a handle which supports seek() and tell(),
then we can avoid tmpfiles completely by using IO::InnerFile, if so
desired: basically, we simulate a temporary file via pointers
to virtual start- and end-positions in the input stream.

If YESNO is false (the default), then we will not use IO::InnerFile.
If YESNO is true, we use IO::InnerFile if we can.
With no argument, just returns the current setting.

B<Note:> inner files are slower than I<real> tmpfiles,
but possibly faster than I<in-core> tmpfiles... so your choice for
this option will probably depend on your choice for
L<tmp_to_core()|/tmp_to_core> and the kind of input streams you are
parsing.

=cut

sub use_inner_files {
    my ($self, $yesno) = @_;
    $self->{MP_UseInnerFiles} = $yesno if (@_ > 1);
    $self->{MP_UseInnerFiles};
}

=back

=cut


#------------------------------------------------------------

=head2 Factory methods

=over 4

=cut

#------------------------------
# 
# =item interface ROLE,[VALUE]
# 
# I<Instance method, deprecated.>
# During parsing, the parser normally creates instances of certain classes,
# like MIME::Entity.  However, you may want to create a parser subclass
# that uses your own experimental head, entity, etc. classes (for example,
# your "head" class may provide some additional MIME-field-oriented methods).
#
sub interface {
    my ($self, $role, $value) = @_;
    usage_warning ("interface() is deprecated: ",
		   "override new_head() or new_entity() in a subclass");
    $value or usage_error "interface(ROLE) is no longer supported";

    if    ($role eq 'HEAD_CLASS') {
	$self->{MP_DefaultFactoryClass}{Head} = $value;
    }
    elsif ($role eq 'ENTITY_CLASS') {
	$self->{MP_DefaultFactoryClass}{Entity} = $value;
    }
    else {
	usage_error "interface(): unknown role: $role";
    }
}

#------------------------------

=item new_body_for HEAD

I<Instance method, factory.>
Based on the HEAD of a part we are parsing, return a new
body object (any desirable subclass of MIME::Body) for
receiving that part's data.

If you set the C<output_to_core> option to false before parsing
(the default), then we call our filer's C<output_path()>
and create a new MIME::Body::File on that filename.

If you set the C<output_to_core> option to true before parsing,
then you get a MIME::Body::InCore instead.

If you want the parser to do something else entirely, you can
override this method in a subclass.

=cut

sub new_body_for {
    my ($self, $head) = @_;

    if ($self->output_to_core) {
	$self->logger->debug("outputting body to core");
	return (new MIME::Body::InCore);
    }
    else {
	my $outpath = $self->filer->output_path($head);
	$self->logger->debug("outputting body to disk file: $outpath");
	$self->filer->purgeable($outpath);        ### we plan to use it
	return (new MIME::Body::File $outpath);
    }
}

#------------------------------

=item new_entity

I<Instance method, factory.>
Return a new MIME::Entity subclass to hold an entity we will parse.
The default returns a new MIME::Entity.

=cut

sub new_entity {
    my $self = shift;
    return $self->{MP_DefaultFactoryClass}{Entity}->new;
}

#------------------------------

=item new_head

I<Instance method, factory.>
Return a new MIME::Head subclass to hold a header we will parse.
The default returns a new MIME::Head.

=cut

sub new_head {
    my $self = shift;
    return $self->{MP_DefaultFactoryClass}{Head}->new;
}

#------------------------------

=item new_tmpfile [RECYCLE]

I<Instance method, factory.>
Return an IO handle to be used to hold temporary data during a parse.
The default uses the standard IO::File->new_tmpfile() method unless
L<tmp_to_core()|/tmp_to_core> dictates otherwise, but you can override this.
You shouldn't need to.

If you do override this, make certain that the object you return is
set for binmode(), and is able to handle the following methods:

    read(BUF, NBYTES)
    getline()
    getlines()
    print(@ARGS)
    flush()
    seek(0, 0)

Fatal exception if the stream could not be established.

If RECYCLE is given, it is an object returned by a previous invocation
of this method; to recycle it, this method must effectively rewind and
truncate it, and return the same object.  If you don't want to support
recycling, just ignore it and always return a new object.

=cut

sub new_tmpfile {
    my ($self, $recycle) = @_;

    my $io;
    if ($self->tmp_to_core) {            ### Use an in-core tmpfile (slow)
	$io = IO::ScalarArray->new;
    }
    else {                               ### Use a real tmpfile (fast)
	                                       ### Recycle?
	if ($self->tmp_recycling &&                  ### we're recycling
	    $recycle &&                              ### something to recycle
	    $Config{'truncate'} && $io->can('seek')  ### recycling will work
	    ){
	    $self->logger->debug("recycling tmpfile: $io");
	    $io->seek(0, 0);
	    truncate($io, 0);
	}
	else {                                 ### Return a new one:
	    $io = tmpopen() || die "can't open tmpfile: $!\n";
	    binmode($io);
	}
    }
    return $io;
}

=back

=cut




#------------------------------------------------------------

=head2 Parser results 

=over 4

=cut

#------------------------------
#
# fail PARAMHASH...
#
# I<Instance method.>
# Possibly-forgivable parse error occurred.  Log it.  
# If we are ignoring errors, return undef; if not, throw an exception.
#
# Params are:
#
#     Error => Human-readable error message; it should NOT end in a newline
#     Class => Simple token for this error
#     ...   => Other useful information
#
# A possible use would be to take different actions based on the Class.
#
sub fail {
    my $self = shift;
    my %p = @_;
    my $class = delete $p{Class} || "Unknown",
    my $error = delete $p{Error} || "unknown error";
    my $etc = join "", map { "\n\t$_: $p{$_}"  } sort keys %p;

    $self->logger->error("$class: $error$etc");
    $self->{MP_IgnoreErrors} ? return undef : die "$class: $error$etc\n";
}

#------------------------------
#
# last_error
#
# I<Instance method, deprecated.>
# Return the errors (if any) that we ignored in the last parse.
#
sub last_error {
    usage_warning "deprecated: use \$parser->results->errors";
    join '', shift->results->errors;
}

#------------------------------
#
# last_head
#
# I<Instance method, deprecated.>
# Return the top-level MIME header of the last stream we attempted to parse.
# This is useful for replying to people who sent us bad MIME messages,
# since we at least have the header.
#
sub last_head {
    usage_warning "deprecated: use \$parser->results->top_head\n";
    shift->results->top_head;
}

#------------------------------
#
# logger
#
# I<Instance method, for subclasses.>
# Return our current logger, a subclass of MIME::Tools::Logger.
#
sub logger {
    return $MIME::Tools::LOG;
}

#------------------------------

=item results

I<Instance method.>
Return an object containing lots of info from the last entity parsed.
This will be an instance of class
L<MIME::Parser::Results|MIME::Parser::Results>.

=cut

sub results {
    shift->{MP_Results};
}


=back

=cut



### Support old helper class names via empty subclasses:

#============================================================
package MIME::Parser::FileInto;
use base 'MIME::Parser::FlatFiler';
1;
#============================================================
package MIME::Parser::FileUnder;
use base 'MIME::Parser::TreeFiler';
1;
#============================================================
package MIME::Parser::RedoUU;
use base 'MIME::Parser::UURedoer';
1;
#============================================================
package MIME::Parser;
1;

__END__


=head1 OPTIMIZING YOUR PARSER


=head2 Maximizing speed

Optimum input mechanisms:

    parse()                    YES (if you give it a globref or a
				    subclass of IO::File)
    parse_open()               YES
    parse_data()               NO  (see below)
    parse_two()                NO  (see below)

Optimum settings:

    extract_nested_messages()  0   (may be slightly faster, but in
                                    general you want it set to 1)
    output_to_core()           0   (will be MUCH faster)
    tmp_recycling()            1?  (probably, but should be investigated)
    tmp_to_core()              0   (will be MUCH faster)
    use_inner_files()          0   (if tmp_to_core() is 0;
				    use 1 otherwise)

B<File I/O is much faster than in-core I/O.>
Although it I<seems> like slurping a message into core and
processing it in-core should be faster... it isn't.
Reason: Perl's filehandle-based I/O translates directly into
native operating-system calls, whereas the in-core I/O is
implemented in Perl.

B<Inner files are slower than real tmpfiles, but faster than in-core ones.>
If speed is your concern, that's why
you should set use_inner_files(true) if you set tmp_to_core(true):
so that we can bypass the slow in-core tmpfiles if the input stream
permits.

B<Native I/O is much faster than object-oriented I/O.>
It's much faster to use E<lt>$fooE<gt> than $foo-E<gt>getline.
For backwards compatibilty, this module must continue to use
object-oriented I/O in most places, but if you use L<parse()|/parse>
with a "real" filehandle (string, globref, or subclass of IO::File)
then MIME::Parser is able to perform some crucial optimizations.

B<The parse_two() call is very inefficient.>
Currently this is just a front-end onto parse_data().
If your OS supports it, you're I<far> better off doing something like:

    $parser->parse_open("/bin/cat msg.head msg.body |");




=head2 Minimizing memory

Optimum input mechanisms:

    parse()                    YES
    parse_open()               YES
    parse_data()               NO  (in-core I/O will burn core)
    parse_two()                NO  (in-core I/O will burn core)

Optimum settings:

    extract_nested_messages()  *** (no real difference)
    output_to_core()           0   (will use MUCH less memory)
    tmp_recycling()            0?  (promotes faster GC if
                                    tmp_to_core is 1)
    tmp_to_core()              0   (will use MUCH less memory)
    use_inner_files()          *** (no real difference, but set it to 1
				    if you *must* have tmp_to_core set to 1,
				    so that you avoid in-core tmpfiles)


=head2 Maximizing tolerance of bad MIME

Optimum input mechanisms:

    parse()                    *** (doesn't matter)
    parse_open()               *** (doesn't matter)
    parse_data()               *** (doesn't matter)
    parse_two()                *** (doesn't matter)

Optimum settings:

    extract_nested_messages()  0   (sidesteps problems of bad nested messages,
                                    but often you want it set to 1 anyway).
    output_to_core()           *** (doesn't matter)
    tmp_recycling()            *** (doesn't matter)
    tmp_to_core()              *** (doesn't matter)
    use_inner_files()          *** (doesn't matter)


=head2 Avoiding disk-based temporary files

Optimum input mechanisms:

    parse()                    YES (if you give it a seekable handle)
    parse_open()               YES (becomes a seekable handle)
    parse_data()               NO  (unless you set tmp_to_core(1))
    parse_two()                NO  (unless you set tmp_to_core(1))

Optimum settings:

    extract_nested_messages()  *** (doesn't matter)
    output_to_core()           *** (doesn't matter)
    tmp_recycling              1   (restricts created files to 1 per parser)
    tmp_to_core()              1
    use_inner_files()          1

B<If we can use them, inner files avoid most tmpfiles.>
If you parse from a seekable-and-tellable filehandle, then the internal
process_to_bound() doesn't need to extract each part into a temporary
buffer; it can use IO::InnerFile (B<warning:> this will slow down
the parsing of messages with large attachments).

B<You can veto tmpfiles entirely.>
If you might not be parsing from a seekable-and-tellable filehandle,
you can set L<tmp_to_core()|/tmp_to_core> true: this will always
use in-core I/O for the buffering (B<warning:> this will slow down
the parsing of messages with large attachments).

B<Final resort.>
You can always override L<new_tmpfile()|/new_tmpfile> in a subclass.







=head1 WARNINGS

=over 4

=item Multipart messages are always read line-by-line

Multipart document parts are read line-by-line, so that the
encapsulation boundaries may easily be detected.  However, bad MIME
composition agents (for example, naive CGI scripts) might return
multipart documents where the parts are, say, unencoded bitmap
files... and, consequently, where such "lines" might be
veeeeeeeeery long indeed.

A better solution for this case would be to set up some form of
state machine for input processing.  This will be left for future versions.


=item Multipart parts read into temp files before decoding

In my original implementation, the MIME::Decoder classes had to be aware
of encapsulation boundaries in multipart MIME documents.
While this decode-while-parsing approach obviated the need for
temporary files, it resulted in inflexible and complex decoder
implementations.

The revised implementation uses a temporary file (a la C<tmpfile()>)
during parsing to hold the I<encoded> portion of the current MIME
document or part.  This file is deleted automatically after the
current part is decoded and the data is written to the "body stream"
object; you'll never see it, and should never need to worry about it.

Some folks have asked for the ability to bypass this temp-file
mechanism, I suppose because they assume it would slow down their application.
I considered accomodating this wish, but the temp-file
approach solves a lot of thorny problems in parsing, and it also
protects against hidden bugs in user applications (what if you've
directed the encoded part into a scalar, and someone unexpectedly
sends you a 6 MB tar file?).  Finally, I'm just not conviced that
the temp-file use adds significant overhead.


=item Fuzzing of CRLF and newline on input

RFC-1521 dictates that MIME streams have lines terminated by CRLF
(C<"\r\n">).  However, it is extremely likely that folks will want to
parse MIME streams where each line ends in the local newline
character C<"\n"> instead.

An attempt has been made to allow the parser to handle both CRLF
and newline-terminated input.


=item Fuzzing of CRLF and newline on output

The C<"7bit"> and C<"8bit"> decoders will decode both
a C<"\n"> and a C<"\r\n"> end-of-line sequence into a C<"\n">.

The C<"binary"> decoder (default if no encoding specified)
still outputs stuff verbatim... so a MIME message with CRLFs
and no explicit encoding will be output as a text file
that, on many systems, will have an annoying ^M at the end of
each line... I<but this is as it should be>.


=item Inability to handle multipart boundaries that contain newlines

First, let's get something straight: I<this is an evil, EVIL practice,>
and is incompatible with RFC-1521... hence, it's not valid MIME.

If your mailer creates multipart boundary strings that contain
newlines I<when they appear in the message body,> give it two weeks notice
and find another one.  If your mail robot receives MIME mail like this,
regard it as syntactically incorrect MIME, which it is.

Why do I say that?  Well, in RFC-1521, the syntax of a boundary is
given quite clearly:

      boundary := 0*69<bchars> bcharsnospace

      bchars := bcharsnospace / " "

      bcharsnospace :=    DIGIT / ALPHA / "'" / "(" / ")" / "+" /"_"
                   / "," / "-" / "." / "/" / ":" / "=" / "?"

All of which means that a valid boundary string I<cannot> have
newlines in it, and any newlines in such a string in the message header
are expected to be solely the result of I<folding> the string (i.e.,
inserting to-be-removed newlines for readability and line-shortening
I<only>).

Yet, there is at least one brain-damaged (or malicious) user agent 
out there that composes mail like this:

      MIME-Version: 1.0
      Content-type: multipart/mixed; boundary="----ABC-
       123----"
      Subject: Hi... I'm a dork!

      This is a multipart MIME message (yeah, right...)

      ----ABC-
       123----

      Hi there!

We have I<got> to discourage practices like this (and the recent file
upload idiocy where binary files that are part of a multipart MIME
message aren't base64-encoded) if we want MIME to stay relatively
simple, and MIME parsers to be relatively robust.

I<Thanks to Andreas Koenig for bringing a baaaaaaaaad user agent to
my attention.>


=back



=head1 AUTHOR

Eryq (F<eryq@zeegee.com>), ZeeGee Software Inc (F<http://www.zeegee.com>).

All rights reserved.  This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.



=head1 VERSION

$Revision: 6.106 $ $Date: 2003/06/04 17:54:01 $

=cut




