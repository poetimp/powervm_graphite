#!/usr/bin/perl
#=========================================================================================================
# Author: Paul Lemmons
# Date: December 2016
# Description: This program uses the IBM HMC REST API to collect
#              performance data. This data is then sent to a Graphite server so that it can be 
#              displayed in the grafana application.
#
# Useful links: HmcRestApi_ReferenceDoc_Release810.0_V1.0.pdf : 
#                  https://www.ibm.com/developerworks/community/groups/service/html/communityview?communityUuid=0196fd8d-7287-4dff-8526-102b5bcf0df5#fullpageWidgetId=W395818bd593b_487f_a7ec_79c3c27093f8&file=567cef95-775a-42a3-bba5-1d19725bd62d
#               POWER8 8247-21L (IBM Power System S812L) Installing, configuring, and managing consoles, terminals, and interfaces HMC REST APIs
#                  http://www.ibm.com/support/knowledgecenter/POWER8/p8ehl/concepts/ApiOverview.htm
#               Blog: Using PCM REST APIs
#                  https://www.ibm.com/developerworks/community/blogs/0196fd8d-7287-4dff-8526-102b5bcf0df5/entry/Using_PCM_REST_APIs?lang=en
#               hmc v8 rest api part 1 curl
#                  https://www.djouxtech.net/posts/hmc-v8-rest-api-part-1-curl/
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

use LWP::UserAgent;
use HTTP::Request::Common;
use Data::Dumper; 
use strict;
use XML::Simple;
use JSON;
use Net::Graphite;
use Date::Manip;

my $VERSION = '1.0';   # Minor updates will not add new datapoints. Major updates will.
my $DEBUG   = 0;       # Makes a lot of noise if turned on but handy for debugging

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

#==============================================================================================================================
# Configuration variables
#==============================================================================================================================
# I don't know about your HMC but we did not purchased a signed cert for it
$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;
$ENV{HTTPS_DEBUG} = 0;
#------------------------------------------------------------------------------------------------------------------------------
# note: To get the above to work on some systems I had to modify the system perl module.
#       This means that if an update occurs to it, this program will likely fail with a 
#       certificate error.
#
#       The change I made is to:
#           /usr/share/perl5/IO/Socket/SSL.pm
#       as folows:
#
#use constant SSL_VERIFY_NONE => Net::SSLeay::VERIFY_NONE();
#use constant SSL_VERIFY_PEER => Net::SSLeay::VERIFY_PEER();
# becomes
#use constant SSL_VERIFY_NONE => 1; # Net::SSLeay::VERIFY_NONE();
#use constant SSL_VERIFY_PEER => 0; # Net::SSLeay::VERIFY_PEER();
#
# and yes, I know it is ugly to have to do that and yes I know that it affects every program that uses it. I believe the issue
# is probably fixed in later releases of the module. 
#------------------------------------------------------------------------------------------------------------------------------

# gotta have rights on hmc...
my $userid   = 'AnHMCUserWithViewPrivs'; # also make sure it is allowed "remote access" which is not obvious in the useid setup
my $password = 'AndItsPassword';


my $hmcHost = 'https://YourHMC.yourbiz.com:12443';
   
my $userAgent = LWP::UserAgent->new;
   $userAgent->add_handler("request_send",  sub { shift->dump; return })   if $DEBUG;
   $userAgent->add_handler("response_done", sub { shift->dump; return })   if $DEBUG;

#==============================================================================================================================
# Global working variables
#==============================================================================================================================
my $response;

#==============================================================================================================================
# Login XML
#==============================================================================================================================
my $xml_Login = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                 <LogonRequest xmlns="http://www.ibm.com/xmlns/systems/power/firmware/web/mc/2012_10/" schemaVersion="V1_4_0">
                    <Metadata>
                       <Atom/>
                    </Metadata>
                       <UserID   kb="CUR" kxe="false">'.$userid.'</UserID>
                       <Password kb="CUR" kxe="false">'.$password.'</Password>
                 </LogonRequest>
                ';

#==============================================================================================================================
# Finally! Let's start coding
#==============================================================================================================================
print "-------------------------------------------------------------------------------------------------\n" if $DEBUG;
print "Response from login\n"                                                                               if $DEBUG;
print "-------------------------------------------------------------------------------------------------\n" if $DEBUG;
$response = $userAgent->put("$hmcHost/rest/api/web/Logon",
                                Content_Type      => "application/vnd.ibm.powervm.web+xml; type=LogonRequest",
                                'Accept'          => "application/vnd.ibm.powervm.web+xml; type=LogonResponse",
                                Content           => $xml_Login);

my $sessionID;
if ($response->is_success)
{
   print $response->content if $DEBUG;
   
   my $SessionInfo = XMLin($response->content);
   $sessionID      = $SessionInfo->{'X-API-Session'}->{'content'};
   
   print "Login Successful\n" if $DEBUG;
}
else
{
   die($response->error_as_HTML);
}

