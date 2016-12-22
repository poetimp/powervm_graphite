#!/usr/bin/perl -w
#=========================================================================================================
# Author: Paul Lemmons
# Date: December 2016
# Description: This program will query the whisper database used by graphite to insure a steady flow of data
#              into the database. It does this by checking for the existance of spcific endpoint data that 
#              should have been collected within the last hour.
#
#=========================================================================================================
use strict;
use LWP::UserAgent;
use JSON;
#-----------------------------------------------------------------------------------------------
# Instanciate communication modules
#-----------------------------------------------------------------------------------------------
my $ua       = new LWP::UserAgent();

#-----------------------------------------------------------------------------------------------
# The connection information for the graphite/whisper datbase server
#-----------------------------------------------------------------------------------------------
my $graphiteProt   = 'http';
my $graphiteHost   = 'yourhost.yourbiz.com';
my $graphitePort   = '81';

#-----------------------------------------------------------------------------------------------
# A list of endpoint data (i.e. the last leaf in the tree of data) to check to insure that data
# has been written in the last hour. The easiest way to get these strings is to connect to the 
# graphite browser at http://tpperfboard:81 and drill to a leaf. Then add it to get graph and 
# then edit the graph data. Copy and then paste here. Replace all variable data with *'s in the
# string.
#-----------------------------------------------------------------------------------------------
my @collectorPoint = ('carbon.agents.tpperfboard-a.creates',
                      'esxprefix.*.esx.*.cpu.idle_millisecond_summation',
                      'esxprefix.*.vm.*.cpu.idle_millisecond_summation',
                      'netapp.capacity.*.*.node.*.aggr.*.compression_space_savings',
                      'netapp.capacity.*.*.svm.*.vol_summary.actual_volume_size',
                      'netapp.perf.*.*.node.*.aggr.*.plex0.cp_read_chain',
                      'powervm.physHost.*.lpar.*.cpusEntitled',
                      'powervm.physHost.*.lpar.*.IO.volumeGroup.*.vgIO.bytesPerSecRead',
                      );

#-----------------------------------------------------------------------------------------------
# try to get the data for each collector mentioned above. Report if any are missing data
#-----------------------------------------------------------------------------------------------
foreach my $cp (@collectorPoint)
{ 
   my $url      = "$graphiteProt://$graphiteHost:$graphitePort/render?target=$cp&format=json&from=-1hours";
   my $response = $ua->post($url, "Content-Type"=>"application/json");
   
   if ( $response->is_success() ) 
   {
      my $content  = $response->content;
      my $jsonresp = decode_json($content);
      if (scalar(@{$jsonresp}) > 0)
      {
         foreach my $target (@{$jsonresp})
         {
            my $count = scalar(@{$target->{'datapoints'}});
            if ($count <= 0)
            {
               do_warn("$cp has no data point during the past hour\n");
            }
         }
      }
      else
      {
         print "$cp has no data point during the past hour\n";
      }
   }
   else
   {
      die("Unable to retrieve data from the graphite server at: $graphiteHost on port $graphitePort\n");
   }
}
