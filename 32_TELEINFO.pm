# $Id: 32_TELEINFO.pm 0.5 2013-12-05 oliv06 $
# doc :  http://play.with.free.fr/index.php/fhem-module-teleinfo/
# credits :
#   code adapted from 15_CUL_EM.pm (author: rudolfkoenig)
#   and from 32_SYSSTAT.pm (author: justme1968)	
# licence : GPL 2

package main;

use strict;
use warnings;

sub
TELEINFO_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "TELEINFO_Define";
  $hash->{UndefFn}  = "TELEINFO_Undefine";
  $hash->{GetFn}    = "TELEINFO_Get";
  $hash->{AttrFn}   = "TELEINFO_Attr";
  $hash->{AttrList} = "cost-BASE cost-HCHC cost-HCHP cost-EJPHN cost-EJPHPM cost-BBRHCJB cost-BBRHPJB cost-BBRHCJW cost-BBRHPJW cost-BBRHCJR cost-BBRHPJR basicFeePerMonth ".
                       $readingFnAttributes;
}

#####################################

sub
TELEINFO_Define($$)
{
  my ($hash, $def) = @_;

  my @a = split("[ \t][ \t]*", $def);

  return "Usage: define <name> TELEINFO mountPoint [interval]"  if((@a < 3) || (@a >4));

  my $mountPoint = $a[2];;

  my $interval = 60;

  if (int(@a)==4) {
     if ( $a[3] =~ /^-?\d+$/ )  {
	# is a number
	$interval = $a[3];
     }
  }
  if( $interval < 60 ) { $interval = 60; }

  $hash->{INTERVAL} = $interval;
  $hash->{TELEINFUSE} = $mountPoint;
  $hash->{STATE} = "Initializing";

  my $ret = TELEINFO_InitSys( $hash );

  if (! $ret) { 
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "TELEINFO_GetUpdate", $hash, 0);
  }

  return $ret;
}

sub
TELEINFO_InitSys($)
{
    my ($hash) = @_;

    # Check if teleinfuse directory is mounted correctly
    opendir (DIR, $hash->{TELEINFUSE}) or return "TELEINFO $hash->{NAME}: Initialization Error: teleinfuse mount point $hash->{TELEINFUSE} : $!";
    open (STATUS, $hash->{TELEINFUSE}.'/status') or return "TELEINFO: Initialization Error: teleinfuse mount point $hash->{TELEINFUSE}.'/status' : $!";
    # at this point we suppose teleinfuse mount point is ready and OK, so get teleinfuse status
    my $line =<STATUS>;
    Log3 $hash->{NAME}, 1, "TELEINFO: $hash->{NAME} initialized : $line";
    $hash->{STATE} = $line;

    # update all available readings once except ADPS (may be old alert)
    readingsBeginUpdate($hash);
    while (my $file = readdir(DIR)) {
      next unless (-f "$hash->{TELEINFUSE}/$file");
      open (FILE, $hash->{TELEINFUSE}."/".$file) or return "TELEINFO: Initialization Error: $hash->{TELEINFUSE}/$file : $!";
      $line = <FILE>;
      if( $file ne "MOTDETAT" ) {
         # remove leading zeros if any
         $line =~ s/^0+(.)/"$1"/e;
         if ( $file =~ /(BASE)|(HCH)|(EJPH)|(BBRH)/ ) {
           $line = sprintf("%0.3f",$line/1000);
         }
      }
      if ($file eq "status") {
         readingsBulkUpdate($hash,"state",$line);
      } elsif ( $file !~ /(ADPS)|(ADIR)/ ) {
         readingsBulkUpdate($hash,$file,$line);
      }
    }
    # initiate tsecs
    if(!defined($hash->{tsecs})) {
      my $tsecs= time(); # number of non-leap seconds since January 1, 1970, UTC
      $hash->{tsecs} = $tsecs;
    }
    readingsEndUpdate($hash, 1);

    return undef;
}

sub
TELEINFO_Undefine($$)
{
  my ($hash, $arg) = @_;

  RemoveInternalTimer($hash);
  return undef;
}

