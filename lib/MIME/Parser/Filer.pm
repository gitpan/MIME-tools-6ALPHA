package MIME::Parser::Filer;

=head1 NAME

MIME::Parser::Filer - manage file-output of the parser


=head1 SYNOPSIS

Before reading further, you should see L<MIME::Parser> to make sure that
you understand where this module fits into the grand scheme of things.
Go on, do it now.  I'll wait.

Now read MIME::Parser::AbstractFiler.

Ready?  Ok... now read L<"DESCRIPTION"> below, and everything else
should make sense.


=head2 Public interface

    ### Create a "filer" of the desired class:
    $filer = MIME::Parser::FlatFiler->new($dir);
 (or)
    $filer = MIME::Parser::TreeFiler->new($topdir);

    ### Want added security?  Don't let outsiders name your files:
    $filer->ignore_filename(1);

    ### Prepare for the parsing of a new top-level message:
    $filer->init_parse;

    ### Given the head of a new message, return the path where this
    ### message's data should be placed:
    $path = $filer->output_path($head);


=head2 Semi-public interface

These methods might be overriden or ignored in some subclasses,
so they don't all make sense in all circumstances:

    ### Tweak the mapping from content-type to extension:
    $emap = $filer->output_extension_map;
    $emap->{"text/html"} = ".htm";




=head1 DESCRIPTION


=head2 How this class is used when parsing

When a MIME::Parser decides that it wants to output a file to disk,
it uses its "Filer" object -- an instance of a MIME::Parser::Filer
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

There are two standard "Filer" subclasses:
B<MIME::Parser::FlatFiler>, which throws all files from all parses
into the same directory, and B<MIME::Parser::TreeFiler> (preferred),
which creates a subdirectory for each message.  Hopefully, these will be
sufficient for most uses, but just in case...

The only method you have to override is L<output_path()|/output_path>:

    $filer->output_path($head);

This method is invoked by MIME::Parser when it wants to put a
decoded message body in an output file.  The method should return a
path to the file to create.  Failure is indicated by throwing an
exception.

The path returned by C<output_path()> should be "ready for open()":
any necessary parent directories need to exist at that point.
These directories can be created by the Filer, if course, and they
should be marked as B<purgeable()> if a purge should delete them.

Actually, if your issue is more I<where> the files go than
what they're named, you can use the default L<output_path()|/output_path>
method and just override one of its components:

    $dir  = $filer->output_dir($head);
    $name = $filer->output_filename($head);
    ...



=head1 PUBLIC INTERFACE

=over 4

=cut

use strict;
use base qw(MIME::Parser::AbstractFiler);

### Kit modules:
use MIME::Tools;
use File::Spec;
use MIME::WordDecoder;

### Output path uniquifiers:
my $GFileNo = 0;
my $GSubdirNo = 0;

### Map content-type to extension.
### If we can't map "major/minor", we try "major/*", then use "*/*".
my %DefaultTypeToExt =
qw(

application/andrew-inset	.ez
application/octet-stream	.bin
application/oda			.oda
application/pdf			.pdf
application/pgp			.pgp
application/postscript		.ps
application/rtf			.rtf
application/x-bcpio		.bcpio
application/x-chess-pgn		.pgn
application/x-cpio		.cpio
application/x-csh		.csh
application/x-dvi		.dvi
application/x-gtar		.gtar
application/x-gunzip		.gz
application/x-hdf		.hdf
application/x-latex		.latex
application/x-mif		.mif
application/x-netcdf		.cdf
application/x-netcdf		.nc
application/x-sh		.sh
application/x-shar		.shar
application/x-sv4cpio		.sv4cpio
application/x-sv4crc		.sv4crc
application/x-tar		.tar
application/x-tcl		.tcl
application/x-tex		.tex
application/x-texinfo		.texi
application/x-troff		.roff
application/x-troff		.tr
application/x-troff-man		.man
application/x-troff-me		.me
application/x-troff-ms		.ms
application/x-ustar		.ustar
application/x-wais-source	.src
application/zip			.zip

audio/basic			.snd
audio/ulaw			.au
audio/x-aiff			.aiff
audio/x-wav			.wav

image/gif			.gif
image/ief			.ief
image/jpeg			.jpg
image/png                       .png
image/xbm                       .xbm
image/tiff			.tif
image/x-cmu-raster		.ras
image/x-portable-anymap		.pnm
image/x-portable-bitmap		.pbm
image/x-portable-graymap	.pgm
image/x-portable-pixmap		.ppm
image/x-rgb			.rgb
image/x-xbitmap			.xbm
image/x-xpixmap			.xpm
image/x-xwindowdump		.xwd

text/*                          .txt
text/html			.html
text/plain			.txt
text/richtext			.rtx
text/tab-separated-values	.tsv
text/x-setext			.etx
text/x-vcard                    .vcf

video/mpeg			.mpg
video/quicktime			.mov
video/x-msvideo			.avi
video/x-sgi-movie		.movie

message/*                       .msg

*/*                             .dat

);


