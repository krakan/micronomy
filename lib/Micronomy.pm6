use Cro::HTTP::Router;
use Cro::HTTP::Client;
use Cro::WebApp::Template;
use URI::Encode;
use JSON::Fast;
use Digest::MD5;

class Micronomy {
    my $server = "https://b3iaccess.deltekenterprise.com";
    my $registration-path = "containers/v1/b3/timeregistration/data;any";
    my $instances-path = "maconomy-api/containers/b3/timeregistration/instances";
    my $employee-path = "containers/v1/b3/api_currentemployee/";
    my $favorites-path = "containers/v1/b3/jobfavorites";
    my $tasks-path = "maconomy-api/containers/b3/timeregistration/search/table;foreignkey=taskname_tasklistline?fields=taskname,description&limit=100";
    my @days = <Sön Mån Tis Ons Tor Fre Lör Sön>;
    my @months = <Dec Jan Feb Mar Apr Maj Jun Jul Aug Sep Okt Nov Dec>;
    template-location 'resources/templates/';

    sub trace($message, $token = '') {
        my $now = DateTime.now(
            formatter => { sprintf "%4d-%02d-%02d %02d:%02d:%06.3f",
                           .year, .month, .day, .hour, .minute, .second });
        my $session = $token ?? Digest::MD5.md5_hex($token).substr(24) !! '-';
        say "$now  $session  $message";
    }

    sub get-header($response, $header) {
        for $response.headers -> $key {
            return $key.value if $key.name.lc eq $header.lc;
        }
    }

    sub show-week($token, %content, :$error) {
        trace "show-week", $token;
        my %card = %content<panes><card><records>[0]<data>;
        my %meta = %content<panes><card><records>[0]<meta>;
        my %table = %content<panes><table>;

        my $weekstatus = 'Öppen';
        $weekstatus = 'Avlämnad' if %table<records>[0]<data><submitted>;
        $weekstatus = 'Godkänd' if %card<approvedvar>;
        my $periodStart = Date.new(%card<periodstartvar>);
        my $today = Date.today.gist;
        my $previous = $periodStart.earlier(days => 1);
        my $next = $periodStart.later(days => 7);
        $next = $next.truncated-to('month') if $periodStart.month != $next.month;

        my $week = %card<weeknumbervar>;
        my @disabled;
        my $sundayDate = $periodStart.truncated-to('week').later(days => 6).day;
        if $sundayDate < 7 {
            my $split = 7 - $sundayDate;
            if $periodStart.day-of-week != 1 {
                $week ~= 'B';
                @disabled = "disabled" xx $split;
            } else {
                $week ~= 'A';
                @disabled = flat("" xx $split, "disabled" xx 6);
            }
        }

        my %data = (
            period => "vecka $week",
            action => "/",
            date-action => "/",
            state => ", $weekstatus",
            next => $next,
            previous => $previous,
            today => $today,
            error => $error,
            concurrency => %meta<concurrencyControl>,
            employee => %card<employeenamevar>,
            date => %card<datevar>,
            total => %card<totalnumberofweekvar>,
            fixed => %card<fixednumberweekvar>,
            overtime => %card<overtimenumberweekvar>,
            invoiceable => %card<invoiceabletimedayweekvar>,
            filler => -1,
        );
        for ^%table<meta><rowCount> -> $row {
            %data<filler> = $row if %table<records>[$row]<data><entrytext> eq "Tjänstledig mot RAM";
        }

        my $fmt = {sprintf "%s %02d/%02d", @days[.day-of-week], .day, .month};
        for 1..7 -> $day {
            my %day = (number => $day);
            %day<date> = Date.new(%card{"dateday{$day}var"}, formatter => $fmt).Str;
            %day<total> = %card{"totalnumberday{$day}var"};
            %day<fixed> = %card{"fixednumberday{$day}var"};
            %day<overtime> = %card{"overtimenumberday{$day}var"};
            %day<invoiceable> = %card{"invoiceabletimeday{$day}var"};
            %data<days>.push(%day);
        }

        my @rows;
        for ^%table<meta><rowCount> -> $row {
            my $status = %table<records>[$row]<data><approvalstatus>;
            $status = "approved" if $status eq "nil" and %card<approvedvar>;
            given $status {
                when "nil" {
                    $status = "";
                }
                when "approved" {
		    # #31d23b = bright green
                    $status = '<div class="status" style="color:#31d23b;">✔</div>';
                }
                when "denied" {
		    # #ff4646 = bright red
                    $status = '<div class="status" style="color:#ff4646;">✘</div>';
                }
                default {
		    # #ff4646 = bright red same as the above
                    $status = '<div class="status" style="color:#ff4646;">' ~ $status ~ '</div>';
                }
            }
            my %row = (
                number => $row,
                title => title($row, %table),
                concurrency => %table<records>[$row]<meta><concurrencyControl>,
                weektotal => %table<records>[$row]<data><weektotal>,
                status => $status,
                disabled => $row == %data<filler>,
            );

            my @rowdays;
            for 1..7 -> $day {
                my $disabled = @disabled[$day-1] // "";
                $disabled = "disabled" if %row<disabled>;
                my $classes = "hour-box input__text";
                $classes ~= $disabled ?? " input__text--disabled" !! " nav-field";
                @rowdays.push(
                    {
                        number => $day,
                        disabled => $disabled,
                        classes => $classes,
                        hours => %table<records>[$row]<data>{"numberday{$day}"} || "",
                    }
                );
            }
            %row<days> = @rowdays;
            @rows.push(%row);
        }

        if %content<last-target> and %content<last-target> ~~ / "hours-" $<row> = (\d+) "-" $<day> = (\d+) / {
            my $day = $<day> - 1;;
            for |($day ... 6), |($day ... 0) -> $day {
                trace "day: $day";
                unless @rows[$<row>]<days>[$day]<disabled> {
                    @rows[$<row>]<days>[$day]<id> = "focus-target";
                    last;
                }
            }
        } else {
            for 1..7 -> $day {
                if %card{"dateday{$day}var"} eq $today and
                                             not @rows[0]<days>[$day-1]<disabled> {
                    @rows[0]<days>[$day-1]<id> = "focus-target";
                }
            }
        }
        %data<rows> = @rows;

        trace "sending timesheet", $token;
        template 'timesheet.html.tmpl', %data;

        CATCH {
            warn "error: invalid data";
            %content = get-week($token, Date.today.gist);
            show-week($token, %content, error => 'invalid data');
            return {};
        }
    }