sub
TELEINFO_Get($@)
{
  my ($hash, @a) = @_;

  my $name = $a[0];
  return "$name: get needs at least one parameter" if(@a < 2);

  my $cmd= $a[1];

  if($cmd eq "readings") {
    opendir (DIR, $hash->{TELEINFUSE}) or return "TELEINFO $hash->{NAME}: Initialization Error: $hash->{TELEINFUSE} : $!";
    open (STATUS, $hash->{TELEINFUSE}.'/status') or return "TELEINFO: Initialization Error: $hash->{TELEINFUSE}.'/status' : $!";
    # at this point we suppose teleinfuse mount point is ready and OK
    my @files = grep { !/(^\.)|(status)/ } readdir(DIR);
    my $ret =  join " ", @files; 

    return $ret;
  }

  return "Unknown argument $cmd, choose one of readings:noArg";
}

sub
TELEINFO_Attr($$$)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;

  $attrVal= "" unless defined($attrVal);
  my $orig = $attrVal;

  if( $attrName eq "readingsFilter") {
    my $hash = $defs{$name};
    my @filter = split(" ",$attrVal);
    @{$hash->{readingsFilter}} = @filter;
    # my %is_in_filter = map {$_ => 1} @filter;
    # %{$hash->{is_in_filter}} = %is_in_filter;
  }

  if( $cmd eq "set" ) {
    if( $orig ne $attrVal ) {
      $attr{$name}{$attrName} = $attrVal;
      return $attrName ." set to ". $attrVal;
    }
  }

  return;
}

