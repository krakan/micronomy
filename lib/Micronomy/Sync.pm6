unit module Micronomy::Sync;

use JSON::Fast;
use Micronomy::Cache;
use Micronomy::Common;
use Micronomy::Demo;

my (%lock, %syncing);
my $retries = 10;

sub sync($employee, $token, %parameters) is export {
    my $action = %parameters<action>;
    trace "sub sync $action", $token;
    given $action {
        when "put" {
            %syncing{%parameters<week>} = %parameters;
        }
        when "submit" {
            %syncing{%parameters<week>} = %parameters;
        }
        when "get" {
            %syncing{%parameters<week>} //= %parameters;
        }
        when "favorites" {
            %syncing<favorites> = {:$employee, :$action};
        }
    }

    unless %lock{$token} {
        %lock{$token} = True;
        start {
            sync-loop($token);
        }
    }
}

sub sync-loop($token) {
    trace "sub sync-loop", $token;
    my %concurrency;
    while True {
        if %syncing {
            trace "sub sync-loop start", $token;
            for %syncing.keys.sort -> $key {
                # sync item
                given %syncing{$key}<action> {
                    when "get" {
                        trace "sync-loop get $key", $token;
                        %concurrency = get-week($token, $key, :%concurrency);
                    }
                    when "put" {
                        trace "sync-loop put $key", $token;
                        my %week = %syncing{$key}<data>;
                        %concurrency = set-week($token, $key, %week, :%concurrency);
                    }
                    when "submit" {
                        trace "sync-loop submit $key", $token;
                        %concurrency = submit($token, $key, %syncing{$key}<reason>, :%concurrency);
                    }
                    when "favorites" {
                        trace "sync-loop get favorites", $token;
                        get-favorites($token, %syncing{$key}<employee>);
                    }
                }
                %syncing{$key}:delete;
            }
            trace "sub sync-loop pause", $token;
        } else {
            sleep 1;
        }
    }
}

my $server = "https://b3iaccess.deltekenterprise.com";
my $instances-path = "maconomy-api/containers/b3/timeregistration/instances";
my $favorites-path = "maconomy-api/containers/b3/jobfavorites/instances";
my $tasks-path = "maconomy-api/containers/b3/timeregistration/search/table;foreignkey=taskname_tasklistline?fields=taskname,description&limit=100";

sub get-week($token, $date, :%concurrency) is export {
    trace "sub get-week $date", $token;

    return get-demo($date) if $token eq "demo";

    my $containerInstanceId = %concurrency<containerInstanceId>;
    my $concurrency = %concurrency<concurrency>;

    unless $containerInstanceId and $concurrency {
        ($containerInstanceId, $concurrency) = get-concurrency($token, $date);
    }

    my $url = "$server/$instances-path/$containerInstanceId/data/panes/card/0";
    trace "sub get-week request", $token;
    my $response = call-url(
        $url,
        headers => {
            Authorization => "X-Reconnect $token",
            Content-Type => "application/json",
            Maconomy-Concurrency-Control => "$concurrency",
        },
        body => '{"data": {"datevar": "' ~ $date ~ '"}}',
    );
    return {} unless $response;
    return parse-week($response);

    CATCH {
        when X::Cro::HTTP::Error {
            error $_, $token;
            return get-week($token, $date) if .response.status == (404, 409, 422).any;
            die $_;
        }
        default {
            error $_, $token;
            die $_;
        }
    }
}

