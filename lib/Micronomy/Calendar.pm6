unit module Micronomy::Calendar;

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
        given my ($hours,$daytype) = redday($tmp) {
            when 6, $daytype ne "Helg" {@arrayofdates.push(@($tmp, 6, $daytype));} #quarter day
            when 4, $daytype ne "Helg"  {@arrayofdates.push(@($tmp, 4, $daytype));} #half day
            when 0, $daytype ne "Helg"  {@arrayofdates.push(@($tmp, 0, $daytype));} #full day
        }
    }
    @arrayofdates, $date; #sending: [(2021-01-01 0 "Nyårsdagen - Init ledig dag"), (2021-01-05 6 "Trettondagsafton - Init ledig dag")...], 2021-01-01
}

#sub calendargenerator(@arrayofdates, $date){
sub calendargenerator($querydate) is export {
    my $list = initreddaygenerator($querydate);
    trace $list;
    #@list = [[(2021-01-01 0 "Nyårsdagen - Init ledig dag")(2021-01-05 6 "Trettondagsafton - Init ledig dag")...]2021-01-01]
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
        my $dayhours = @pair[1];
        my $daytype = @pair[2];
        my $dtstart = "";
        my $dtend ="";
        my $uid = "";
        my $summary ="";
        my $dayafter = $startdate + 1;
        given $dayhours {
            when 6 {
                $uid = "Init-Micronomy-" ~ $startdate.year().Str ~ "-" ~ $counter.Str ~ "\r\n";
                $summary = sprintf "%s\r\n", $daytype;
                $dtstart = sprintf "%04d%02d%02d%s", $startdate.year, $startdate.month, $startdate.day, "T150000\r\n";
                $dtend = sprintf "%04d%02d%02d%s", $dayafter.year, $dayafter.month, $dayafter.day, "T000000\r\n";
            } 
            when 4 {
                $uid = "Init-Micronomy-" ~ $startdate.year().Str ~ "-" ~ $counter.Str ~ "\r\n";
                $summary = sprintf "%s\r\n", $daytype;
                $dtstart = sprintf "%04d%02d%02d%s", $startdate.year, $startdate.month, $startdate.day, "T130000\r\n";
                $dtend = sprintf "%04d%02d%02d%s", $dayafter.year, $dayafter.month, $dayafter.day, "T000000\r\n";
            } 
            when 0 {
                $uid = "Init-Micronomy-" ~ $startdate.year().Str ~ "-" ~ $counter.Str ~ "\r\n";
                $summary = sprintf "%s\r\n", $daytype;
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

    #sends a string that is an ics string shhort example of what it looks like here.
    #BEGIN:VCALENDAR
    #PRODID:Init-Micronomy-2023
    #VERSION:2.0
    #BEGIN:VEVENT
    #UID:Init-Micronomy-2022-1
    #DTSTAMP:20220101T150000
    #DTSTART:20220105T150000
    #DTEND:20220106T000000
    #SUMMARY:Trettondagsafton
    #END:VEVENT
    #END:VCALENDAR

}

sub redday($day){
    given sprintf "%02d%02d", $day.month, $day.day {
        when "0101"                   { return 0, "Nyårsdagen - Init ledig dag"; }  # Nyårsdagen
        when "0105"                   { return 6, "Trettondagsafton - Init ledig dag"; }  # 12-dag Jul
        when "0106"                   { return 0, "Trettondagjul - Init ledig dag"; }  # 13-dag Jul
        when easter($day.year, -3)    { return 4, "Skärtorsdag - Init ledig dag"; }  # Skärtorsdag
        when easter($day.year, -2)    { return 0, "Långfredag - Init ledig dag"; }  # Långfredag
        when easter($day.year, -1)    { return 0, "Påskafton - Init ledig dag"; }  # Påskafton
        when easter($day.year)        { return 0, "Påskdagen - Init ledig dag"; }  # Påskdagen
        when easter($day.year,  1)    { return 0, "Annandag påsk - Init ledig dag"; }  # Annandag Påsk
        when "0430"                   { return 4, "Valborg - Init ledig dag"; }  # Valborg
        when "0501"                   { return 0, "Första Maj - Init ledig dag"; }  # 1:a Maj
        when easter($day.year, 39)    { return 0, "Kristi himmelsfärdsdag - Init ledig dag"; }  # Kristi Himmelfärdsdag
        when easter($day.year, 40)    {
                                        #return 8 , "Vardag - Init ledig dag"if $day.day-of-week != 5; #onödigt eftersom kristi flygare alltid är på en torsdag.
                                        return 0, "Fredag efter Kristi himmelsfärdsdag - Init ledig dag"; #klämdag
        }
        when easter($day.year, 48)    { return 0, "Pingstafton - Init ledig dag"; }  # Pingstafton
        when easter($day.year, 49)    { return 0, "Pingstdagen - Init ledig dag"; }  # Pingstdagen
        when "0606"                   { return 0, "Nationaldagen - Init ledig dag"; }  # Nationaldagen
        when midsummer($day.year, -1) { return 0, "Midsommarafton - Init ledig dag"; }  # Midsommarafton
        when midsummer($day.year)     { return 0, "Midsommardagen - Init ledig dag"; }  # Midsommardagen
        when allsaints($day.year, -1) { return 4, "Allhelgonaafton - Init ledig dag"; }  # Allhelgonaafton
        when allsaints($day.year)     { return 0, "Alla helgons dag - Init ledig dag"; }  # Alla Helgons Dag
        when "1223"                   { return 6, "Dagen före dopparedagen - Init ledig dag"; }  # dan före dopparedan
        when "1224"                   { return 0, "Julafton - Init ledig dag"; }  # Julafton
        when "1225"                   { return 0, "Juldagen - Init ledig dag"; }  # Juldagen
        when "1226"                   { return 0, "Annandag jul - Init ledig dag"; }  # Annandag Jul
        when "1227"                   { return 0, "Mellandag - Init ledig dag"; }  # mellandag
        when "1228"                   { return 0, "Mellandag - Init ledig dag"; }  # mellandag
        when "1229"                   { return 0, "Mellandag - Init ledig dag"; }  # mellandag
        when "1230"                   { return 0, "Mellandag - Init ledig dag"; }  # mellandag
        when "1231"                   { return 0, "Nyårsafton - Init ledig dag"; }  # Nyårsafton
        default {
                                        return 0, "Helg - Init ledig dag" if $day.day-of-week > 5;
                                        return 8, "Vardag";
        }
    }
}

sub easter(Int $year, Int $diff = 0) {
    # Meeus/Jones/Butcher
    my $a = $year mod 19;
    my $b = $year div 100;
    my $c = $year mod 100;
    my $d = $b div 4;
    my $e = $b mod 4;
    my $f = ($b + 8) div 25;
    my $g = ($b - $f + 1) div 3;
    my $h = (19*$a + $b - $d - $g + 15) mod 30;
    my $i = $c div 4 ;
    my $k = $c mod 4 ;
    my $l = (32 + 2*$e + 2*$i - $h - $k) mod 7 ;
    my $m = ($a + 11*$h + 22*$l) div 451 ;
    my $month = ($h + $l - 7*$m + 114) div 31 ;
    my $day = (($h + $l - 7*$m + 114) mod 31) + 1;
    my $fmt = { sprintf "%02d%02d", .month, .day };
    my $date = Date.new($year, $month, $day, formatter => $fmt).later(days => $diff);
    return $date.Str;
}

sub floating-date(Int $year, Int $month, Int $mday, Int $wday, Int :$count = 1, Int :$diff = 0) {
    # $diff days after $count:th $wday on or after $year-$month-$mday
    my $fmt = { sprintf "%02d%02d", .month, .day };
    my $origin = Date.new(sprintf("%d-%02d-%02d", $year, $month, $mday), formatter => $fmt);
    my $oday = $origin.day-of-week;
    my $later = (7 - ($oday - $wday) % 7) % 7;
    $later += ($count - 1) * 7;
    $later += $diff;
    return  $origin.later(days => $later).Str;
}

sub midsummer($year, $diff = 0) {
    # 1st Sat on/after 20 June
    return floating-date $year, 6, 20, 6, :$diff;
}

sub allsaints($year, $diff = 0) {
    # 1st Sat on/after 31 Oct
    return floating-date $year, 10, 31, 6, :$diff;
}

