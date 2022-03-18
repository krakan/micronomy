unit module Micronomy::Calendar;

use Micronomy::Demo;
use Micronomy::Cache;
use Micronomy::Common;

sub initreddaygenerator($requestedyear) {
    #iterates over a year and produces init red days. $requested should be YYYY-MM-DD and a Date class.
    my $date = $requestedyear.truncated-to('year'); #YYYY-01-01 to start iteration on jan frst.
    my @arrayofdates; 
    my $roof = 0;
    if $date.is-leap-year {
        $roof = 366;
    }
    else {
        $roof = 365;
    }
    loop (my $i = 0; $i < $roof; $i++ ){
        my $tmp = $date +$i; 
                #call for expected($date) as this will return work hours and inform of what kind of day it is.
                given my $val = expected($tmp) {
                        when 6 {@arrayofdates.push(@($tmp, 6));} #quarter day
                        when 4 {@arrayofdates.push(@($tmp, 4));} #half day
                        when 0 {@arrayofdates.push(@($tmp, 0));} #full day
                }
    }
    @arrayofdates, $date; #sending: [2021-01-01, 2021-01-05...], 2021-01-01
}

#sub calendargenerator(@arrayofdates, $date){
sub calendargenerator($querydate) is export {
    my $list = initreddaygenerator($querydate);
    #@list = [[(2021-01-01 0)(2021-01-05 6)]2021-01-01]
    #@arrayofdates = [(2021-01-01 0) (2021-01-05 6)...]
    #$date = 2021-01-01
    my @arrayofdates = $list[0];
    my $date = $list[1];
    my $calendarstring = ""; 
    my $counter = 0;
    my $prodid = "Init-Micronomy-" ~ $date.year.Str ~ "\r\n"; #part of vcalendar
    my $version = "2.0\r\n"; #part of vcalendar
    $calendarstring = $calendarstring ~ "BEGIN:VCALENDAR\r\n";
    $calendarstring = $calendarstring ~ "PRODID:" ~ $prodid;
    $calendarstring = $calendarstring ~ "VERSION:" ~ $version; 
    for @arrayofdates -> @pair {
        $counter++;
        #@pair  = (YYYY-MM-DD, H) where H is quarrter/half/full day of work. see initreddaygenerator.
        my $dtstamp = sprintf "%04d%02d%02d%s", $date.year, $date.month, $date.day, "T150000\r\n";
        my $startdate = @pair[0];
        my $daytype = @pair[1];
        my $dtstart = "";
        my $dtend ="";
        my $uid = "";
        my $summary ="";
        my $dayafter = $startdate + 1;
        given $daytype {
            when 6 {
                $uid = "Init-Micronomy-" ~ $startdate.year().Str ~ "-" ~ $counter.Str ~ "\r\n";
                $summary = "Quarter red day\r\n";
                $dtstart = sprintf "%04d%02d%02d%s", $startdate.year, $startdate.month, $startdate.day, "T150000\r\n";
                $dtend = sprintf "%04d%02d%02d%s", $dayafter.year, $dayafter.month, $dayafter.day, "T000000\r\n";
            } 
            when 4 {
                $uid = "Init-Micronomy-" ~ $startdate.year().Str ~ "-" ~ $counter.Str ~ "\r\n";
                $summary = "half red day\r\n";
                $dtstart = sprintf "%04d%02d%02d%s", $startdate.year, $startdate.month, $startdate.day, "T130000\r\n";
                $dtend = sprintf "%04d%02d%02d%s", $dayafter.year, $dayafter.month, $dayafter.day, "T000000\r\n";
            } 
            when 0 {
                $uid = "Init-Micronomy-" ~ $startdate.year().Str ~ "-" ~ $counter.Str ~ "\r\n";
                $summary = "Full red day\r\n";
                $dtstart = sprintf "%04d%02d%02d%s", $startdate.year, $startdate.month, $startdate.day, "T000000\r\n";
                $dtend = sprintf "%04d%02d%02d%s", $dayafter.year, $dayafter.month, $dayafter.day, "T000000\r\n";
            } 
        }
        $calendarstring = $calendarstring ~ "BEGIN:VEVENT\r\n";
        $calendarstring = $calendarstring ~ "UID:" ~ $uid;
        $calendarstring = $calendarstring ~ "DTSTAMP:" ~ $dtstamp;
        $calendarstring = $calendarstring ~ "DTSTART:" ~$dtstart; 
        $calendarstring = $calendarstring ~ "DTEND:" ~ $dtend;
        $calendarstring = $calendarstring ~ "SUMMARY:" ~ $summary; 
        $calendarstring = $calendarstring ~ "END:VEVENT\r\n";
    }
    $calendarstring = $calendarstring ~ "END:VCALENDAR\r\n";
    return $calendarstring;
}