sub set-week($token, $date, %week, :%concurrency) is export {
    trace "sub set-week $date", $token;

    return {} if $token eq "demo";

    my $containerInstanceId = %concurrency<containerInstanceId>;
    my $concurrency = %concurrency<concurrency>;
    my $row-count = -1;

    unless $containerInstanceId and $concurrency {
        ($containerInstanceId, $concurrency, $row-count) = get-concurrency($token, $date);
    }

    my $url = "$server/$instances-path/$containerInstanceId/data/panes/table";

    my %content;
    for ^@(%week<rows>) -> $row {
        # populate row
        for 0 .. $retries -> $wait {
            try {
                # check for changes
                my $keep = not %week<rows>[$row]<temp>;
                if %content {
                    my $unchanged = %week<rows>[$row]<job> eq %content<panes><table><records>[$row]<data><jobnumber>;
                    $unchanged = %week<rows>[$row]<task> eq %content<panes><table><records>[$row]<data><taskname> if $unchanged;
                    $unchanged = $keep eq %content<panes><table><records>[$row]<data><permanentline> if $unchanged;
                    if $unchanged {
                        for 1..7 -> $day {
                            my $hours = %week<rows>[$row]<hours>{"$day"} // 0;
                            if ($hours != $%content<panes><table><records>[$row]<data>{"numberday{$day}"}) {
                                $unchanged = False;
                                last;
                            }
                        }
                    }
                    trace "skipping row $row", $token if $unchanged;
                    last if $unchanged;
                }

                my $target = "/$row";
                if $row-count == $row {
                    $target = "";
                } elsif 0 <= $row-count <= $row {
                    $target = "?row=$row";
                }
                my @data = ();
                @data.push('"jobnumber": "' ~ %week<rows>[$row]<job> ~ '"');
                @data.push('"taskname": "' ~ %week<rows>[$row]<task> ~ '"') if %week<rows>[$row]<task>;
                for 1..7 -> $day {
                    my $hours = %week<rows>[$row]<hours>{"$day"} // 0;
                    @data.push("\"numberday{$day}\": $hours");
                }
                my $data = '{"data": {' ~ @data.join(",") ~ '}}';
                if $target {
                    trace "setting $target to $data", $token;
                } else {
                    trace "adding row $data", $token;
                }
                my $response = call-url(
                    "$url$target",
                    timeout => 3,
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Maconomy-Concurrency-Control => $concurrency,
                        Content-Type => "application/json",
                    },
                    body => $data,
                );
                $concurrency = get-header($response, 'maconomy-concurrency-control');
                %content = await $response.body;
                $row-count = %content<panes><table><meta><rowCount> // -1;

                if $keep ne %content<panes><table><records>[$row]<data><permanentline> {
                    my $permanent = $keep.lc;
                    trace "set permanence for row $target to $permanent", $token;
                    my $response = call-url(
                        "$url/$row",
                        timeout => 3,
                        headers => {
                            Authorization => "X-Reconnect $token",
                            Maconomy-Concurrency-Control => $concurrency,
                            Content-Type => "application/json",
                        },
                        body => '{"data": {"permanentline":' ~ " $permanent}}",
                    );
                    $concurrency = get-header($response, 'maconomy-concurrency-control');
                    %content = await $response.body;
                }

                last;
            }
            if $! ~~ X::Cro::HTTP::Error and $!.response.status == (404, 409, 422).any and $wait < $retries {
                ($containerInstanceId, $concurrency, $row-count) = get-concurrency($token, $date);
            } elsif $! {
                die $!
            }
        }
    }
    for @(%week<rows>) ..^ $row-count -> $row {
        # delete extraneous rows
        for 0 .. $retries -> $wait {
            try {
                trace "delete row $row", $token;
                my $response = call-url(
                    "$url/$row",
                    method => 'delete',
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Maconomy-Concurrency-Control => $concurrency,
                    },
                );
                $concurrency = get-header($response, 'maconomy-concurrency-control');
                last;
            }
            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 409 and $wait < $retries {
                ($containerInstanceId, $concurrency, $row-count) = get-concurrency($token, $date);
            } elsif $! {
                die $!
            }
        }
    }

    return {:$concurrency, :$containerInstanceId};
}

