###############################################################
#
# $Id: 93_EmonCMSLog.pm 2014-05-03 playwithfree $
# Initial version by Fuzzy http://forum.fhem.de/index.php/topic,11472.0.html
#
###############################################################

package main;

use strict;
use warnings;
use Scalar::Util;
use LWP;
use LWP::UserAgent;
use HTTP::Request::Common;

################################################################
sub EmonCMSLog_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}    = "EmonCMSLog_Define";
    $hash->{UndefFn}  = "EmonCMSLog_Undef";
    $hash->{NotifyFn} = "EmonCMSLog_Log";
    $hash->{AttrFn}   = "EmonCMSLog_Attr";
    $hash->{AttrList} = "disable:0,1 loglevel:0,5";

}

################################################################
sub EmonCMSLog_Define($@) {
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );

    return "wrong syntax: define <name> EmonCMSLog baseURL APIKEY regexp"
      if ( int(@a) != 5 );

    $hash->{BASEURL} = $a[2];
    $hash->{APIKEY}  = $a[3];

    my $regexp = $a[4];

    eval { "Hallo" =~ m/^$regexp$/ };
    return "Bad regexp: $@" if ($@);
    $hash->{REGEXP} = $regexp;

	$hash->{STATE} = "active";
	
    return undef;
}

################################################################
sub EmonCMSLog_Undef($$) {
    my ( $hash, $name ) = @_;

    return undef;
}

################################################################
sub EmonCMSLog_Attr(@) {
    my @a  = @_;
    my $do = 0;

    if ( $a[0] eq "set" && $a[2] eq "disable" ) {
        $do = ( !defined( $a[3] ) || $a[3] ) ? 1 : 2;
    }
    $do = 2 if ( $a[0] eq "del" && ( !$a[2] || $a[2] eq "disable" ) );
    return if ( !$do );

    $defs{ $a[1] }{STATE} = ( $do == 1 ? "disabled" : "active" );

    return undef;
}

################################################################
sub EmonCMSLog_ParseEvent($$) {
    my ( $type, $event ) = @_;
    my @result;

    # split the event into reading and argument
    # "day-temp: 22.0 (Celsius)" -> "day-temp", "22.0 (Celsius)"
    my @parts   = split( /: /, $event );
    my $reading = shift @parts;
    my $value   = join( ": ", @parts );

    # default reading
    if ( !defined($value) || $value eq "" ) {
        $value   = $reading;
        $reading = "";
    }

    if ( !Scalar::Util::looks_like_number($value) ) {
        if ( $reading eq "battery" ) {
            $value =~ s/ok/1/;
            $value =~ s/replaced/1/;
            $value =~ s/low/0/;
            $value =~ s/empty/0/;
        }

        if ( $event =~ m/^dim(\d+).*/o ) {
            $value   = $1;
            $reading = "dim";
        }
        elsif ( $event =~ m/^level (\d+).*/o ) {
            $value   = $1;
            $reading = "level";
        }
        elsif ( $value =~ m/(\d+) \(Celsius\)/o ) {
            $value = $1;
        }
        elsif ( $value =~ m/(\d+) \(km\/h\)/o ) {
            $value = $1;
        }
        elsif ( $value =~ m/(\d+) \(l\/m2\)/o ) {
            $value = $1;
        }
        elsif ( $value =~ m/(\d+) \(\%\)/o ) {
            $value = $1;
        }
        else {
            $value =~ s/yes/1/;
            $value =~ s/no/0/;
            $value =~ s/on/1/;
            $value =~ s/off/0/;
        }
    
		if ( !Scalar::Util::looks_like_number($value) ) {
			$value = undef;
		}
	}

    @result = ( $reading, $value );
    return @result;
}

################################################################
sub EmonCMSLog_Log($$) {

    # Log is my entry, dev is the entry of the changed device
    my ( $log, $dev ) = @_;

    return undef if ( $log->{STATE} eq "disabled" );

	my $key = $log->{APIKEY};
    my $re  = $log->{REGEXP};
    my $n   = $dev->{NAME};
    my $t   = uc( $dev->{TYPE} );
	my $max = int( @{ $dev->{CHANGED} } );
	my $inputs = "";
    for ( my $i = 0 ; $i < $max ; $i++ ) {
        my $s = $dev->{CHANGED}[$i];
        $s = "" if ( !defined($s) );

        # log matching events only
        if ( $n =~ m/^$re$/ || "$n:$s" =~ m/^$re$/ ) {

            # parse the event
            my @r       = EmonCMSLog_ParseEvent( $t, $s );
            my $reading = $r[0];
            my $value   = $r[1];

			# skip non numeric reading
			next if (!$value);
						
			# append to result
            if ( length($inputs) > 0 ) {
                $inputs .= ",";
            }
            $inputs .= $n;
            if ( $reading ne "" ) {
                $inputs .= "." . $reading;
            }
            $inputs .= ":" . $value;
        }
	}

	if ($inputs) {
		my $emon_url =
		  $log->{BASEURL}."/input/post?json={$inputs}\&apikey=$key";
                Log3 $log->{NAME}, 5, "EmonCMSLog [$log->{NAME}]: $emon_url";
#		my $emon_ua = LWP::UserAgent->new;
#		$emon_ua->timeout(3);
#		my $emon_res = $emon_ua->get($emon_url);
		my $hash = { url => $emon_url,
		  callback=>sub($$$){ Log 5,"$emon_url\nERR:$_[1] DATA:$_[2]" },
		};
		my ($err, $ret) = HttpUtils_NonblockingGet($hash);
		if($err) {
		  Log3 undef, $hash->{loglevel}, "CustomGetFileFromURL $err";
		}

#		if ( $emon_res->is_error ) {
#			Log3 $log->{NAME}, 1,
#			  (     "EmonCMSLog => Update[" 
#				  . $n
#				  . "] ERROR: "
#				  . ( $emon_res->as_string )
#				  . "\n" );
#		} elsif ($emon_res->as_string !~ /\nok/ ) {
#                        Log3 $log->{NAME}, 1, "EmonCMSLog [$log->{NAME}]: $emon_url";
#			Log3 $log->{NAME}, 1,
#			  (     "EmonCMSLog => Update[" 
#				  . $n
#				  . "] RETURN: "
#				  . ( $emon_res->as_string )
#				  . "\n" );
#                }
	}
	
    return "";
}

1;
