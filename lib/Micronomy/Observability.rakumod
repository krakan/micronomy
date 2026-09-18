unit module Micronomy::Observability;

# Minimal, dependency-free instrumentation: liveness/readiness checks and a
# hand-rolled Prometheus text exporter. There is no maintained Prometheus
# client for Raku, and the metric set here is small enough that a library
# would add more weight than it saves.

my $start-time = now;
my $lock = Lock.new;

my %http-requests;       # {route}{method}{status} => count
my %http-duration-sum;   # {route} => total seconds
my %http-duration-count; # {route} => count
my %maconomy-calls;      # {outcome} => count
my $cache-errors = 0;

sub record-http-request(Str $route, Str $method, Str $status, Real $duration) is export {
    $lock.protect: {
        %http-requests{$route}{$method}{$status}++;
        %http-duration-sum{$route} += $duration;
        %http-duration-count{$route}++;
    }
}

sub record-maconomy-call(Str $outcome) is export {
    $lock.protect: { %maconomy-calls{$outcome}++; }
}

sub record-cache-error() is export {
    $lock.protect: { $cache-errors++; }
}

sub check-liveness() is export {
    # Reaching this point means the Cro reactor is scheduling requests, which
    # is all "is the process alive" needs to mean. No external calls here -
    # liveness must never depend on Maconomy or anything else external.
    return True;
}

sub cache-writable() is export {
    my $dir = $*PROGRAM-NAME;
    $dir ~~ s/<-[^\/]>* $//;
    $dir ||= '.';
    my $probe = "$dir/resources/.readyz-probe";
    try {
        spurt $probe, "ok";
        unlink $probe;
    }
    return $! ?? (False, "cache directory not writable ({$!.message})") !! (True, "");
}

sub check-readiness() is export {
    my ($ok, $reason) = cache-writable();
    return %(ready => $ok, reason => $reason);
}

# Both of these read from /proc, so they are Linux-only (which is what the
# container runs); elsewhere they quietly report 0 rather than fail metrics
# collection for a couple of gauges.

sub process-memory-bytes() {
    my $status = try slurp "/proc/self/status";
    return 0 unless $status and $status ~~ /'VmRSS:' \s* (\d+) \s* 'kB'/;
    return +$0 * 1024;
}

sub process-cpu-seconds() {
    my $stat = try slurp "/proc/self/stat";
    return 0e0 unless $stat;
    # The comm field (2nd) is the only one that can contain spaces/parens, so
    # split after the *last* ')' rather than assuming fixed field positions.
    my $paren = $stat.rindex(')') // return 0e0;
    my @fields = $stat.substr($paren + 2).split(' ');
    # utime/stime are fields 14 and 15 of /proc/pid/stat; @fields[0] here is
    # field 3 (state), so they land at indices 11 and 12.
    my constant $CLK-TCK = 100; # USER_HZ has been 100 on Linux for decades
    return ((@fields[11] // 0).Int + (@fields[12] // 0).Int) / $CLK-TCK;
}

sub render-metrics() is export {
    my $out = "";
    $lock.protect: {
        $out ~= "# HELP micronomy_http_requests_total Total number of HTTP requests.\n";
        $out ~= "# TYPE micronomy_http_requests_total counter\n";
        for %http-requests.keys.sort -> $route {
            for %http-requests{$route}.keys.sort -> $method {
                for %http-requests{$route}{$method}.keys.sort -> $status {
                    my $count = %http-requests{$route}{$method}{$status};
                    $out ~= "micronomy_http_requests_total\{route=\"$route\",method=\"$method\",status=\"$status\"\} $count\n";
                }
            }
        }

        $out ~= "# HELP micronomy_http_request_duration_seconds_sum Total time spent handling requests, in seconds.\n";
        $out ~= "# TYPE micronomy_http_request_duration_seconds_sum counter\n";
        for %http-duration-sum.keys.sort -> $route {
            my $sum = %http-duration-sum{$route};
            $out ~= "micronomy_http_request_duration_seconds_sum\{route=\"$route\"\} {$sum.fmt('%.6f')}\n";
        }
        $out ~= "# HELP micronomy_http_request_duration_seconds_count Number of requests observed for duration.\n";
        $out ~= "# TYPE micronomy_http_request_duration_seconds_count counter\n";
        for %http-duration-count.keys.sort -> $route {
            $out ~= "micronomy_http_request_duration_seconds_count\{route=\"$route\"\} {%http-duration-count{$route}}\n";
        }

        $out ~= "# HELP micronomy_maconomy_calls_total Calls made to the Maconomy API, by outcome.\n";
        $out ~= "# TYPE micronomy_maconomy_calls_total counter\n";
        for <ok timeout error retry_404> -> $outcome {
            my $count = %maconomy-calls{$outcome} // 0;
            $out ~= "micronomy_maconomy_calls_total\{outcome=\"$outcome\"\} $count\n";
        }

        $out ~= "# HELP micronomy_cache_errors_total Errors writing or reading the on-disk employee cache.\n";
        $out ~= "# TYPE micronomy_cache_errors_total counter\n";
        $out ~= "micronomy_cache_errors_total $cache-errors\n";
    }

    $out ~= "# HELP micronomy_build_info Static build information.\n";
    $out ~= "# TYPE micronomy_build_info gauge\n";
    $out ~= "micronomy_build_info\{version=\"0.0.1\"\} 1\n";

    $out ~= "# HELP process_uptime_seconds Seconds since the process started.\n";
    $out ~= "# TYPE process_uptime_seconds gauge\n";
    $out ~= "process_uptime_seconds {(now - $start-time).fmt('%.3f')}\n";

    $out ~= "# HELP process_resident_memory_bytes Resident memory size in bytes.\n";
    $out ~= "# TYPE process_resident_memory_bytes gauge\n";
    $out ~= "process_resident_memory_bytes {process-memory-bytes()}\n";

    $out ~= "# HELP process_cpu_seconds_total Total user and system CPU time spent, in seconds.\n";
    $out ~= "# TYPE process_cpu_seconds_total counter\n";
    $out ~= "process_cpu_seconds_total {process-cpu-seconds().fmt('%.2f')}\n";

    return $out;
}
