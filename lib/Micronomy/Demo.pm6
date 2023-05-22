unit module Micronomy::Demo;

use JSON::Fast;
use Micronomy::Cache;
use Micronomy::Calendar;
use Micronomy::Common;

sub get-demo($date) is export {
    trace "Micronomy::Demo.get-demo $date";
    my $today = Date.today;
    my %cache = get-cache("demo");
    %cache<currentDate> = $date;
    %cache<concurrency> = '"card"="demo"';
    %cache<containerInstanceId> = 'demo';

    my ($week, $start-date, $year, $month, $mday) = get-current-week($date);
    %cache<currentWeek> = $start-date.yyyy-mm-dd;

    # find previous week if missing
    if not %cache<weeks>{$year}{$month}{$mday}:exists {
        outer:
        for %cache<weeks>.keys.sort.reverse -> $year2 {
            next if $year2 > $year;
            for %cache<weeks>{$year2}.keys.sort.reverse -> $month2 {
                next if "$year2-$month2" gt "$year-$month";
                for %cache<weeks>{$year2}{$month2}.keys.sort.reverse -> $mday2 {
                    next if "$year2-$month2-$mday2" gt "$year-$month-$mday";
                    trace "copying $year2-$month2-$mday2 (%cache<weeks>{$year2}{$month2}{$mday2}<name>)";
                    %cache<weeks>{$year}{$month}{$mday} = from-json to-json %cache<weeks>{$year2}{$month2}{$mday2};
                    last outer;
                }
            }
        }
        if not %cache<weeks>{$year}{$month}{$mday}:exists {
            trace "copying 1970-01-05 (2)";
            my %source = get-cache("demo-source");
            %cache<weeks>{$year}{$month}{$mday} = from-json to-json %source<weeks><1970><01><05>;
            %cache<jobs> //= from-json to-json %source<jobs>;
        }

        # don't copy temporary rows
        my @keep;
        for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
            @keep.push(%row) unless %row<temp>;
        }
        %cache<weeks>{$year}{$month}{$mday}<rows> = @keep;

        # don't add future hours
        if $start-date >= $today.truncated-to('week') {
            for 1..7 -> $wday {
                if $start-date.later(days => $wday-1) >= $today {
                    for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
                        %row<hours>{$wday}:delete
                    }
                }
            }
        }

        %cache = sum-up-demo(%cache<currentWeek>, %cache);
    }

    # auto approve old weeks
    if $start-date < $today.truncated-to('week') {
        %cache<weeks>{$year}{$month}{$mday}<state> = 2;
    }

    %cache<weeks>{$year}{$month}{$mday}<name> = $week;
    return %cache;
}

sub set-demo(%parameters, $row) is export {
    trace "Micronomy::Demo.set-demo", "demo";
    my %cache = get-demo(%parameters<date>);

    my ($week-name, $start-date, $year, $month, $mday) = get-current-week(%parameters<date>);

    for 1..7 -> $wday  {
        my $hours = %parameters{"hours-$row-$wday"} || "0";
        $hours = +$hours.subst(",", ".");
        %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<hours>{$$wday} = $hours;;
    }
    set-cache(%cache);
    return %cache;
}

sub set-demo-filler(%parameters) is export {
    trace "Micronomy::Demo.set-demo-filler";
    my %content = get-demo(%parameters<date>);
    my $filler = %parameters<filler> // -1;
    %content = sum-up-demo(%parameters<date>, %content, $filler);
    set-cache(%content);
}

sub add-demo-data($action, $source, $target is copy, %parameters) is export {
    trace "add demo data [$source -> $target] " ~ %parameters{"position-$source"}, "demo";

    my ($week-name, $start-date, $year, $month, $mday) = get-current-week(%parameters<date>);
    my %cache = get-demo(%parameters<date>);
    my %row;
    %row<job> = %parameters{"job-$source"} if %parameters{"job-$source"};
    my $task = %parameters{"task-$source"} // "";
    %row<task> = $task if %parameters{"task-$source"};
    %row<temp> = True unless %parameters{"keep-$source"};
    %row<concurrency> = '"card"="demo", "table"="demo"';
    %row<state> = "";
    if %parameters{"position-$source"} ne $source and %parameters{"hours-$source"}:exists {
        my $day = 0;
        my $total = 0;
        for %parameters{"hours-$source"}.split(";") -> $hours {
            $day++;
            %row<hours>{$day} = $hours if $hours ne "0";
            $total += $hours;
        }
        %row<total> = $total if $total != 0;
    }

    my $max = %cache<weeks>{$year}{$month}{$mday}<rows>.elems;
    $target = min($max, $target);
    if $action eq "add" {
        %cache<weeks>{$year}{$month}{$mday}<rows>.splice($target, 0, %row);
    } else {
        %cache<weeks>{$year}{$month}{$mday}<rows>[$target] = %row;
    }

    unless %cache<jobs>{%row<job>}<tasks>{$task}:exists {
        unless %cache<jobs>{%row<job>}:exists {
            my %favorites = get-cache("demo-faves");
            for @(%favorites<panes><table><records>) -> %data {
                if %data<data><jobnumber> == %row<job> {
                    %cache<jobs>{%row<job>}<name> = %data<data><jobnamevar>;
                    last;
                }
            }
        }
        if $task {
            my %tasks = get-cache("demo-tasks");
            for @(%tasks{%row<job>}) -> %task {
                if %task<number> == $task {
                    %cache<jobs>{%row<job>}<tasks>{$task} = %task<name>;
                    last;
                }
            }
        }
    }

    set-cache(%cache);
}