#==============================================================================================================================
# Get PCM preferences
#==============================================================================================================================

print "-------------------------------------------------------------------------------------------------\n" if $DEBUG;
print "Response from get PCM preferences\n"                                                                 if $DEBUG;
print "-------------------------------------------------------------------------------------------------\n" if $DEBUG;
$response = $userAgent->get("$hmcHost/rest/api/pcm/preferences",
                             Content_Type      => "application/atom+xml; charset=UTF-8",
                             'Accept'          => "application/atom+xml; charset=UTF-8",
                             'X-API-Session'   => $sessionID
                             );
my %managedSystem;
if ($response->is_success)
{
   print $response->content if $DEBUG;
   
   my $pcmInfo = XMLin($response->content);
   print Dumper($pcmInfo) if $DEBUG; 
   
   foreach my $system (@{$pcmInfo->{'entry'}->{'content'}->{'ManagementConsolePcmPreference:ManagementConsolePcmPreference'}->{'ManagedSystemPcmPreference'}})
   {
      my $systemName              = $system->{'SystemName'}->{'content'};
      $managedSystem{$systemName} = {'uuid'       => $system->{'Metadata'}->{'Atom'}->{'AtomID'},
                                     'ltmEnabled' => $system->{'LongTermMonitorEnabled'}->{'content'},
                                     'stmEnabled' => $system->{'ShortTermMonitorEnabled'}->{'content'},
                                    };
   }
   
   if ($DEBUG)
   {
      foreach my $systemName(sort(keys(%managedSystem)))
      {
         print $systemName."\t".
               $managedSystem{$systemName}->{'uuid'}."\t".
               $managedSystem{$systemName}->{'ltmEnabled'}."\t".
               $managedSystem{$systemName}->{'stmEnabled'}.
               "\n";
      }
   }
}
else
{
   die($response->error_as_HTML);
}

#==============================================================================================================================
# Get LTM performance Data (Here is where we actuall send data to graphite)
#==============================================================================================================================