    sub title(Int $row, %table --> Str) {
        my %row = %table<records>[$row]<data>;
        my $title = %row<entrytext>;
        my $len = chars $title;
        $title ~= ' / ' ~ %row<jobnamevar>;
    }

    method get-month(:$token, :$date) {
        trace "get-month $date", $token;
        my $start-date = $date ?? Date.new($date) !! Date.today;
        $start-date .= first-date-in-month;
        my $end-date = $start-date.last-date-in-month;

        Micronomy.get-period(:$token, :$start-date, :$end-date);
    }

    method get-period(:$token, :$start-date, :$end-date) {
        trace "get-period $start-date", $token;

        my $bucketSize = 'week';
        my $previous = $start-date.earlier(days => 1);
        my $next = $end-date.later(days => 1);

        if $start-date.truncated-to('year') != $end-date.truncated-to('year') {
            $bucketSize = 'year';
        } elsif $start-date.truncated-to('month') != $end-date.truncated-to('month') {
            $bucketSize = 'month';
        }

        my (%content, %sums, %totals, %card);
        my $current = $start-date;
        for 0..* -> $week {
            %content = get-week($token, $current.gist);
            my %table = %content<panes><table>;
            %card = %content<panes><card><records>[0]<data>;
            my $bucket = $current.truncated-to($bucketSize);

            %totals<total>{$bucket} += %card<totalnumberofweekvar>;
            %totals<fixed>{$bucket} += %card<fixednumberweekvar>;
            %totals<overtime>{$bucket} += %card<overtimenumberweekvar>;
            %totals<invoiceable>{$bucket} += %card<invoiceabletimedayweekvar>;

            for 1 .. 7 -> $day {
                my $date = %card{"dateday{$day}var"};
                next if $date lt $start-date.gist;
                last if $date gt $end-date.gist;

                for ^%table<meta><rowCount> -> $row {
                    my $hours = %table<records>[$row]<data>{"numberday{$day}"};
                    if $hours {
                        my $job = %table<records>[$row]<data>{"jobnumber"};
                        my $task = %table<records>[$row]<data>{"taskname"};
                        unless %sums{$job}{$task}<title>:exists {
                            %sums{$job}{$task}<title> = title($row, %table),
                        }
                        %sums{$job}{$task}<bucket>{$bucket} += $hours;
                    }
                }
            }
            my $next = $current.later(days => 7).truncated-to('week');
            last if $next gt $end-date;
            if $next.month != $current.month and $next.day > 1 {
                $current = $next.earlier(days => 1);
            } else {
                $current = $next;
            }
        }

        my @buckets = %totals<total>.keys.sort;
        for @buckets -> $bucket {
             %totals<total><sum> += %totals<total>{$bucket};
             %totals<fixed><sum> += %totals<fixed>{$bucket};
             %totals<overtime><sum> += %totals<overtime>{$bucket};
             %totals<invoiceable><sum> += %totals<invoiceable>{$bucket};
        }

        my %data = (
            period => "$start-date - $end-date",
            action => "/month",
            date-action => "/period",
            state => "",
            next => $next,
            previous => $previous,
            today => Date.today.gist,
            error => "",
            concurrency => 'read-only',
            employee => %card<employeenamevar>,
            date => $start-date.gist,
            end-date => $end-date.gist,
            total => %totals<total><sum>,
            fixed => %totals<fixed><sum>,
            overtime => %totals<overtime><sum>,
            invoiceable => %totals<invoiceable><sum>,
            filler => -1,
        );

        my $fmt = {sprintf "v%02d", .week-number};
        $fmt = {sprintf "%s", @months[.month]} if $bucketSize eq "month";
        $fmt = {sprintf "%4d", .year} if $bucketSize eq "year";
        for @buckets -> $bucket {
            my %day = (number => $bucket);
            my $suffix = "";
            my $bucketDate = Date.new($bucket);
            my $bucketStart = $start-date > $bucketDate ?? $start-date !! $bucketDate;
            if $bucketSize eq "week" {
                $suffix = "B" if $bucketDate < $start-date;
                $suffix = "A" if $bucketDate.later(days => 6) > $end-date;
                %day<url> = "/?date=$bucketStart";
            } elsif $bucketSize eq "month" {
                %day<url> = "/month?date=$bucketStart";
            } elsif $bucketSize eq "year" {
                my $bucketEnd = $bucketStart.year ~ "-12-31";
                $bucketEnd = $end-date if $end-date.gist lt $bucketEnd;
                %day<url> = "/period?date=$bucketStart&end-date=$bucketEnd";
            }
            %day<date> = Date.new($bucket, formatter => $fmt).Str ~ $suffix;
            %day<total> = %totals<total>{$bucket};
            %day<fixed> = %totals<fixed>{$bucket};
            %day<overtime> = %totals<overtime>{$bucket};
            %day<invoiceable> = %totals<invoiceable>{$bucket};
            %data<days>.push(%day);
        }

        my $row = 0;
        for %sums.keys.sort -> $job {
            for %sums{$job}.keys.sort -> $task {
                my @rowbuckets;
                for @buckets -> $bucket {
                    %sums{$job}{$task}<sum> += %sums{$job}{$task}<bucket>{$bucket} // 0;
                    @rowbuckets.push(
                        {
                            number => $bucket,
                            disabled => "disabled",
                            classes => "hour-box input__text input__text--disabled",
                            hours => %sums{$job}{$task}<bucket>{$bucket} || "",
                        }
                    );
                }

                my %row = (
                    number => $row++,
                    title => %sums{$job}{$task}<title>,
                    concurrency => 'read-only',
                    weektotal => %sums{$job}{$task}<sum>,
                    disabled => True,
                    status => "",
                    days => @rowbuckets,
                );
                %data<rows>.push(%row);
            }
        }

        trace "sending timesheet", $token;
        template 'timesheet.html.tmpl', %data;
    }