sub delete-demo-row($target, %parameters) is export {
    trace "delete demo row $target", "demo";
    my ($week-name, $start-date, $year, $month, $mday) = get-current-week(%parameters<date>);
    my %cache = get-demo($start-date);
    %cache<weeks>{$year}{$month}{$mday}<rows>.splice($target, 1);
    set-cache(%cache);
}

# internal subroutines

sub sum-up-demo(Str $date, %cache, $filler = -1) {
    trace "sub sum-up-demo $date, $filler";
    my ($week-name, $start-date, $year, $month, $mday) = get-current-week($date);
    my $start-day = $start-date.day-of-week;

    %cache<weeks>{$year}{$month}{$mday}<totals><fixed> = 0;
    %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> = 0;
    %cache<weeks>{$year}{$month}{$mday}<totals><overtime> = 0;
    %cache<weeks>{$year}{$month}{$mday}<totals><reported> = 0;

    for 1..7 -> $wday {
        my $fixed;
        my $skipped = False;
        my $day = $start-date.later(days => $wday - $start-day);
        if $wday < $start-day or $day.month != $start-date.month {
            # skip out of week data
            $skipped = True;
            %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}:delete;
        } else {
            $fixed = expected($day);
            %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<fixed> = $fixed;
        }

        my $rowNum = -1;
        my $invoiceable = 0;
        my $reported = 0;
        for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
            if ($skipped or not %row<hours>{$wday}) {
                # skip out of week data or zero hours
                %row<hours>{$wday}:delete;
            } elsif %row<task> ne "102" { # don't sum "Beredskap"
                $invoiceable += %row<hours>{$wday} if %row<job> eq <12020002 12020003>.any;
                $reported += %row<hours>{$wday};
            }
        }
        next if $skipped;

        %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<reported> = $reported;
        %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<invoiceable> = $invoiceable;
        my $overtime = $reported - $fixed;
        %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<overtime> = $overtime;

        %cache<weeks>{$year}{$month}{$mday}<totals><fixed> += $fixed;
        %cache<weeks>{$year}{$month}{$mday}<totals><invoiceable> += $invoiceable;
        %cache<weeks>{$year}{$month}{$mday}<totals><reported> += $reported;
        %cache<weeks>{$year}{$month}{$mday}<totals><overtime> += $overtime;
    }
    for @(%cache<weeks>{$year}{$month}{$mday}<rows>) -> %row {
        %row<total> = 0;
        for 1..7 -> $wday {
            %row<total> += %row<hours>{$wday} // 0;
        }
    }

    if $filler >= 0 {
        my %parameters;
        set-filler(%cache, %parameters, $filler);
        for 1..7 -> $wday {
            my $previous = %cache<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$wday} // 0;
            my $compensation = %parameters{"hours-$filler-$wday"};
            %cache<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$wday} = $compensation;
            if $compensation != $previous {
                $compensation -= $previous;
                %cache<weeks>{$year}{$month}{$mday}<rows>[$filler]<total> += $compensation;
                %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<reported> += $compensation;
                %cache<weeks>{$year}{$month}{$mday}<totals><days>{$wday}<overtime> += $compensation;
                %cache<weeks>{$year}{$month}{$mday}<totals><reported> += $compensation;
                %cache<weeks>{$year}{$month}{$mday}<totals><overtime> += $compensation;
            }
        }
    }
    return %cache;
}

sub expected($day) {
    return 0 if $day.day-of-week > 5;
    given sprintf "%02d%02d", $day.month, $day.day {
        when "0101"                   { return 0; }  # Nyårsdagen
        when "0105"                   { return 6; }  # 12-dag Jul
        when "0106"                   { return 0; }  # 13-dag Jul
        when easter($day.year, -3)    { return 4; }  # Skärtorsdag
        when easter($day.year, -2)    { return 0; }  # Långfredag
        when easter($day.year, -1)    { return 0; }  # Påskafton
        when easter($day.year)        { return 0; }  # Påskdagen
        when easter($day.year,  1)    { return 0; }  # Annandag Påsk
        when "0430"                   { return 4; }  # Valborg
        when "0501"                   { return 0; }  # 1:a Maj
        when easter($day.year, 39)    { return 0; }  # Kristi Himmelfärdsdag
        when easter($day.year, 40)    { return 0; }  # klämdag
        when easter($day.year, 48)    { return 0; }  # Pingstafton
        when easter($day.year, 49)    { return 0; }  # Pingstdagen
        when "0606"                   { return 0; }  # Nationaldagen
        when midsummer($day.year, -1) { return 0; }  # Midsommarafton
        when midsummer($day.year)     { return 0; }  # Midsommardagen
        when allsaints($day.year, -1) { return 4; }  # Allhelgonaafton
        when allsaints($day.year)     { return 0; }  # Alla Helgons Dag
        when "1223"                   { return 6; }  # dan före dopparedan
        when "1224"                   { return 0; }  # Julafton
        when "1225"                   { return 0; }  # Juldagen
        when "1226"                   { return 0; }  # Annandag Jul
        when "1227"                   { return 0; }  # mellandag
        when "1228"                   { return 0; }  # mellandag
        when "1229"                   { return 0; }  # mellandag
        when "1230"                   { return 0; }  # mellandag
        when "1231"                   { return 0; }  # Nyårsafton
        default { return 8; }
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