print "-------------------------------------------------------------------------------------------------\n" if $DEBUG;
print "Response from get Long Term Metrics \n"                                                              if $DEBUG;
print "-------------------------------------------------------------------------------------------------\n" if $DEBUG;
foreach my $systemName(sort(keys(%managedSystem)))
{
   print "Processing managed system: $systemName\n"  if $DEBUG;
   if ($managedSystem{$systemName}->{'ltmEnabled'} =~ /true/i) # Only try if the long term metrics are collected for this managed system
   {
      $response = $userAgent->get("$hmcHost/rest/api/pcm/ManagedSystem/".$managedSystem{$systemName}->{'uuid'}."/RawMetrics/LongTermMonitor",
                                   Content_Type      => "application/atom+xml; charset=UTF-8",
                                   'Accept'          => "application/atom+xml; charset=UTF-8",
                                   'X-API-Session'   => $sessionID
                                   );
      
      if ($response->is_success)
      {
         print $response->content if $DEBUG;
         my %lparPrev;
         my %graphiteData;
         my $ltmInfo = XMLin($response->content);
         #print Dumper($ltmInfo) if $DEBUG; 
         #---------------------------------------------------------------------------------------------------------------------
         # Before we get too much further here you are going to scratch your head and ask "Why did he do that" in a number of
         # places. Let me tell you about the data that we will be getting.
         # 
         # First interpreting the data is like reading gas or electric meters. You don't have an idea how much gas or 
         # electricity has been used until you second trip out. This is because you measure the deltas between trips to 
         # determine usage. The same applies here. You have to subtract the previous reading from the current reading to 
         # determine what has been consumed. So, we have to keep track of our last reading.
         #
         # Next, the data is not presented in a predictable order. We really want to see in in chronological order so that 
         # we can calculate the deltas correctly.
         #
         # Lastly, things are represented in percentages. They are represented in fractions of a CPU. So, what is actually
         # calculated is the number of CPUs that are used, not the percentage of anything. There is enough information to
         # calculate percentages but in keeping with the data we will be perpetuating that paradigm.
         #
         # Ok... now you can read the code :-)
         #---------------------------------------------------------------------------------------------------------------------
         
         #                  sort  the long time metrics by the URL name. This works to put them in chronological order
         foreach my $entry (sort {$ltmInfo->{'entry'}->{$a}->{'link'}->{'href'} cmp $ltmInfo->{'entry'}->{$b}->{'link'}->{'href'}} keys(%{$ltmInfo->{'entry'}}))
         {
            # We are only interested in the physical metrics, not the IO metrics at this time.
            if ($ltmInfo->{'entry'}->{$entry}->{'link'}->{'href'} =~ /_phyp_/)
            {
               print $ltmInfo->{'entry'}->{$entry}->{'link'}->{'href'}."\n" if $DEBUG;
               $response = $userAgent->get($ltmInfo->{'entry'}->{$entry}->{'link'}->{'href'},
                                            Content_Type      => $ltmInfo->{'entry'}->{$entry}->{'link'}->{'type'},
                                            'Accept'          => $ltmInfo->{'entry'}->{$entry}->{'link'}->{'type'},
                                            'X-API-Session'   => $sessionID
                                            );
               if ($response->is_success)
               {
                  my $perfData = decode_json($response->content);
                  print $response->content if $DEBUG;
                  print Dumper($perfData)  if $DEBUG; 
                  # Do something with the performance data
                  my $timeStamp = UnixDate($perfData->{'systemUtil'}->{'utilSample'}->{'timeStamp'},"%s");
                  
                  if (defined($perfData->{'systemUtil'}->{'utilSample'}->{'lparsUtil'}[0]->{'name'})) # easy test to see if we actually got data
                  {
                      # Collect data for each LPAR sorted by name)
                     foreach my $lpar (sort {$a->{'name'} cmp $b->{'name'}} @{$perfData->{'systemUtil'}->{'utilSample'}->{'lparsUtil'}})
                     {
                        if (defined($lpar->{'name'}))
                        {
                           print "Processing LPAR: $lpar->{'name'}\n" if $DEBUG;
                           if (defined($lparPrev{$lpar->{'name'}})) 
                           {
                              # Here is where we do all of the calculations and send the data to Graphite
                              my $cyclesAvailable = $perfData->{'systemUtil'}->{'utilSample'}->{'timeBasedCycles'} - $lparPrev{$lpar->{'name'}}->{'hostCycles'};
                              my $cpusEntitled    = $lpar->{'processor'}->{'entitledProcCycles'}                   - $lparPrev{$lpar->{'name'}}->{'entitledProcCycles'};
                              my $cpusCapped      = $lpar->{'processor'}->{'utilizedCappedProcCycles'}             - $lparPrev{$lpar->{'name'}}->{'utilizedCappedProcCycles'};
                              my $cpusUnCapped    = $lpar->{'processor'}->{'utilizedUnCappedProcCycles'}           - $lparPrev{$lpar->{'name'}}->{'utilizedUnCappedProcCycles'};
                                 
                              $graphiteData{$timeStamp} = {'physHost' => 
                                                             {$perfData->{'systemUtil'}->{'utilInfo'}->{'name'} =>
                                                                {'processor' =>
                                                                   {
                                                                    'totalProcUnits' => $perfData->{'systemUtil'}->{'utilSample'}->{'processor'}->{'totalProcUnits'},
                                                                   },
                                                                 'memory' =>
                                                                   {
                                                                    'totalMem' => $perfData->{'systemUtil'}->{'utilSample'}->{'memory'}->{'totalMem'},
                                                                   },
                                                                 'lpar' => 
                                                                    {$lpar->{'name'} =>
                                                                       {'memory' => $lpar->{'memory'}->{'logicalMem'},
                                                                        'maxVirtProcs'  => $lpar->{'processor'}->{'maxVirtualProcessors'},
                                                                        'maxProcUnits'  => $lpar->{'processor'}->{'maxProcUnits'},
                                                                        'state'         => $lpar->{'state'},
                                                                        'type'          => $lpar->{'type'},
                                                                        'cpusEntitled'  => ($cpusEntitled/$cyclesAvailable),
                                                                        'cpusUsed'      => ($cpusCapped/$cyclesAvailable)+($cpusUnCapped/$cyclesAvailable),
                                                                       },
                                                                    },
                                                                },
                                                             },
                                                          };
                                                 
                              $graphite->send(path => $graphite_root, data => \%graphiteData);
                              print Dumper(%graphiteData) if $DEBUG;
                              undef %graphiteData;
                           }
                           # capture current which becomes previous next loop
                           $lparPrev{$lpar->{'name'}} = {'hostCycles'                 => $perfData->{'systemUtil'}->{'utilSample'}->{'timeBasedCycles'},
                                                         'entitledProcCycles'         => $lpar->{'processor'}->{'entitledProcCycles'},
                                                         'utilizedCappedProcCycles'   => $lpar->{'processor'}->{'utilizedCappedProcCycles'},
                                                         'utilizedUnCappedProcCycles' => $lpar->{'processor'}->{'utilizedUnCappedProcCycles'},
                                                        };
                        }
                     }
                  }
               }
               else
               {
                  die($response->error_as_HTML);
               }
            }
         }
      }
      else
      {
         die($response->error_as_HTML);
      }
   }
   else
   {
      print "Manage system $systemName skipped, Long Term Metrics not enables\n"  if $DEBUG;
   }
}
print "Done\n"  if $DEBUG; # Nice to have a place to put a breakpoint at the end when debugging
