#!/usr/bin/perl -w
#=========================================================================================================
# Author: Paul Lemmons
# Date: December 2016
# Description: This program reaches out to each server and runs an iostat to collect statistics relating
#              to I/O. These stats are then sent to the graphite server for retention and display by the 
#              grafana server.
#
#              The program uses a multi threaded design to send to a large number of hosts at the same time. 
#              The number of hosts that it processes simultaneously is controlled by the $MAX_PROCESSES 
#              Variable below.
#              
#              The connection to the graphite server is also hard coded below and should be updated to reflect 
#              reality. 
# 
# Dependencies:
#              This program depends on the "whichHost.pl"" script being on each host. It also depends on a
#              userid of "graphite" being established on each host. This userid must also have authorized 
#              access from this host's root or whatever ID is running theis script via ssh keys.
#
# IMPORTANT:
#
# Make sure you add these lines to the: /etc/carbon/storage-schemas.conf and restart Carbon-cache service before 
# the first time you call this program or the retention of data will be a lot shorter than you hope for.
#
# [powervm]
# pattern = ^powervm.*
# retentions = 60s:60d, 5m:180d, 15m:395d, 1h:5y
#
#=========================================================================================================
use strict;
use List::Util qw[min max];
use Net::Graphite;
use Parallel::ForkManager;
use Net::Ping;

#==============================================================================================================================
# Configuration Constants
#==============================================================================================================================
my $MAX_PROCESSES  = 50;   # How many hosts should I process at a time
my $IOSTAT_SECONDS = 20;   # How long should iostat collect stats
my $INTERVAL       = 2*60; # Collect data every 2 minutes
my $ETERNITY_ROLLS = 1;    # Handy constant

my $pinger         = Net::Ping->new('external',2);
#==============================================================================================================================
# Setup for connection to Graphite service
#==============================================================================================================================
my $graphite = Net::Graphite->new(
     # except for host, these hopefully have reasonable defaults, so are optional
     host                  => 'yourhost.yourbiz.com',
     port                  => 2003,
     trace                 => 0,                # if true, copy what's sent to STDERR
     proto                 => 'tcp',            # can be 'udp'
     timeout               => 1,                # timeout of socket connect in seconds
     fire_and_forget       => 0,                # if true, ignore sending errors
     return_connect_error  => 0,                # if true, forward connect error to caller
 );
my $graphite_root = 'powervm';                  # This is the top most node name in graphite data tree
my %graphiteData  = ();                         # The graphite data structure
#-------------------------------------------------------------------------------------------------
# Instanciate a process manager
#-------------------------------------------------------------------------------------------------
my $pm = new Parallel::ForkManager($MAX_PROCESSES);
   