#------------------------------

sub init {
    my $self = shift;

    ### Always invoke inherited method first!
    $self->SUPER::init(@_);

    $self->{MPF_Prefix} = "msg";
    $self->{MPF_Dir}    = ".";
    $self->{MPF_Ext}    = { %DefaultTypeToExt };

    $self->{MPF_MaxName} = 80;       ### max filename before treated as evil
    $self->{MPF_TrimRoot} = 14;      ### trim root to this length
    $self->{MPF_TrimExt}  = 3;       ### trim extension to this length
}

#------------------------------
#
# cleanup_dir
#
# Class method, utility.
# Cleanup a directory, defaulting empty to "."
#
sub cleanup_dir {
    my ($self, $dir) = @_;
    $dir = '.' if (!defined($dir) || ($dir eq ''));   # coerce empty to "."
    $dir = '/.' if ($dir eq '/');   # coerce "/" so "$dir/$filename" works
    $dir =~ s|/$||;                 # be nice: get rid of any trailing "/"
    $dir;
}

#------------------------------

=item evil_filename FILENAME

I<Instance method.>
Is this an evil filename; i.e., one which should not be used
in generating a disk file name?  It is if any of these are true:

    * it is empty
    * it is a string of dots: ".", "..", etc.
    * it contains a known "path" character: '/' '\' ':' '[' ']'
    * it is too long

If you just want to change this behavior, you should override
this method in the subclass of MIME::Parser::Filer that you use.

B<Warning:> at the time this method is invoked, the FILENAME has
already been unmime'd into the local character set.
If you're using any character set other than ASCII, ISO-8859-*,
or UTF-8, the interpretation of the "path" characters might be
very different, and you will probably need to override this method.
See L<MIME::WordDecoder/unmime> for more details.

B<Note:> subclasses of MIME::Parser::Filer which override
output_path() might not consult this method; note, however, that
the built-in subclasses do consult it.

I<Thanks to Andrew Pimlott for finding a real dumb bug in the original
version.  Thanks to Nickolay Saukh for noting that evil is in the
eye of the beholder.>

=cut

sub evil_filename {
    my ($self, $name) = @_;

    $self->logger->debug("is this evil? '$name'");

    return 1 if (!defined($name) or ($name eq ''));   ### empty
    return 1 if ($name =~ m{^\.+\Z});         ### dots
    return 1 if ($name =~ tr{\\/:[]}{});      ### path characters
    return 1 if ($self->{MPF_MaxName} and
		 (length($name) > $self->{MPF_MaxName}));

    $self->logger->debug("it's ok");
    0;
}

#------------------------------

=item exorcise_filename FILENAME

I<Instance method.>
If a given filename is evil (see L</evil_filename>) we try to
rescue it by performing some basic operations: shortening it,
removing bad characters, etc., and checking each against
evil_filename().

Returns the exorcised filename (which is guaranteed to not
be evil), or undef if it could not be salvaged.

B<Warning:> at the time this method is invoked, the FILENAME has
already been unmime'd into the local character set.
If you're using anything character set other than ASCII, ISO-8859-*,
or UTF-8, the interpretation of the "path" characters might be very
very different, and you will probably need to override this method.
See L<MIME::WordDecoder/unmime> for more details.

=cut