    sub get-week($token, $date is copy = '') {
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;
        trace "sub get-week $date", $token;
        my $url = "$server/$registration-path?card.datevar=$date";

        my $request = Cro::HTTP::Client.get(
            $url,
            headers => {
                Authorization => "X-Reconnect $token",
            },
        );
        my $response = await $request;
        my $body = await $response.body;
        return $body;

        CATCH {
            when X::Cro::HTTP::Error {
                warn "error: " ~ .response.status;
                Micronomy.get-login() if .response.status == 401;
                return {};
            }
            Micronomy.get-login(reason => "Ogiltig session! ")
        }
    }

    method get(:$token, :$date = '') {
        trace "get $date", $token;
        my %content = get-week($token, $date) and
            show-week($token, %content);
        trace "get method done", $token;
    }

    method demo(:$token) {
        trace "demo", $token;
        my $dir = $*PROGRAM-NAME;
        $dir ~~ s/<-[^/]>* $//;
        $dir ||= '.';
        my $file = "$dir/resources/demo.json";
        my %content = from-json slurp $file;
        show-week($token, %content);
        trace "demo method done", $token;
    }

    sub get-favorites($token) {
        trace "sub get-favorites", $token;
        my $url = "$server/$favorites-path/data;any";
        my $request = Cro::HTTP::Client.get(
            $url,
            headers => {
                Authorization => "X-Reconnect $token",
                Content-Type => "application/json",
                Content-Length => 0,
            },
        );
        my $response = await $request;
        my $body = await $response.body;
        return $body;

        CATCH {
            when X::Cro::HTTP::Error {
                warn "error: [" ~ .response.status ~ "]:\n    " ~ $body.join("\n    ");
                Micronomy.get-login() if .response.status == 401;
                return {};
            }
            Micronomy.get-login(reason => "Ogiltig session! ")
        }
    }

