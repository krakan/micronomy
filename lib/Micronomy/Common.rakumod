unit module Micronomy::Common;

use Cro::HTTP::Client;
use Digest::MD5;
use experimental :pack;

sub get-header($response, $header) is export {
    for $response.headers -> $key {
        return $key.value if $key.name.lc eq $header.lc;
    }
}

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
    say "$now  $session:{$*THREAD.id}  $message";
}

sub error($exception, $token = '', $label = 'error') is export {
    trace "$label: {$exception.Str}", $token;
    for $exception.backtrace.grep(*.file.contains('micronomy')).grep(*.subname) -> $trace {
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