sub exorcise_filename {
    my ($self, $fname) = @_;

    ### Isolate to last path element:
    my $last = $fname; $last =~ s{^.*[/\\\[\]:]}{};
    if ($last and !$self->evil_filename($last)) {
	$self->logger->debug("looks like I can use the last path element");
	return $last;
    }

    ### Break last element into root and extension, and truncate:
    my ($root, $ext) = (($last =~ /^(.*)\.([^\.]+)\Z/)
			? ($1, $2)
			: ($last, ''));
    $root = substr($root, 0, ($self->{MPF_TrimRoot} || 14));
    $ext  = substr($ext,  0, ($self->{MPF_TrimExt}  ||  3));
    $ext =~ /^\w+$/ or $ext = "dat";
    my $trunc = $root . ($ext ? ".$ext" : '');
    if (!$self->evil_filename($trunc)) {
	$self->logger->debug("looks like I can use a truncated last path element");
	return $trunc;
    }

    ### Hope that works:
    undef;
}

#------------------------------

=item find_unused_path DIR, FILENAME

I<Instance method, subclasses only.>
We have decided on an output directory and tentative filename,
but there is a chance that it might already exist.  Keep
adding a numeric suffix "-1", "-2", etc. to the filename
until an unused path is found, and then return that path.

The suffix is actually added before the first "." in the filename
is there is one; for example:

    picture.gif       archive.tar.gz      readme
    picture-1.gif     archive-1.tar.gz    readme-1
    picture-2.gif     archive-2.tar.gz    readme-2
    ...               ...                 ...
    picture-10.gif
    ...

This can be a costly operation, and risky if you don't want files
renamed, so it is in your best interest to minimize situations
where these kinds of collisions occur.  Unfortunately, if
a multipart message gives all of its parts the same recommended
filename, and you are placing them all in the same directory,
this method might be unavoidable.

=cut

sub find_unused_path {
    my ($self, $dir, $fname) = @_;
    my $i = 0;
    while (1) {

	### Create suffixed name (from filename), and see if we can use it:
	my $suffix = ($i ? "-$i" : "");
	my $sname = $fname; $sname =~ s/^(.*?)(\.|\Z)/$1$suffix$2/;
	my $path = File::Spec->catfile($dir, $sname);
	if (! -e $path) {   ### it's good!
	    $i and $self->logger->warning
		("collision with $fname in $dir: using $path");
	    return $path;
	}
	$self->logger->debug("$path already taken");
    } continue { ++$i; }
}

#------------------------------

=item ignore_filename [YESNO]

I<Instance method.>
Return true if we should always ignore recommended filenames in
messages, choosing instead to always generate our own filenames.
With argument, sets this value.

B<Note:> subclasses of MIME::Parser::Filer which override
output_path() might not honor this setting; note, however, that
the built-in subclasses honor it.

=cut

sub ignore_filename {
    my $self = shift;
    $self->{MPF_IgnoreFilename} = $_[0] if @_;
    $self->{MPF_IgnoreFilename};
}

#------------------------------

=item output_dir HEAD

I<Instance method, for subclasses only.>
Return the output directory for a singlepart entity with
the given header.
The default method returns ".".

=cut

sub output_dir {
    my ($self, $head) = @_;
    return ".";
}

#------------------------------

=item output_filename HEAD

I<Instance method, for subclasses only.>
A given recommended filename was either not given, or it was judged
to be evil.  Return a fake name, possibly using information in the
message HEADer.  Note that this is just the filename, not the full path.

Used by L<output_path()|/output_path>.
If you're using the default C<output_path()>, you probably don't
need to worry about avoiding collisions with existing files;
we take care of that in L<find_unused_path()|/find_unused_path>.

=cut

sub output_filename {
    my ($self, $head) = @_;

    ### Get the recommended name:
    my $recommended = unmime $head->recommended_filename;

    ### Get content type:
    my ($type, $subtype) = split m{/}, $head->mime_type; $subtype ||= '';

    ### Get recommended extension, being quite conservative:
    my $recommended_ext = (($recommended and ($recommended =~ m{(\.\w+)\Z}))
			   ? $1
			   : undef);

    ### Try and get an extension, honoring a given one first:
    my $ext = ($recommended_ext ||
	       $self->{MPF_Ext}{"$type/$subtype"} ||
	       $self->{MPF_Ext}{"$type/*"} ||
	       $self->{MPF_Ext}{"*/*"} ||
	       ".dat");

    ### Get a prefix, and make up a name:
    ++$GFileNo;
    return ($self->output_prefix . "-$$-$GFileNo$ext");
}