    sub get-tasks($token, $jobnumber) {
        trace "sub get-tasks for $jobnumber", $token;

        my $url = "$server/$tasks-path";
        my $request = Cro::HTTP::Client.post(
            $url,
            headers => {
                Authorization => "X-Reconnect $token",
                Content-Type => "application/json",
            },
            body => '{"data": {"jobnumber":"' ~ $jobnumber ~ '"}}',
        );
        my $response = await $request;
        my $body = await $response.body;

        my @tasks;
        for @($body<panes><filter><records>) -> $record {
            @tasks.push(
                {
                    number => $record<data><taskname>,
                    name => $record<data><description>,
                }
            );
        }
        return @tasks;
    }

    sub get-concurrency($token, $date) {
        trace "get concurrency", $token;
        # get card id
        my $url = "$server/$instances-path";
        my $response = await Cro::HTTP::Client.post(
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

        my $retries = 10;
        for 0 .. $retries -> $wait {
            try {
                sleep $wait/10;
                # refresh data? (seems to be required)
                $response = await Cro::HTTP::Client.post(
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

                last;
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries {
                trace "get-concurrency (data;any) received 404 - retrying [{$wait+1}/$retries]", $token;
            } else {
                die $!;
            }
        }

        for 0 .. $retries -> $wait {
            try {
                sleep $wait/10;
                $response = await Cro::HTTP::Client.post(
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

                return $containerInstanceId, $concurrency;
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries {
                trace "get-concurrency (datevar) received 404 - retrying [{$wait+1}/$retries]", $token;
            } else {
                die $!;
            }
        }
    }

    sub add-data($action, $token, $source, $target, %parameters) {
        trace "add data [$source -> $target] " ~ %parameters{"position-$source"}, $token;
        my $numberOfLines = %parameters<rows>;
        my ($containerInstanceId, $concurrency) = get-concurrency($token, %parameters<date>);

        my $url = "$server/$instances-path/$containerInstanceId/data/panes/table";
        if (%parameters{"position-$source"} < $numberOfLines) {
            if $action eq "add" {
                $url ~= "?row=" ~ $target;
            } else {
                $url ~= "/$target";
            }
        }

        my $retries = 9;
        for 0 .. $retries -> $wait {
            sleep $wait/10;
            try {
                # populate row
                my @data = ();
                @data.push('"jobnumber": "' ~ %parameters{"job-$source"} ~ '"') if %parameters{"job-$source"};
                @data.push('"taskname": "' ~  %parameters{"task-$source"} ~ '"') if %parameters{"task-$source"};
                @data.push('"permanentline": ' ~ (%parameters{"keep-$source"} == 1 ?? "false" !! "true"));
                if %parameters{"position-$source"} ne $source and %parameters{"hours-$source"}:exists {
                    my $day = 0;
                    for %parameters{"hours-$source"}.split(";") -> $hours {
                        $day++;
                        @data.push("\"numberday{$day}\": $hours") if $hours ne "0";
                    }
                }
                my $data = '{"data": {' ~ @data.join(",") ~ '}}';
                trace "$url $data";

                my $response = await Cro::HTTP::Client.post(
                    "$url",
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Maconomy-Concurrency-Control => $concurrency,
                        Content-Type => "application/json",
                    },
                    body => $data,
                );

                return get-header($response, 'maconomy-concurrency-control');
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries {
                trace "add-data received 404 - retrying [{$wait+1}/$retries]", $token;
            } else {
                die $!;
            }
        }
    }

    sub delete-row($token, $target, %parameters) {
        trace "delete row $target", $token;
        my ($containerInstanceId, $concurrency) = get-concurrency($token, %parameters<date>);

        # delete row
        my $url = "$server/$instances-path";
        for ^10 -> $wait {
            sleep $wait/10;
            try {
                my $response = await Cro::HTTP::Client.delete(
                    "$url/$containerInstanceId/data/panes/table/$target",
                    headers => {
                        Authorization => "X-Reconnect $token",
                        Maconomy-Concurrency-Control => $concurrency,
                    },
                );
                return get-header($response, 'maconomy-concurrency-control');
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < 9 {
                trace "delete-row received 404 - retrying [{$wait+1}/9]", $token;
            } else {
                die $!;
            }
        }
    }

    sub edit($token, %parameters) {
        my $numberOfLines = %parameters<rows>;
        my @currentPosition = ^$numberOfLines;

        # delete, update or move lines
        for (^$numberOfLines).sort({@currentPosition[$_]}) -> $row {
            trace "positions "~@currentPosition;
            my $target = @currentPosition[$row];
            my $was-kept = %parameters{"was-kept-$row"} eq "True" ?? 2 !! 1;
            if %parameters{"keep-$row"} == 0 {
                delete-row($token, $target, %parameters);

                # mark index as deleted in position array
                @currentPosition[$row] = -1;
                for ^@currentPosition -> $position {
                    @currentPosition[$position]-- if @currentPosition[$position] > $target;
                }
                next;

            } elsif %parameters{"set-task-$row"} or %parameters{"keep-$row"} != $was-kept {
                %parameters{"task-$row"} = %parameters{"set-task-$row"};
                add-data('update', $token, $row, $target, %parameters);
            }

            # move lines
            my $newTarget = %parameters{"position-$row"};
            if $newTarget != $row and $newTarget != $target {
                trace "move row $row from $target to $newTarget", $token;
                if $newTarget < $target {
                    add-data('add', $token, $row, $newTarget, %parameters);
                    delete-row($token, $target+1, %parameters);
                } else {
                    add-data('add', $token, $row, $newTarget+1, %parameters);
                    delete-row($token, $target, %parameters);
                }
                # move indexes in position array
                @currentPosition[$row] = $newTarget;
                for ^@currentPosition -> $position {
                    my $other = @currentPosition[$position];
                    @currentPosition[$position]-- if $newTarget > $other > $target;
                    @currentPosition[$position]++ if $newTarget < $other < $target;
                }
            }
        }
        trace "positions "~@currentPosition;

        # add new line
        my $row = $numberOfLines;
        if %parameters{"job-$row"} ne "" {
            %parameters{"keep-$row"} = 2;
            my $task = %parameters{"job-$row"}.split("/")[1];
            %parameters{"task-$row"} = %parameters{"job-$row"}.split("/")[1] if $task;
            %parameters{"job-$row"} = %parameters{"job-$row"}.split("/")[0];
            add-data('add', $token, $row, %parameters{"position-$row"}, %parameters);
        }
    }

    method edit(:$token, :%parameters) {
        trace "edit", $token;
        my $date = %parameters<date>;
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;

        trace "parameters:", $token;
        for %parameters.keys.sort -> $key {
            trace "$key: %parameters{$key}";
        }
        edit($token, %parameters) if %parameters<rows>:exists;

        my %favorites = get-favorites($token) || return;
        my %content = get-week($token, $date);

        my %card = %content<panes><card><records>[0]<data>;
        my %meta = %content<panes><card><records>[0]<meta>;
        my %table = %content<panes><table>;
        my $week = %card<weeknumbervar>;

        my %data = (
            week => $week,
            error => '',
            concurrency => %meta<concurrencyControl>,
            employee => %card<employeenamevar>,
            date => $date,
        );
        my (@rows, %rows);
        for ^%table<meta><rowCount> -> $row {
            my $jobnumber  = %table<records>[$row]<data><jobnumber>;
            my $tasknumber = %table<records>[$row]<data><taskname>;
            %rows{$jobnumber}{$tasknumber} = 1;
            my @hours;
            for 1..7 -> $day {
                @hours.push(%table<records>[$row]<data>{"numberday{$day}"} || 0);
            }
            my %row = (
                number => $row,
                description => %table<records>[$row]<data><description>,
                jobnumber   => $jobnumber,
                jobname     => %table<records>[$row]<data><jobnamevar>,
                tasknumber  => $tasknumber,
                taskname    => %table<records>[$row]<data><tasktextvar>,
                concurrency => %table<records>[$row]<meta><concurrencyControl>,
                keep        => %table<records>[$row]<data><permanentline>,
                hours       => @hours.join(";"),
            );
            if not $tasknumber {
                %row<tasks> = get-tasks($token, $jobnumber);
            }
            @rows.push(%row);
        }
        %data<rows> = @rows;
        %data<next> = @rows.elems;

        my @favorites;
        for ^%favorites<panes><table><meta><rowCount> -> $row {
            my $jobnumber = %favorites<panes><table><records>[$row]<data><jobnumber>;
            my $tasknumber = %favorites<panes><table><records>[$row]<data><taskname>;
            next if %rows{$jobnumber}{$tasknumber};
            my %favorite = (
                favorite   => %favorites<panes><table><records>[$row]<data><favorite>,
                jobnumber  => $jobnumber,
                jobname    => %favorites<panes><table><records>[$row]<data><jobnamevar>,
                tasknumber => $tasknumber,
                taskname   => %favorites<panes><table><records>[$row]<data><tasktextvar>,
            );
            @favorites.push(%favorite);
        }
        %data<favorites> = @favorites;

        template 'edit.html.tmpl', %data;

        #CATCH {
        #    when X::Cro::HTTP::Error {
        #        warn "error: " ~ .response.status;
        #        Micronomy.get-login() if .response.status == 401;
        #        return {};
        #    }
        #    Micronomy.get-login(reason => "Ogiltig session! ")
        #}
    }

    sub set-filler(%content, %parameters, $filler --> Bool) {
        return False if $filler < 0;
        return False unless %content;

        my %card = %content<panes><card><records>[0]<data>;
        my %table = %content<panes><table>;
        my $previous = %table<records>[$filler]<data><weektotal>;
        my $total = %card<fixednumberweekvar> - %card<totalnumberofweekvar> + $previous;

        for (1..7).sort(
            {
                %card{"overtimenumberday{$_}var"}
                -
                %table<records>[$filler]<data>{"numberday{$_}"}
            }
        ) -> $day  {
            my $previous = %table<records>[$filler]<data>{"numberday{$day}"},
            my $overtime = $previous - %card{"overtimenumberday{$day}var"};
            $overtime = $total if $overtime > $total;
            $overtime = 0 if $overtime < 0;

            trace("filling day $day with $overtime");
            %parameters{"hours-$filler-$day"} = $overtime;
            $total -= $overtime;
        }
        return True;
    }

    sub set(%parameters, $row, $token) {
        my @changes;
        for 1..7 -> $day  {
            my $hours = %parameters{"hours-$row-$day"} || "0";
            $hours = +$hours.subst(",", ".");
            my $previous = %parameters{"hidden-$row-$day"} || 0;
            if $hours ne $previous {
                @changes.push("\"numberday$day\": " ~ $hours);
            }
        }
        if @changes {
            trace "setting row $row", $token;
            my $concurrency = %parameters{"concurrency-$row"};
            my $url = "$server/$registration-path/table/$row?card.datevar=%parameters<date>";
            my $response = await Cro::HTTP::Client.post(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Content-Type => "application/json",
                    Accept => "application/json",
                    Maconomy-Concurrency-Control => $concurrency,
                },
                body => '{"data":{' ~ @changes.join(", ") ~ '}}',
            );
            return await $response.body;
        }
    }

    method set(:$token, :%parameters) {
        trace "set", $token;
        for %parameters.keys.sort({.split('-', 2)[1]//''}) -> $key {
            next if $key ~~ /concurrency/;
            my $value =  %parameters{$key};
            trace "  $key: $value", $token if $value;
        }

        my $filler = %parameters<filler> // -1;
        my %content;
        for 0..* -> $row {
            last unless %parameters{"concurrency-$row"};
            next if $row == $filler;
            my %result = set(%parameters, $row, $token);
            %content = %result if %result;
        }
        if set-filler(%content, %parameters, $filler) {
            my %result = set(%parameters, $filler, $token);
            %content = %result if %result;
        }

        %content ||= get-week($token, %parameters<date>);
        %content<last-target> =  %parameters<last-target>;
        show-week($token, %content);
        return;

        CATCH {
            when X::Cro::HTTP::Error {
                warn "error: " ~ .response.status;
                if .response.status == 401 {
                    Micronomy.get-login(reason => "Var vänlig och logga in!");
                    return;
                }
            }
            Micronomy.get-login(reason => "Ogiltig session! ")
        }
    }

    method submit(:$token, :$date = '', :$reason, :$concurrency) {
        trace "submit $date", $token;
        my $url = "$server/$registration-path/card/0/action;name=submittimesheet?card.datevar=$date";
        $url ~= "&card.resubmissionexplanationvar=$reason" if $reason;
        my $response = await Cro::HTTP::Client.post(
            $url,
            headers => {
                Authorization => "X-Reconnect $token",
                Content-Type => "application/json",
                Accept => "application/json",
                Maconomy-Concurrency-Control => $concurrency,
                Content-Length => 0,
            },
        );

        my %content = await $response.body;
        show-week($token, %content);

        CATCH {
            when X::Cro::HTTP::Error {
                my $body = await .response.body;
                warn "error: [" ~ .response.status ~ "]:\n    " ~ $body.join("\n    ");
                if .response.status == 401 {
                    Micronomy.get-login(reason => "Var vänlig och logga in!");
                } else {
                    %content = get-week($token, $date);
                    show-week($token, %content, error => $body<errorMessage>);
                }
                return {};
            }
        }
    }

    method get-login(:$username = '', :$reason = '') {
        trace "get-login $username $reason";
        my %data = (
            username => $username,
            reason => $reason,
        );
        set-cookie("sessionToken", "login",
                   same-site => Cro::HTTP::Cookie::SameSite::Strict,
                   expires => DateTime.now(),
                  );
        template 'login.html.tmpl', %data;
        trace "sent login page";
    }

    method login(:$username = '', :$password) {
        my ($token, $status);
        if $username and $password {
            trace "login $username ***";
            my $url = "$server/$employee-path/data;any";
            my $response = await Cro::HTTP::Client.get(
                $url,
                auth => {
                    username => $username,
                    password => $password
                },
                headers => {
                    Maconomy-Authentication => 'X-Reconnect',
                    Set-Cookie => 'sessionToken=',
                },
            );
            $token = get-header($response, 'maconomy-reconnect');
            trace "logged in $username", $token;

            CATCH {
                when X::Cro::HTTP::Error {
                    my $error = (await .response.body)<errorMessage>;
                    $error = $error ?? '[' ~ .response.status ~ '] ' ~ $error !! .message();
                    $status = uri_encode_component($error);
                }
            }
        }
        if $token {
            trace "$username logged in", $token;
            set-cookie("sessionToken", $token,
                       same-site => Cro::HTTP::Cookie::SameSite::Strict,
                      );
            redirect "/", :see-other;
            trace "redirected from login to get", $token;
        } else {
            trace "$username login failed";
            $status //= '';
            redirect "/login?username=$username&reason=$status", :see-other;
            trace "redirected from login to login";
        }
    }

    method logout(:$token) {
        trace "logout", $token;
        my $status;
        if $token {
            my $url = "$server/$employee-path/data;any";
            my $response = await Cro::HTTP::Client.get(
                $url,
                headers => {
                    Authorization => "X-Reconnect $token",
                    Maconomy-Authentication => "X-Log-Out",
                },
            );

            CATCH {
                when X::Cro::HTTP::Error {
                    # ignore errors
                }
            }
        }
        set-cookie("sessionToken", "logout",
                   same-site => Cro::HTTP::Cookie::SameSite::Strict,
                   expires => DateTime.now(),
                  );
        redirect "/login?reason=Utloggad!", :see-other;
    }
}
