use lib "./t";

use MIME::Entity;
use ExtUtils::TBone;
use Globby;
use strict;

my $line;
my $LINE;


### black black magic:
{
   local $^W = undef;
   eval q{
	sub MIME::Entity::make_boundary {
	    return "----------=_000-000-000";
	}
   };
}

#------------------------------------------------------------
# BEGIN
#------------------------------------------------------------

# Create checker:
my $T = typical ExtUtils::TBone;
$T->begin(1);



#------------------------------------------------------------
$T->msg("Create an entity");
#------------------------------------------------------------

# Create the top-level, and set up the mail headers in a couple
# of different ways:
my $top = MIME::Entity->build(Type  => "multipart/mixed",
			      -From => "me\@myhost.com",
			      -To   => "you\@yourhost.com");
$top->head->add('subject', "Hello, nurse!");
$top->preamble([]);
$top->epilogue([]);

# Attachment #0: a simple text document: 
attach $top  Path=>"./testin/short.txt";

# Attachment #1: a GIF file:
attach $top  Path        => "./testin/mime-sm.gif",
             Type        => "image/gif",
             Encoding    => "base64",
	     Disposition => "attachment";

#------------------------------------------------------------
$T->msg("Output msg with default \n boundary delimiter [in binmode]");
#------------------------------------------------------------
open TMP, ">testout/bd.msg1" or die "open: $!";
binmode TMP;
$top->print(\*TMP);
close TMP;

#------------------------------------------------------------
$T->msg("Output msg with \r\n boundary delimiter [in binmode]");
#------------------------------------------------------------
open TMP, ">testout/bd.msg2" or die "open: $!";
binmode TMP;
{
   local $MIME::Entity::BOUNDARY_DELIMITER = "\r\n";
   $top->print(\*TMP);
}
close TMP;

#-----test------
$T->ok_eqnum((5 + (-s "testout/bd.msg1")),
	     (-s "testout/bd.msg2"), 
	     "expected difference between files");


# Done!
exit(0);
1;