sub get-concurrency($token, $date) is export {
    trace "get concurrency", $token;
    return '"card"="demo", "table"="demo"' if $token eq "demo";

    # get card id
    my $url = "$server/$instances-path";
    my $response = call-url(
        $url,
        headers => {
            Authorization => "X-Reconnect $token",
            Content-Type => "application/json",
        },
        body => '{"panes":{}}',
    );

    my %content = await $response.body;
    my $containerInstanceId = %content<meta><containerInstanceId>;
    my $concurrency = get-header($response, 'maconomy-concurrency-control');
    my $employeeNumber = 0;

    trace "get concurrency employeeNumber", $token;
    # refresh concurrency (sic!)
    $response = call-url(
        "$url/$containerInstanceId/data;any",
        headers => {
            Authorization => "X-Reconnect $token",
            Maconomy-Concurrency-Control => $concurrency,
            Content-Type => "application/json",
            Content-Length => 0,
        },
    );
    $concurrency = get-header($response, 'maconomy-concurrency-control');
    %content = await $response.body;
    $employeeNumber = %content<panes><card><records>[0]<data><employeenumber>;

    trace "get concurrency concurrency", $token;
    $response = call-url(
        "$url/$containerInstanceId/data/panes/card/0",
        headers => {
            Authorization => "X-Reconnect $token",
            Maconomy-Concurrency-Control => $concurrency,
            Content-Type => "application/json",
        },
        body => '{"data":{"datevar":"' ~ $date ~ '","employeenumbervar":"' ~ $employeeNumber ~ '"}}',
    );
    $concurrency = get-header($response, 'maconomy-concurrency-control');
    %content = await $response.body;
    my $row-count = %content<panes><table><meta><rowCount> // 0;

    return $containerInstanceId, $concurrency, $row-count;

    CATCH {
        when X::Cro::HTTP::Error {
            if .response.status == 409 {
                return get-concurrency($token, $date);
            } else {
                die $_;
            }
        }
    }
}

sub parse-week($response) is export {
    trace "parse-week";
    my %content = await $response.body;

    my %card = %content<panes><card><records>[0]<data>;
    my @records = @(%content<panes><table><records>);
    my $rowCount = %content<panes><table><meta><rowCount>;

    my $weekstatus = 0;
    $weekstatus = 1 if @records[0]<data><submitted>;
    $weekstatus = 2 if %card<approvedvar>;

    my %cache = get-cache(%card<employeenumber>);

    %cache<employeeName> = %card<employeenamevar>;
    %cache<employeeNumber> = %card<employeenumber>;
    %cache<concurrency> = get-header($response, 'maconomy-concurrency-control');
    %cache<containerInstanceId> = %content<meta><containerInstanceId>;

    my %weekData = (
        name => %card<weeknumbervar> ~ %card<partvar>,
        state => $weekstatus,
        synched => DateTime.now,
        totals => {
            reported => %card<totalnumberofweekvar>,
            fixed => %card<fixednumberweekvar>,
            overtime => %card<overtimenumberweekvar>,
            invoiceable => %card<invoiceabletimedayweekvar>,
        },
    );

    for 1..7 -> $wday {
        my %day;
        %day<reported> = %card{"totalnumberday{$wday}var"} if %card{"totalnumberday{$wday}var"};
        %day<fixed> = %card{"fixednumberday{$wday}var"} if %card{"fixednumberday{$wday}var"};
        %day<overtime> = %card{"overtimenumberday{$wday}var"} if %card{"overtimenumberday{$wday}var"};
        %day<invoiceable> = %card{"invoiceabletimeday{$wday}var"} if %card{"invoiceabletimeday{$wday}var"};
        %weekData<totals><days>{$wday} = %day if %day.keys;
    }

    for ^$rowCount -> $row {
        my %rowData = @records[$row]<data>;
        my $jobName = %rowData<jobnamevar>;
        my $jobNumber = %rowData<jobnumber>;
        my $taskNumber = %rowData<taskname>;
        my $taskName = %rowData<entrytext>;

        %cache<jobs>{$jobNumber}<name> = $jobName;
        %cache<jobs>{$jobNumber}<tasks>{$taskNumber} = $taskName;

        my $total = @records[$row]<data><weektotal>;

        %weekData<rows>[$row] = {
            job => $jobNumber,
            task => $taskNumber,
        };
        %weekData<rows>[$row]<temp> = True unless @records[$row]<data><permanentline>;
        %weekData<rows>[$row]<total> = $total if $total;
        for 1..7 -> $wday {
            my $hours = @records[$row]<data>{"numberday{$wday}"};
            %weekData<rows>[$row]<hours>{$wday} = $hours if $hours;
        }
    }

    my ($week-name, $periodStart, $year, $month, $mday) = get-current-week(%card<periodstartvar>);
    %cache<weeks>{$year}{$month}{$mday} = %weekData;

    set-cache(%cache);

    %cache<currentWeek> = %card<periodstartvar>;
    %cache<currentDate> = %card<datevar>;
    for ^$rowCount -> $row {
        my %rowData = @records[$row]<data>;
        %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<state> = %rowData<approvalstatus>;
        %cache<weeks>{$year}{$month}{$mday}<rows>[$row]<concurrency> = @records[$row]<meta><concurrencyControl>;
    }

    return %cache;
}

