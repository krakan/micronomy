unit module Micronomy::Common;

use Cro::HTTP::Client;
use Digest::MD5;
use experimental :pack;

sub call-url($url, :%auth, :%headers, :$body, :$method, :$timeout is copy = 2) is export {
    my $retries = 10;
    my $token = %headers<Authorization>;
    $token = $token.split(' ')[1] if $token;
    for 0 .. $retries -> $wait {
        try {
            sleep $wait/10;
            my $request;
            if $method and $method eq 'delete' {
                $request = Cro::HTTP::Client.delete($url, :%headers);
            } elsif $body {
                $request = Cro::HTTP::Client.post($url, :%headers, :$body);
            } elsif defined %headers<Content-Length> {
                $request = Cro::HTTP::Client.post($url, :%headers);
            } elsif %auth {
                $request = Cro::HTTP::Client.get($url, :%auth, :%headers);
            } else {
                $request = Cro::HTTP::Client.get($url, :%headers);
            }
            await Promise.anyof($request, Promise.in($timeout));
            unless $request {
                trace sprintf("{whodunit()} timeout #$wait %.1fs", $timeout), $token;
                $timeout += 0.5;
                next;
            }
            my $response = await $request;
            return $response;
        }
        if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries { # 404 Not Found - probably not true - try again
            trace "{whodunit()} received {$!.response.status} - retrying [{$wait+1}/$retries]", $token;
        } else {
            trace "{whodunit()} received {$!.response.status}", $token;
            die $!;
        }
    }
    trace "{whodunit()} timed out too many times", $token;
    return {};
}

sub whodunit() {
    # subs are (Backtrace.new, this, callee, caller, ...)
    my $caller = Backtrace.new.grep(*.subname)[3];
    return "{$caller.subname}:{$caller.line}";
}

sub trace($message, $token = '') is export {
    my $now = DateTime.now(
        formatter => { sprintf "%4d-%02d-%02d %02d:%02d:%06.3f",
                       .year, .month, .day, .hour, .minute, .second });
    my $session = $token ?? md5($token).unpack("H*").substr(24) !! '-';
    say "$now  $session  $message";
}

sub error($exception, $token = '') is export {
    trace "ERROR: {$exception.Str}", $token;
    for $exception.backtrace.grep(*.file.contains('micronomy')).grep(*.subname).reverse -> $trace {
        my $file = $trace.file.split("/")[*-1].split(" ")[0];
        trace "-> $file:{$trace.line}  {$trace.subname}()", $token;
    }
}

sub title(Str $job, Str $task --> Str) is export {
    "$task / $job";
}

sub get-current-week($date is copy) is export {
    $date = $date ?? Date.new($date) !! Date.today;
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