while ($ETERNITY_ROLLS)
{
   my @hostList      = ('host1','host2','host3','host4'); # List of AIX hosts. Recommend replaceing with something more dynamic
   #===================================================================================================================
   # Go through and collect data on each host
   #===================================================================================================================
   foreach my $host (@hostList)
   {
      if ($pinger->ping($host))
      {
         #================================================================================================================
         # Fork starting here
         #================================================================================================================
         my $pid       = $pm->start and next;
         #print "Starting Collecting from host... $host\n";

         #================================================================================================================
         # Collect IO data from host
         #================================================================================================================
         my $timeStamp = time();
         my @ioData    = `ssh graphite\@$host 'iostat -DRTl $IOSTAT_SECONDS 1'`;
         my @vgData    = `ssh graphite\@$host 'lsvg -p \`lsvg\`'`;
         my $msName    = `ssh graphite\@$host '/usr/local/bin/whichHost.pl | tr -d "\n"'`;

         #================================================================================================================
         # Initialize top level graphite nodes
         #================================================================================================================
         $graphiteData{$timeStamp} = {'physHost' => 
                                        {$msName =>
                                           {'lpar' => 
                                               {$host =>
                                                  {'IO' =>
                                                     {'volumeGroup' => {}
                                                     },
                                                  },
                                               },
                                           },
                                        },
                                     };
         #================================================================================================================
         # Build out the scafolding for the actual data using the hdisks in each volume group
         #================================================================================================================
         my $vgName;
         my %vgMap = ();
         foreach my $line (@vgData)
         {
            if    ($line =~ /^(\S+):/)
            {
               $vgName = $1;
               $graphiteData{$timeStamp}->{'physHost'}->{$msName}->{'lpar'}->{$host}->{'IO' =>}->{'volumeGroup'}->{$vgName}->{'disk'} = {};
            }
            elsif ($line =~ /^(hdisk\d+)/) 
            {
               my $hdisk  = $1;
               
               $graphiteData{$timeStamp}->{'physHost'}->{$msName}->{'lpar'}->{$host}->{'IO' =>}->{'volumeGroup'}->{$vgName}->{'disk'}->{$hdisk} =  {};
               $vgMap{$hdisk} = $vgName;
            }
         }
      
         #================================================================================================================
         # Now add the actual data to the graphite structure
         #================================================================================================================
         my %vgIO=();
         foreach my $line (@ioData)
         {
            if ($line =~ /^(hdisk\d+)\s+(.*)/) 
            {
               my $hdisk   = $1;
               my $ioStats = $2;
               my $vgName  = $vgMap{$hdisk};
               
               my @statValues = split(/\s+/,$ioStats);
               my $bpsRead             = $statValues[3];  if ($bpsRead  =~ /([0-9\.]+)k/i){$bpsRead= $1*1024} elsif($bpsRead  =~ /([0-9\.]+)m/i){$bpsRead= $1*1024*1024} elsif($bpsRead  =~ /([0-9\.]+)g/i){$bpsRead= $1*1024*1024*1204}
               my $bpsWrite            = $statValues[4];  if ($bpsWrite =~ /([0-9\.]+)k/i){$bpsWrite=$1*1024} elsif($bpsWrite =~ /([0-9\.]+)m/i){$bpsWrite=$1*1024*1024} elsif($bpsWrite =~ /([0-9\.]+)g/i){$bpsWrite=$1*1024*1024*1204}
               my $serviceTimeReadAve  = $statValues[6];  if ($serviceTimeReadAve  =~ /([0-9\.])s/i){$serviceTimeReadAve=$1 *1000};
               my $serviceTimeReadMax  = $statValues[8];  if ($serviceTimeReadMax  =~ /([0-9\.])s/i){$serviceTimeReadMax=$1 *1000};
               my $serviceTimeWriteAve = $statValues[12]; if ($serviceTimeWriteAve =~ /([0-9\.])s/i){$serviceTimeWriteAve=$1*1000};
               my $serviceTimeWriteMax = $statValues[14]; if ($serviceTimeWriteMax =~ /([0-9\.])s/i){$serviceTimeWriteMax=$1*1000};
      
               $graphiteData{$timeStamp}->{'physHost'}->{$msName}->{'lpar'}->{$host}->{'IO' =>}->{'volumeGroup'}->{$vgName}->{'disk'}->{$hdisk} =  {'bytesPerSecRead'      => $bpsRead,
                                                                                                                                                    'bytesPerSecWritten'   => $bpsWrite,
                                                                                                                                                    'serviceTimeReadAve'   => $serviceTimeReadAve,
                                                                                                                                                    'serviceTimeWriteAve'  => $serviceTimeWriteAve,
                                                                                                                                                    'serviceTimeReadMax'   => $serviceTimeReadMax,
                                                                                                                                                    'serviceTimeWriteMax'  => $serviceTimeWriteMax,
               #================================================================================================================
               # Roll up individual disk stats into volume group stats
               #================================================================================================================
                                                                                                                                                    };
               if (!defined($vgIO{$vgName})) {$vgIO{$vgName} = {}};
               if (!defined($vgIO{$vgName}->{'count'})) {$vgIO{$vgName}->{'count'} = 1} else {$vgIO{$vgName}->{'count'}++};
               if (!defined($vgIO{$vgName}->{'bytesPerSecRead'}))     {$vgIO{$vgName}->{'bytesPerSecRead'}     = $bpsRead}             else {$vgIO{$vgName}->{'bytesPerSecRead'}     += $bpsRead};
               if (!defined($vgIO{$vgName}->{'bytesPerSecWritten'}))  {$vgIO{$vgName}->{'bytesPerSecWritten'}  = $bpsWrite}            else {$vgIO{$vgName}->{'bytesPerSecWritten'}  += $bpsWrite};
               if (!defined($vgIO{$vgName}->{'serviceTimeReadAve'}))  {$vgIO{$vgName}->{'serviceTimeReadAve'}  = $serviceTimeReadAve}  else {$vgIO{$vgName}->{'serviceTimeReadAve'}  += $serviceTimeReadAve};
               if (!defined($vgIO{$vgName}->{'serviceTimeWriteAve'})) {$vgIO{$vgName}->{'serviceTimeWriteAve'} = $serviceTimeWriteAve} else {$vgIO{$vgName}->{'serviceTimeWriteAve'} += $serviceTimeWriteAve};
               if (!defined($vgIO{$vgName}->{'serviceTimeReadMax'}))  {$vgIO{$vgName}->{'serviceTimeReadMax'}  = $serviceTimeReadMax}  else {$vgIO{$vgName}->{'serviceTimeReadMax'}  = max($serviceTimeReadMax ,$vgIO{$vgName}->{'serviceTimeReadMax'})};
               if (!defined($vgIO{$vgName}->{'serviceTimeWriteMax'})) {$vgIO{$vgName}->{'serviceTimeWriteMax'} = $serviceTimeWriteMax} else {$vgIO{$vgName}->{'serviceTimeWriteMax'} = max($serviceTimeWriteMax,$vgIO{$vgName}->{'serviceTimeWriteMax'})};
            }
            
         }
         
         #================================================================================================================
         # Convert summed averages back to averages then add volumegroup level stats to graphite structure
         #================================================================================================================
         foreach my $vgName (keys(%vgIO))
         {
            if (defined($vgIO{$vgName}->{'count'}) and $vgIO{$vgName}->{'count'} >0)
            {
               $vgIO{$vgName}->{'serviceTimeReadAve'}     /= $vgIO{$vgName}->{'count'};
               $vgIO{$vgName}->{'serviceTimeWriteAve'}    /= $vgIO{$vgName}->{'count'};
            }
            $graphiteData{$timeStamp}->{'physHost'}->{$msName}->{'lpar'}->{$host}->{'IO' =>}->{'volumeGroup'}->{$vgName}->{'vgIO'} =  {'bytesPerSecRead'     => $vgIO{$vgName}->{'bytesPerSecRead'},
                                                                                                                                       'bytesPerSecWritten'  => $vgIO{$vgName}->{'bytesPerSecWritten'},
                                                                                                                                       'serviceTimeReadAve'  => $vgIO{$vgName}->{'serviceTimeReadAve'},
                                                                                                                                       'serviceTimeWriteAve' => $vgIO{$vgName}->{'serviceTimeWriteAve'},
                                                                                                                                       'serviceTimeReadMax'  => $vgIO{$vgName}->{'serviceTimeReadMax'},
                                                                                                                                       'serviceTimeWriteMax' => $vgIO{$vgName}->{'serviceTimeWriteMax'},
                                                                                                                                     };
         }
         #================================================================================================================
         # Send to graphite server
         #================================================================================================================
         $graphite->send(path => $graphite_root, data => \%graphiteData);
         #================================================================================================================
         # Fork ends here
         #================================================================================================================
         $pm->finish; # Terminates the child process
      }
      else
      {
         print "Host $host is not responding to ping\n;";
      }
   }
   $pm->wait_all_children;
   sleep(120);
}
print "Done\n";