#------------------------------

=item output_prefix [PREFIX]

I<Instance method.>
Get the short string that all filenames for extracted body-parts
will begin with (assuming that there is no better "recommended filename").
The default is F<"msg">.

If PREFIX I<is not> given, the current output prefix is returned.
If PREFIX I<is> given, the output prefix is set to the new value,
and the previous value is returned.

Used by L<output_filename()|/output_filename>.

B<Note:> subclasses of MIME::Parser::Filer which override
output_path() or output_filename() might not honor this setting;
note, however, that the built-in subclasses honor it.

=cut

sub output_prefix {
    my ($self, $prefix) = @_;
    $self->{MPF_Prefix} = $prefix if (@_ > 1);
    $self->{MPF_Prefix};
}

#------------------------------

=item output_type_ext

I<Instance method.>
Return a reference to the hash used by the default
L<output_filename()|/output_filename> for mapping from content-types
to extensions when there is no default extension to use.

    $emap = $filer->output_typemap;
    $emap->{'text/plain'} = '.txt';
    $emap->{'text/html'}  = '.html';
    $emap->{'text/*'}     = '.txt';
    $emap->{'*/*'}        = '.dat';

B<Note:> subclasses of MIME::Parser::Filer which override
output_path() or output_filename() might not consult this hash;
note, however, that the built-in subclasses consult it.

=cut

sub output_type_ext  {
    my $self = shift;
    return $self->{MPF_Ext};
}

#------------------------------

=item output_path HEAD

I<Instance method, concrete override.>
Given a MIME head for a file to be extracted, come up with a good
output pathname for the extracted file.  This is the only method
you need to worry about if you are building a custom filer.

The default implementation does a lot of work; subclass
implementers I<really> should try to just override its components
instead of the whole thing.  It works basically as follows:

    $directory = $self->output_dir($head);

    $filename = $head->recommended_filename();
    if (!$filename or
	 $self->ignore_filename() or
	 $self->evil_filename($filename)) {
 	$filename = $self->output_filename($head);
    }

    return $self->find_unused_path($directory, $filename);

B<Note:> There are many, many, many ways you might want to control
the naming of files, based on your application.  If you don't like
the behavior of this function, you can easily define your own subclass
of MIME::Parser::Filer and override it there.

B<Note:> Nickolay Saukh pointed out that, given the subjective nature of
what is "evil", this function really shouldn't I<warn> about an evil
filename, but maybe just issue a I<debug> message.  I considered that,
but then I thought: if debugging were off, people wouldn't know why
(or even if) a given filename had been ignored.  In mail robots
that depend on externally-provided filenames, this could cause
hard-to-diagnose problems.  So, the message is still a warning.

I<Thanks to Laurent Amon for pointing out problems with the original
implementation, and for making some good suggestions.  Thanks also to
Achim Bohnet for pointing out that there should be a hookless, OO way of
overriding the output path.>

=cut

sub output_path {
    my ($self, $head) = @_;

    ### Get the output directory:
    my $dir = $self->output_dir($head);

    ### Get the output filename, decoding into the local character set:
    my $fname = unmime $head->recommended_filename;

    ### Can we use it:
    if    (!defined($fname)) {
	$self->logger->debug
	    ("no filename recommended: synthesizing our own");
	$fname = $self->output_filename($head);
    }
    elsif ($self->ignore_filename) {
	$self->logger->debug
	    ("ignoring all external filenames: synthesizing our own");
	$fname = $self->output_filename($head);
    }
    elsif ($self->evil_filename($fname)) {

	### Can we save it by just taking the last element?
	my $ex = $self->exorcise_filename($fname);
	if (defined($ex) and !$self->evil_filename($ex)) {
	    $self->logger->warning
		("Provided filename '$fname' is regarded as evil, ",
		 "but I was able to exorcise it and get something ",
		 "usable.");
	    $fname = $ex;
	}
	else {
	    $self->logger->warning
		("Provided filename '$fname' is regarded as evil; ",
		 "I'm ignoring it and supplying my own.");
	    $fname = $self->output_filename($head);
	}
    }
    $self->logger->debug("planning to use '$fname'");

    ### Resolve collisions and return final path:
    return $self->find_unused_path($dir, $fname);
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

