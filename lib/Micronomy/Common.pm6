unit module Micronomy::Common;

use Digest::MD5;

sub trace($message, $token = '') is export {
    my $now = DateTime.now(
        formatter => { sprintf "%4d-%02d-%02d %02d:%02d:%06.3f",
                       .year, .month, .day, .hour, .minute, .second });
    my $session = $token ?? Digest::MD5.md5_hex($token).substr(24) !! '-';
    say "$now  $session  $message";
}

sub title(Str $job, Str $task --> Str) is export {
    "$task / $job";
}

sub get-current-week($date is copy) is export {
    $date = Date.new($date);
    my $week = $date.week-number;
    my $monday = $date.truncated-to("week");
    my $sunday = $monday.later(days => 6);
    my $start-date = $monday;
    if $monday.month == $date.month != $sunday.month {
        $week ~= "A";
    } elsif $monday.month != $date.month == $sunday.month {
        $week ~= "B";
        $start-date = $date.truncated-to("month");
    }

    my $year = sprintf "%4d", $start-date.year;
    my $month = sprintf "%02d", $start-date.month;
    my $mday = sprintf "%02d", $start-date.day;

    return $week, $start-date, $year, $month, $mday;
}

sub set-filler(%content, %parameters, $filler --> Bool) is export {
    trace "set-filler $filler";
    return False if $filler < 0;
    return False unless %content<weeks>:exists;

    my ($week, $start-date, $year, $month, $mday) = get-current-week(%content<currentWeek>);

    my $previous = %content<weeks>{$year}{$month}{$mday}<rows>[$filler]<total> // 0;
    my $fixed = %content<weeks>{$year}{$month}{$mday}<totals><fixed> // 0;
    my $reported = %content<weeks>{$year}{$month}{$mday}<totals><reported> // 0;
    my $total = $fixed - $reported + $previous;

    for (1..7).sort(
        {
            (%content<weeks>{$year}{$month}{$mday}<totals><days>{$_}<overtime> // 0)
            -
            (%content<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$_} // 0)
        }
    ) -> $day  {
        my $previous = %content<weeks>{$year}{$month}{$mday}<rows>[$filler]<hours>{$day} // 0;
        my $overtime = %content<weeks>{$year}{$month}{$mday}<totals><days>{$day}<overtime> // 0;

        $overtime = $previous - $overtime;
        $overtime = $total if $overtime > $total;
        $overtime = 0 if $overtime < 0;

        trace "filling day $day with $overtime";
        %parameters{"hours-$filler-$day"} = $overtime;
        $total -= $overtime;
    }
    return True;
}
