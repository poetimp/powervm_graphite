#!/usr/bin/perl

# All LPARs on a managed system have the same serial number. So this is a simple lookup table
# that will report which managed system I am running on. It would, of course, be updated to 
# represent your facility.

chomp($serialNum=`uname -m`);

# Make sure case of managed hosts mach what is in the HMC. 
# And for goodness sake don't name your manage systems after the 12 dwarves!

if    ($serialNum=~/00820192ABCD/){print "Sleepy\n"}
elsif ($serialNum=~/00AB30CF4670/){print "Dopey\n"}
elsif ($serialNum=~/00DEADBEEF01/){print "Grumpy\n"}
else  {print "ERROR: No LPAR with the serial number $serialNum was found\n"}

