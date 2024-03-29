package MIME::Head;


=head1 NAME

MIME::Head - MIME message header (a subclass of Mail::Header)


=head1 SYNOPSIS

Before reading further, you should see L<MIME::Tools> to make sure that 
you understand where this module fits into the grand scheme of things.
Go on, do it now.  I'll wait.

Ready?  Ok...

=head2 Construction

    ### Create a new, empty header, and populate it manually:    
    $head = MIME::Head->new;
    $head->replace('content-type', 'text/plain; charset=US-ASCII');
    $head->replace('content-length', $len);
    
    ### Parse a new header from a filehandle:
    $head = MIME::Head->read(\*STDIN);
    
    ### Parse a new header from a file, or a readable pipe:
    $testhead = MIME::Head->from_file("/tmp/test.hdr");
    $a_b_head = MIME::Head->from_file("cat a.hdr b.hdr |");


=head2 Output

    ### Output to filehandle:
    $head->print(\*STDOUT);  
    
    ### Output as string:
    print STDOUT $head->as_string;
    print STDOUT $head->stringify;


=head2 Getting field contents

    ### Is this a reply?
    $is_reply = 1 if ($head->get('Subject') =~ /^Re: /);
    
    ### Get receipt information:
    print "Last received from: ", $head->get('Received', 0), "\n";
    @all_received = $head->get('Received');
    
    ### Print the subject, or the empty string if none:
    print "Subject: ", $head->get('Subject',0), "\n";
     
    ### Too many hops?  Count 'em and see!
    if ($head->count('Received') > 5) { ...
    
    ### Test whether a given field exists
    warn "missing subject!" if (! $head->count('subject'));


=head2 Setting field contents

    ### Declare this to be an HTML header:
    $head->replace('Content-type', 'text/html');


=head2 Manipulating field contents

    ### Get rid of internal newlines in fields:
    $head->unfold;
    
    

=head2 Getting high-level MIME information

    ### Get/set a given MIME attribute:
    unless ($charset = $head->mime_attr('content-type.charset')) {
        $head->mime_attr("content-type.charset" => "US-ASCII");
    }

    ### The content type (e.g., "text/html"):
    $mime_type     = $head->mime_type;
    
    ### The content transfer encoding (e.g., "quoted-printable"):
    $mime_encoding = $head->mime_encoding;
    
    ### The recommended name when extracted:
    $file_name     = $head->recommended_filename;
    
    ### The boundary text, for multipart messages:
    $boundary      = $head->multipart_boundary;


=head1 DESCRIPTION

A class for parsing in and manipulating RFC-822 message headers, with some 
methods geared towards standard (and not so standard) MIME fields as 
specified in RFC-1521, I<Multipurpose Internet Mail Extensions>.


=head1 PUBLIC INTERFACE

=cut

#------------------------------

require 5.002;

### Pragmas:
use strict;
use vars qw($VERSION @ISA @EXPORT_OK);

### System modules:
use IO::Wrap;

### Other modules:
use Mail::Header 1.09 ();
use Mail::Field  1.05 ();

### Kit modules:
use MIME::Words qw(:all);
use MIME::Tools qw(:config :msgs);
use MIME::Field::ParamVal;
use MIME::Field::ConTraEnc;
use MIME::Field::ContDisp;
use MIME::Field::ContType;

@ISA = qw(Mail::Header);


#------------------------------
#
# Public globals...
#
#------------------------------

### The package version, both in 1.23 style *and* usable by MakeMaker:
$VERSION = substr q$Revision: 6.106 $, 10;

### Sanity (we put this test after our own version, for CPAN::):
use Mail::Header 1.06 ();


#------------------------------

=head2 Creation, input, and output

=over 4

=cut

#------------------------------


#------------------------------

=item new [ARG],[OPTIONS]

I<Class method, inherited.>
Creates a new header object.  Arguments are the same as those in the 
superclass.  

=cut

sub new {
    my $class = shift;
    bless Mail::Header->new(@_), $class;
}

#------------------------------

=item from_file EXPR,OPTIONS

I<Class or instance method>.
For convenience, you can use this to parse a header object in from EXPR, 
which may actually be any expression that can be sent to open() so as to 
return a readable filehandle.  The "file" will be opened, read, and then 
closed:

    ### Create a new header by parsing in a file:
    my $head = MIME::Head->from_file("/tmp/test.hdr");

Since this method can function as either a class constructor I<or> 
an instance initializer, the above is exactly equivalent to:

    ### Create a new header by parsing in a file:
    my $head = MIME::Head->new->from_file("/tmp/test.hdr");

On success, the object will be returned; on failure, the undefined value.

The OPTIONS are the same as in new(), and are passed into new()
if this is invoked as a class method.

B<Note:> This is really just a convenience front-end onto C<read()>,
provided mostly for backwards-compatibility with MIME-parser 1.0.

=cut

sub from_file {
    my ($self, $file, @opts) = @_; ### at this point, $self is inst. or class!
    my $class = ref($self) ? ref($self) : $self;

    ### Parse:
    open(HDR, $file) or die "can't open $file: $!\n";
    binmode(HDR);  # we expect to have \r\n at line ends, and want to keep 'em.
    $self = $class->new(\*HDR, @opts);      ### now, $self is instance or undef
    close(HDR);
    $self;
}

#------------------------------

=item read FILEHANDLE

I<Instance (or class) method.> 
This initiallizes a header object by reading it in from a FILEHANDLE,
until the terminating blank line is encountered.  
A syntax error or end-of-stream will also halt processing.

Supply this routine with a reference to a filehandle glob; e.g., C<\*STDIN>:

    ### Create a new header by parsing in STDIN:
    $head->read(\*STDIN);

On success, the self object will be returned; on failure, a false value.

B<Note:> in the MIME world, it is perfectly legal for a header to be
empty, consisting of nothing but the terminating blank line.  Thus,
we can't just use the formula that "no tags equals error".

B<Warning:> as of the time of this writing, Mail::Header::read did not flag
either syntax errors or unexpected end-of-file conditions (an EOF
before the terminating blank line).  MIME::ParserBase takes this
into account.

=cut

sub read {
    my $self = shift;      ### either instance or class!
    ref($self) or $self = $self->new;    ### if used as class method, make new
    $self->SUPER::read(@_);   
}



#------------------------------

=back

=head2 Getting/setting fields

The following are methods related to retrieving and modifying the header 
fields.  Some are inherited from Mail::Header, but I've kept the
documentation around for convenience.

=over 4

=cut

#------------------------------


#------------------------------

=item add TAG,TEXT,[INDEX]

I<Instance method, inherited.>
Add a new occurence of the field named TAG, given by TEXT:

    ### Add the trace information:    
    $head->add('Received', 
               'from eryq.pr.mcs.net by gonzo.net with smtp');

Normally, the new occurence will be I<appended> to the existing 
occurences.  However, if the optional INDEX argument is 0, then the 
new occurence will be I<prepended>.  If you want to be I<explicit> 
about appending, specify an INDEX of -1.

B<Warning>: this method always adds new occurences; it doesn't overwrite
any existing occurences... so if you just want to I<change> the value
of a field (creating it if necessary), then you probably B<don't> want to use 
this method: consider using C<replace()> instead.

=cut

### Inherited.

#------------------------------

=item count TAG

I<Instance method, inherited.>
Returns the number of occurences of a field; in a boolean context, this
tells you whether a given field exists:

    ### Was a "Subject:" field given?
    $subject_was_given = $head->count('subject');

The TAG is treated in a case-insensitive manner.
This method returns some false value if the field doesn't exist,
and some true value if it does.

=cut

### Inherited.

#------------------------------
#
# decode
#
# Instance method, deprecated.
#
sub decode {
    usage_error "deprecated MIME::Head::decode() has been removed";
}

#------------------------------

=item delete TAG,[INDEX]

I<Instance method, inherited.>
Delete all occurences of the field named TAG.

    ### Remove some MIME information:
    $head->delete('MIME-Version');
    $head->delete('Content-type');

=cut

### Inherited


#------------------------------

=item get TAG,[INDEX]

I<Instance method, inherited.>  
Get the contents of field TAG.

If a B<numeric INDEX> is given, returns the occurence at that index, 
or undef if not present:

    ### Print the first and last 'Received:' entries (explicitly):
    print "First, or most recent: ", $head->get('received', 0), "\n";
    print "Last, or least recent: ", $head->get('received',-1), "\n"; 

If B<no INDEX> is given, but invoked in a B<scalar> context, then
INDEX simply defaults to 0:

    ### Get the first 'Received:' entry (implicitly):
    my $most_recent = $head->get('received');

If B<no INDEX> is given, and invoked in an B<array> context, then
I<all> occurences of the field are returned:

    ### Get all 'Received:' entries:
    my @all_received = $head->get('received');

=cut

### Inherited.


#------------------------------

=item get_all FIELD

I<Instance method.>
Returns the list of I<all> occurences of the field, or the 
empty list if the field is not present:

    ### How did it get here?
    @history = $head->get_all('Received');

B<Note:> I had originally experimented with having C<get()> return all 
occurences when invoked in an array context... but that causes a lot of 
accidents when you get careless and do stuff like this:

    print "\u$field: ", $head->get($field), "\n";

It also made the intuitive behaviour unclear if the INDEX argument 
was given in an array context.  So I opted for an explicit approach
to asking for all occurences.

=cut

sub get_all {
    my ($self, $tag) = @_;
    $self->count($tag) or return ();          ### empty if doesn't exist
    ($self->get($tag));
}

#------------------------------

=item print [OUTSTREAM]

I<Instance method, override.>
Print the header out to the given OUTSTREAM, or the currently-selected
filehandle if none.  The OUTSTREAM may be a filehandle, or any object
that responds to a print() message.

The override actually lets you print to any object that responds to
a print() method.  This is vital for outputting MIME entities to scalars.

Also, it defaults to the I<currently-selected> filehandle if none is given
(not STDOUT!), so I<please> supply a filehandle to prevent confusion.

=cut

sub print {
    my ($self, $fh) = @_;
    $fh = wraphandle($fh || select);   ### get output handle, as a print()able
    $fh->print($self->as_string);
}

#------------------------------

=item stringify

I<Instance method.>
Return the header as a string.  You can also invoke it as C<as_string>.

=cut

sub stringify {
    my $self = shift;          ### build clean header, and output...
    my @header = grep {defined($_) ? $_ : ()} @{$self->header};
    join "", map { /\n$/ ? $_ : "$_\n" } @header;
}
sub as_string { shift->stringify(@_) }

#------------------------------

=item unfold [FIELD]

I<Instance method, inherited.>
Unfold (remove newlines in) the text of all occurences of the given FIELD.  
If the FIELD is omitted, I<all> fields are unfolded.
Returns the "self" object.

=cut

### Inherited


#------------------------------

=back

=head2 MIME-specific methods

All of the following methods extract information from the following fields:

    Content-type
    Content-transfer-encoding
    Content-disposition

Be aware that they do not just return the raw contents of those fields,
and in some cases they will fill in sensible (I hope) default values.
Use C<get()> or C<mime_attr()> if you need to grab and process the 
raw field text.

B<Note:> some of these methods are provided both as a convenience and
for backwards-compatibility only, while others (like
recommended_filename()) I<really do have to be in MIME::Head to work
properly,> since they look for their value in more than one field.
However, if you know that a value is restricted to a single
field, you should really use the Mail::Field interface to get it.

=over 4

=cut

#------------------------------

=item mime_attr ATTR,[VALUE]

A quick-and-easy interface to set/get the attributes in structured 
MIME fields:

    $head->mime_attr("content-type"         => "text/html");
    $head->mime_attr("content-type.charset" => "US-ASCII");
    $head->mime_attr("content-type.name"    => "homepage.html");

This would cause the final output to look something like this:

    Content-type: text/html; charset=US-ASCII; name="homepage.html"

Note that the special empty sub-field tag indicates the anonymous 
first sub-field.

B<Giving VALUE as undefined> will cause the contents of the named subfield 
to be deleted:

    $head->mime_attr("content-type.charset" => undef);

B<Supplying no VALUE argument> just returns the attribute's value,
or undefined if it isn't there:

    $type = $head->mime_attr("content-type");      ### text/html
    $name = $head->mime_attr("content-type.name"); ### homepage.html

In all cases, the new/current value is returned.

=cut

sub mime_attr {
    my ($self, $attr, $value) = @_;

    ### Break attribute name up:
    my ($tag, $subtag) = split /\./, $attr;
    $subtag ||= '_';

    ### Set or get?
    my $field = MIME::Field::ParamVal->parse($self->get($tag, 0));
    if (@_ > 2) {   ### set it:
	$field->param($subtag, $value);             ### set subfield
	$self->replace($tag, $field->stringify);    ### replace!
	return $value;
    }
    else {          ### get it:
	return $field->param($subtag);
    }
}

#------------------------------

=item mime_encoding

I<Instance method.>
Try I<real hard> to determine the content transfer encoding
(e.g., C<"base64">, C<"binary">), which is returned in all-lowercase.

If no encoding could be found, the default of C<"7bit"> is returned.  
I quote from RFC-1521 section 5:

    This is the default value -- that is, "Content-Transfer-Encoding: 7BIT" 
    is assumed if the Content-Transfer-Encoding header field is not present.

I do one other form of fixup: "7_bit", "7-bit", and "7 bit" are 
corrected to "7bit"; likewise for "8bit".

=cut

sub mime_encoding {
    my $self = shift;
    my $enc = lc($self->mime_attr('content-transfer-encoding') || '7bit');
    $enc =~ s{^([78])[ _-]bit\Z}{$1bit};
    $enc;
}

#------------------------------

=item mime_type [DEFAULT]

I<Instance method.>
Try C<real hard> to determine the content type (e.g., C<"text/plain">,
C<"image/gif">, C<"x-weird-type">, which is returned in all-lowercase.  
"Real hard" means that if no content type could be found, the default 
(usually C<"text/plain">) is returned.  From RFC-1521 section 7.1:

    The default Content-Type for Internet mail is 
    "text/plain; charset=us-ascii".

Unless this is a part of a "multipart/digest", in which case 
"message/rfc822" is the default.  Note that you can also I<set> the 
default, but you shouldn't: normally only the MIME parser uses this 
feature.

=cut

sub mime_type {
    my ($self, $default) = @_;
    $self->{MIH_DefaultType} = $default if @_ > 1;
    lc($self->mime_attr('content-type') || 
       $self->{MIH_DefaultType} || 
       'text/plain');
}

#------------------------------

=item multipart_boundary

I<Instance method.>
If this is a header for a multipart message, return the 
"encapsulation boundary" used to separate the parts.  The boundary
is returned exactly as given in the C<Content-type:> field; that
is, the leading double-hyphen (C<-->) is I<not> prepended.

Well, I<almost> exactly... this passage from RFC-1521 dictates
that we remove any trailing spaces:

   If a boundary appears to end with white space, the white space 
   must be presumed to have been added by a gateway, and must be deleted.

Returns undef (B<not> the empty string) if either the message is not
multipart, if there is no specified boundary, or if the boundary is
illegal (e.g., if it is empty after all trailing whitespace has been
removed).

=cut

sub multipart_boundary {
    my $self = shift;
    my $value =  $self->mime_attr('content-type.boundary');
    (!defined($value) or $value eq '') ? undef : $value;
}

#------------------------------

=item recommended_filename

I<Instance method.>
Return the recommended external filename.  This is used when
extracting the data from the MIME stream.

Returns undef if no filename could be suggested.

=cut

sub recommended_filename {
    my $self = shift;
    my $value;

    ### Start by trying to get 'filename' from the 'content-disposition':
    $value = $self->mime_attr('content-disposition.filename');
    return $value if (defined($value) and $value ne '');

    ### No?  Okay, try to get 'name' from the 'content-type':
    $value = $self->mime_attr('content-type.name');
    return $value if (defined($value) and $value ne '');

    ### Sorry:
    undef;
}

#------------------------------

=back

=cut




__END__

#------------------------------


=head1 NOTES

=over 4

=item Why have separate objects for the entity, head, and body?

See the documentation for the MIME-tools distribution
for the rationale behind this decision.


=item Why assume that MIME headers are email headers?

I quote from Achim Bohnet, who gave feedback on v.1.9 (I think
he's using the word "header" where I would use "field"; e.g.,
to refer to "Subject:", "Content-type:", etc.):

    There is also IMHO no requirement [for] MIME::Heads to look 
    like [email] headers; so to speak, the MIME::Head [simply stores] 
    the attributes of a complex object, e.g.:

        new MIME::Head type => "text/plain",
                       charset => ...,
                       disposition => ..., ... ;

I agree in principle, but (alas and dammit) RFC-1521 says otherwise.
RFC-1521 [MIME] headers are a syntactic subset of RFC-822 [email] headers.
Perhaps a better name for these modules would be RFC1521:: instead of
MIME::, but we're a little beyond that stage now.

In my mind's eye, I see an abstract class, call it MIME::Attrs, which does
what Achim suggests... so you could say:

     my $attrs = new MIME::Attrs type => "text/plain",
				 charset => ...,
                                 disposition => ..., ... ;

We could even make it a superclass of MIME::Head: that way, MIME::Head
would have to implement its interface, I<and> allow itself to be
initiallized from a MIME::Attrs object.

However, when you read RFC-1521, you begin to see how much MIME information
is organized by its presence in particular fields.  I imagine that we'd
begin to mirror the structure of RFC-1521 fields and subfields to such 
a degree that this might not give us a tremendous gain over just
having MIME::Head.


=item Why all this "occurence" and "index" jazz?  Isn't every field unique?

Aaaaaaaaaahh....no.

Looking at a typical mail message header, it is sooooooo tempting to just
store the fields as a hash of strings, one string per hash entry.  
Unfortunately, there's the little matter of the C<Received:> field, 
which (unlike C<From:>, C<To:>, etc.) will often have multiple 
occurences; e.g.:

    Received: from gsfc.nasa.gov by eryq.pr.mcs.net  with smtp
        (Linux Smail3.1.28.1 #5) id m0tStZ7-0007X4C; 
	 Thu, 21 Dec 95 16:34 CST
    Received: from rhine.gsfc.nasa.gov by gsfc.nasa.gov 
	 (5.65/Ultrix3.0-C) id AA13596; 
	 Thu, 21 Dec 95 17:20:38 -0500
    Received: (from eryq@localhost) by rhine.gsfc.nasa.gov 
	 (8.6.12/8.6.12) id RAA28069; 
	 Thu, 21 Dec 1995 17:27:54 -0500
    Date: Thu, 21 Dec 1995 17:27:54 -0500
    From: Eryq <eryq@rhine.gsfc.nasa.gov>
    Message-Id: <199512212227.RAA28069@rhine.gsfc.nasa.gov>
    To: eryq@eryq.pr.mcs.net
    Subject: Stuff and things

The C<Received:> field is used for tracing message routes, and although
it's not generally used for anything other than human debugging, I
didn't want to inconvenience anyone who actually wanted to get at that
information.  

I also didn't want to make this a special case; after all, who
knows what other fields could have multiple occurences in the
future?  So, clearly, multiple entries had to somehow be stored
multiple times... and the different occurences had to be retrievable.

=back


=head1 AUTHOR

Eryq (F<eryq@zeegee.com>), ZeeGee Software Inc (F<http://www.zeegee.com>).

All rights reserved.  This program is free software; you can redistribute 
it and/or modify it under the same terms as Perl itself.

The more-comprehensive filename extraction is courtesy of 
Lee E. Brotzman, Advanced Data Solutions.


=head1 VERSION

$Revision: 6.106 $ $Date: 2003/06/04 17:54:01 $

=cut

1;