sub
TELEINFO_GetUpdate($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  # Counter specials
  # total_cnt=  total (cumulated) value in Wh as read from the device
  # basis_cnt=  correction to total (cumulated) value in Wh to account for
  #             counter wraparounds
  # total    =  total (cumulated) value in Wh
  # delta    =  delta (cumulated) value in Wh over latest poll period

  my %readings; # prepare readings to be updated
  my $total_cnt = 0;
  my $total = 0;
  my $total_cnt_last = 0;
  my $basis_cnt = 0;
  my $cost = 0;
  my $basicfee = 0;

  # keep polling time in readings
  #
  my $interval = $hash->{INTERVAL};
  my $tsecs_prev;
  #----- get previous tsecs
  if(defined($hash->{tsecs})) {
     $tsecs_prev= $hash->{tsecs};
  } else {
     $tsecs_prev= 0; # 1970-01-01
  }
  #----- save actual tsecs
  my $tsecs= time();  # number of non-leap seconds since January 1, 1970, UTC
  $hash->{tsecs} = $tsecs;

  #schedule next poll
  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday()+$interval, "TELEINFO_GetUpdate", $hash, 1);

  # Get teleinfuse status
  opendir (DIR, $hash->{TELEINFUSE}) or return "TELEINFO $hash->{NAME}: Initialization Error: $hash->{TELEINFUSE} : $!";
  open (STATUS, $hash->{TELEINFUSE}.'/status') or return "TELEINFO: Initialization Error: $hash->{TELEINFUSE}.'/status' : $!";

  # at this point we suppose teleinfuse mount point is ready. 
  # Now get its state
  my $state = <STATUS>;
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash,"state",$state);

  if ( $state ne "online" ) { 
    Log3 $hash->{NAME}, 1, "TELEINFO $hash->{NAME}: status = $state";
  } else {
     my $energy = 0; # total energy (Wh) over the polling interval
     my $power  = 0; # active power (W) - average over the polling interval  
     my $bill   = 0; # bill over the last period  
     while (my $file = readdir(DIR)) {
      next unless (-f "$hash->{TELEINFUSE}/$file");
      open (FILE, $hash->{TELEINFUSE}."/".$file) or return "TELEINFO: Initialization Error: $hash->{TELEINFUSE}/$file : $!";
      my $line = <FILE>;
      if( $file ne "MOTDETAT" ) {
         # remove leading zeros if any
         $line =~ s/^0+(.)/"$1"/e;
      }

      if ($file ne "status") {
        if ( $file =~ /(BASE)|(HCH)|(EJPH)|(BBRH)/ ) {
          # convert Wh to kWh
          $line = sprintf("%0.3f",$line/1000);
          $readings{$file} = $line;

          ###################################
          # Start CUMULATE day and month 

	  $total_cnt = $line;
          # initialize total_cnt_last
          $total_cnt_last = 0;
          if(defined($hash->{READINGS}{$file})) {
            $total_cnt_last= $hash->{READINGS}{$file}{VAL};
          }

          # initialize basis_cnt_last
          $basis_cnt = 0;
          if(defined($hash->{READINGS}{$file."_basis".$file})) {
            $basis_cnt= $hash->{READINGS}{$file."_basis"}{VAL};
          }
          if($total_cnt < $total_cnt_last) {
            # counter wraparound
            $basis_cnt += $total_cnt_last;
            $readings{$file."_basis"} = $basis_cnt;
          }
          
          $total = ($basis_cnt+$total_cnt);

          # delta (kWh) = energy over last polling interval for this counter
          my $delta = $total - $total_cnt_last; 
          $readings{$file."_cum_".$interval."s"} = sprintf("%0.3f",$delta);
          # cumulated energy counters
          $energy += $delta*1000;

          #----- get cost parameter
          $cost = AttrVal($name, "cost-".$file, 0);
          $basicfee = AttrVal($name, "basicFeePerMonth", 0);

	  # bill over the last period
          #$bill += $delta * $cost;

          #----- check whether day or month was changed
          if(!defined($hash->{READINGS}{$file."_cum_day"})) {
            #----- init cum_day if it is not set
            readingsBulkUpdate($hash,$file."_cum_day",0);
            readingsBulkUpdate($hash,$file."_start_day",$total);
            readingsBulkUpdate($hash,$file."_cost_day",0);
          } else {
            if( (localtime($tsecs_prev))[3] != (localtime($tsecs))[3] ) {
              #----- day has changed (#3)
              my $val = $total-$hash->{READINGS}{$file."_start_day"}{VAL};
              readingsBulkUpdate($hash,$file."_cum_day",sprintf("%0.3f",$val));
              readingsBulkUpdate($hash,$file."_start_day",$total);
              readingsBulkUpdate($hash,$file."_cost_day",sprintf("%0.3f",$val*$cost));

              if( (localtime($tsecs_prev))[4] != (localtime($tsecs))[4] ) {
                #----- month has changed (#4)
                if(!defined($hash->{READINGS}{$file."_cum_month"})) {
                  # init cum_month if not set
                  readingsBulkUpdate($hash,$file."_cum_month",0);
                  readingsBulkUpdate($hash,$file."_start_month",$total);
                  readingsBulkUpdate($hash,$file."_cost_month",0);
                } else {
                  my $val = $total-$hash->{READINGS}{$file."_start_month"}{VAL};
                  readingsBulkUpdate($hash,$file."_cum_month",sprintf("%0.3f",$val));
                  readingsBulkUpdate($hash,$file."_start_month",$total);
                  readingsBulkUpdate($hash,$file."_cost_month",sprintf("%0.3f",$val*$cost+$basicfee));
                }
              }
            }
          } 
          # End CUMULATE day and month


        #} elsif ( $file eq "ADPS" ) {
        } elsif ( $file =~ /(ADPS)|(ADIR.*)/ ) {
	   # update ADPS or ADIR1-ADIR3 value only if changed
           my $file_mtime = (stat(FILE))[9]; 
           if ($tsecs_prev < $file_mtime ) {
              # file's last modify time more recent than last poll
              readingsBulkUpdate($hash,$file,$line);
           }
        } else {
              readingsBulkUpdate($hash,$file,$line);
        }
      }
      # update calculated values
      foreach my $k (keys %readings) {
        readingsBulkUpdate($hash, $k, $readings{$k});
      }
     }
     $power = sprintf("%u", $energy / ($tsecs - $tsecs_prev) * 3600 );
     readingsBulkUpdate($hash, "P_avg_".$interval."s", $power);
  }
  readingsEndUpdate($hash, 1);
}

1;

=pod
=begin html
<a name="TELEINFO"></a>
<h3>TELEINFO</h3>
<ul>The TELEINFO module interprets messages sent by french energy meters using teleinfuse on the host FHEM runs on.</ul>
<strong>Notes:</strong>
<ul>
<ul>
<ul>
	<li>Only Linux is supported.</li>
	<li>This module needs the <code>teleinfuse</code> program.
Code can be retrieved on '<code>http://code.google.com/p/teleinfuse/</code>' and a mount point must be setup as here: '<code>teleinfuse /dev/ttyUSB0 /mnt/teleinfo -o allow-other</code>'</li>
</ul>
</ul>
</ul>
<a name="TELEINFO_Define"></a>

<strong>Define</strong>

<code>define &lt;name&gt; TELEINFO &lt;mountpoint&gt; &lt;device&gt; [&lt;interval&gt;] </code>

Defines a TELEINFO device.