sub get-favorites($token, $employee) {
    trace "sub get-favorites", $token;
    return if $token eq "demo";

    my $url = "$server/$favorites-path";
    my $response = call-url(
        $url,
        headers => {
            Authorization => "X-Reconnect $token",
            Content-Type => "application/json",
        },
        body => '{"panes": {}}',
    );
    my $body = await $response.body;

    my $containerInstanceId = $body<meta><containerInstanceId>;
    my $concurrency = get-header($response, 'maconomy-concurrency-control');

    $url = "$server/$favorites-path/$containerInstanceId/data;any";
    $response = call-url(
        $url,
        headers => {
            Authorization => "X-Reconnect $token",
            Content-Type => "application/json",
            Content-Length => 0,
            Maconomy-Concurrency-Control => $concurrency,
        },
    );
    $body = await $response.body;

    my (%favorites, %jobs, %fetch);
    for @($body<panes><table><records>) -> $record {
        my $job = $record<data><jobnumber>;
        my $task = $record<data><taskname>;
        %favorites{$record<data><favorite>}<job> = $job;
        %favorites{$record<data><favorite>}<task> = $task if $task;
        %jobs{$job}<name> = $record<data><jobnamevar>;
        if $task {
            %jobs{$job}<tasks>{$task} = $record<data><tasktextvar>;
        } else {
            %fetch{$job}++;
        }
    }
    for %fetch.keys -> $job {
        my %tasks = get-tasks($token, $job);
        if %tasks {
            for %tasks.keys -> $task {
                %jobs{$job}<tasks>{$task} = %tasks{$task};
            }
        } else {
            %jobs{$job}:delete;
        }
    }

    my %cache = get-cache($employee);
    for %jobs.keys -> $job {
        %cache<jobs>{$job} = %jobs{$job};
    }
    %cache<favorites> = %favorites;
    set-cache(%cache);
}

sub get-tasks($token, $jobnumber) {
    trace "sub get-tasks for $jobnumber", $token;

    my $url = "$server/$tasks-path";
    my $response = call-url(
        $url,
        headers => {
            Authorization => "X-Reconnect $token",
            Content-Type => "application/json",
        },
        body => '{"data": {"jobnumber":"' ~ $jobnumber ~ '"}}',
    );
    my $body = await $response.body;

    my %tasks;
    for @($body<panes><filter><records>) -> $record {
        %tasks{$record<data><taskname>} = $record<data><description>;
    }
    return %tasks;
}

sub submit($token, $date, $reason = "", :%concurrency) {
    trace "sub submit $date", $token;

    my $containerInstanceId = %concurrency<containerInstanceId>;
    my $concurrency = %concurrency<concurrency>;

    unless $containerInstanceId and $concurrency {
        ($containerInstanceId, $concurrency) = get-concurrency($token, $date);
    }

    # submit week
    for 0 .. $retries -> $wait {
        try {
            my $url = "$server/$instances-path/$containerInstanceId/data/panes/card/0/action;name=submittimesheet";
            $url ~= "?card.resubmissionexplanationvar=$reason" if $reason;
            trace "submit $url", $token;
            my $response = call-url(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Content-Type => "application/json",
                    Maconomy-Concurrency-Control => $concurrency,
                    Content-Length => 0,
                },
            );
        }
        if $! ~~ X::Cro::HTTP::Error and $!.response.status == (404, 409).any and $wait < $retries {
            ($containerInstanceId, $concurrency) = get-concurrency($token, $date);
        } elsif $! {
            die $!
        }
    }
}