Data is updated every &lt;interval&gt; seconds. The default and minimum is 60.

Examples:

<code>define teleinfo TELEINFO /mnt/teleinfo</code>

<code>define teleinfo TELEINFO /mnt/teleinfo 300</code>

&nbsp;

<a name="TELEINFO_Readings"></a>

<strong>Readings</strong>
<ul>
	<li>OPTARIF
Option tarifaire</li>
	<li>ISOUSC
Intensité souscrite</li>
	<li>BASE
Index en kWh si option = base</li>
	<li>HCHC
Index heures creuses en kWh si option = heures creuses</li>
	<li>HCHP
Index heures pleines en kWh si option = heures creuses</li>
	<li>EJP HN
Index heures normales en kWh si option = EJP</li>
	<li>EJP HPM
Index heures de pointe mobile en kWh si option = EJP</li>
	<li>BBR HC JB
Index heures creuses jours bleus en kWh si option = tempo</li>
	<li>BBR HP JB
Index heures pleines jours bleus en kWh si option = tempo</li>
	<li>BBR HC JW
Index heures creuses jours blancs en kWh si option = tempo</li>
	<li>BBR HP JW
Index heures pleines jours blancs si option = tempo</li>
	<li>BBR HC JR
Index heures creuses jours rouges si option = tempo</li>
	<li>BBR HP JR
Index heures pleines jours rouges si option = tempo</li>
	<li>PEJP
Préavis EJP si option = EJP (30mn avant période EJP)</li>
	<li>PTEC
Période tarifaire en cours</li>
	<li>DEMAIN
Couleur du lendemain si option = tempo</li>
	<li>IINST, IINST1, IINST2, IINST3
Intensité instantanée (par phase pour compteurs triphasés)</li>
	<li>ADPS, ADIR1, ADIR2, ADIR3
Avertissement de dépassement de puissance souscrite (par phase pour compteur triphasé) : message émis uniquement en cas de dépassement effectif</li>
	<li>IMAX, IMAX1, IMAX2, IMAX3
Intensité maximale (par phase pour compteurs triphasés)</li>
	<li>PAPP
Puissance apparente en VA</li>
	<li>PMAX
Puissance apparente triphasée en VA</li>
	<li>HHPHC
Groupe horaire si option = heures creuses ou tempo</li>
	<li>MOTDETAT
Mot d'état (autocontrôle)</li>
	<li>BASE_cum_day, HCHP_cum_day, HPHP_cum_day etc.
Compteurs de consommation par jour : CUM_DAY: conso jour précédent en kWh</li>
	<li>BASE_cum, HCHP_cum, HPHP_cum etc.
Index de consommation corrigé en début de journ�en kWh</li>
	<li>BASE_cum_&lt;interval&gt;s, HCHP_cum_&lt;interval&gt;s, HPHP_cum_&lt;interval&gt;s etc.
Consommation cumulée sur l'intervalle de polling en kWh</li>
	<li>BASE_cum_cost_day, HCHP_cum_cost_day, HPHP_cum_cost_day etc.
Coût par jour</li>
	<li>BASE_cum_month, HCHP_cum_month, HPHP_cum_month etc.
Compteurs de consommation par mois : CUM_DAY: conso mois précédent en Wh</li>
	<li>BASE_cum_cost_month, HCHP_cum_month, HPHP_cum_cost_month etc.
Coût par jour</li>
	<li>P_avg_&lt;interval&gt;s
Puissance active moyenne globale sur l'intervalle &lt;interval&gt;s</li>
</ul>
<strong>Get</strong>

<code>get &lt;name&gt; &lt;value&gt;</code>

where

<code>value</code>

is one of
<ul>
	<li>readingsLists 
the readings that can be monitored (different depending on counter parameters).</li>
</ul>
<a name="TELEINFO_Attr"></a>

<strong>Attributes</strong>
<ul>
	<li>basicFeePerMonth
basic fee per month.</li>
	<li>cost-BASE
cost per kWh if BASE fee.</li>
	<li>cost-HCHC
cost per kWh if HC hours.</li>
	<li>cost-EJPHN cost-EJPHPM cost-BBRHCJB cost-BBRHPJB cost-BBRHCJW cost-BBRHPJW cost-BBRHCJR cost-BBRHPJR
cost per kWh depending on contract, days and hours</li>
	<li>readingFnAttributes</li>
</ul>
=end html
=cut

