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

    sub show($token, %content, :$error) {
        trace "show", $token;
        my %card = %content<panes><card><records>[0]<data>;
        my %meta = %content<panes><card><records>[0]<meta>;
        my %table = %content<panes><table>;

        my $weekstatus = 'Öppen';
        $weekstatus = 'Avlämnad' if %table<records>[0]<data><submitted>;
        $weekstatus = 'Godkänd' if %card<approvedvar>;
        my $periodStart = Date.new(%card<periodstartvar>);
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
            week => $week,
            state => $weekstatus,
            next => $next,
            previous => $previous,
            error => $error,
            concurrency => %meta<concurrencyControl>,
            employee => %card<employeenamevar>,
            date => %card<datevar>,
            totalSum => %card<totalnumberofweekvar>,
            fixedSum => %card<fixednumberweekvar>,
            overtimeSum => %card<overtimenumberweekvar>,
            invoiceableSum => %card<invoiceabletimedayweekvar>,
        );

        my $fmt = {sprintf "%s %02d/%02d", @days[.day-of-week], .day, .month};
        for 1..7 -> $day {
            %data<dates>.push(Date.new(%card{"dateday{$day}var"}, formatter => $fmt).Str);
            %data<total>.push(%card{"totalnumberday{$day}var"});
            %data<fixed>.push(%card{"fixednumberday{$day}var"});
            %data<overtime>.push(%card{"overtimenumberday{$day}var"});
            %data<invoiceable>.push(%card{"invoiceabletimeday{$day}var"});
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
                    $status = '<span style="color:green;">✔</span>';
                }
                when "denied" {
                    $status = '<span style="color:red;">✘</span>';
                }
                default {
                    $status = '<span style="color:red;">' ~ $status ~ '</span>';
                }
            }
            my %row = (
                number => $row,
                title => title($row, %table),
                concurrency => %table<records>[$row]<meta><concurrencyControl>,
                weektotal => %table<records>[$row]<data><weektotal>,
                status => $status,
            );
            my @rowdays;
            for 1..7 -> $day {
                @rowdays.push(
                    {
                        number => $day,
                        hours => %table<records>[$row]<data>{"numberday{$day}"} || "",
                        disabled => @disabled[$day-1] // "",
                    }
                );
            }
            %row<days> = @rowdays;
            @rows.push(%row);
        }
        %data<rows> = @rows;

        template 'timesheet.html.tmpl', %data;
        trace "sent timesheet", $token;

        CATCH {
            warn "error: invalid data";
            %content = get($token, Date.today);
            show($token, %content, error => 'invalid data');
            return {};
        }
    }

    sub title(Int $row, %table --> Str) {
        my %row = %table<records>[$row]<data>;
        my $title = %row<entrytext>;
        my $len = chars $title;
        $title ~= ' / ' ~ %row<jobnamevar>;
    }

    method get-month(:$token, :$date = '') {
        trace "get-month $date", $token;
        my $current = Date.new($date).truncated-to('month');
        my $number-of-days = $current.later(days => 31).truncated-to('month').earlier(days => 1).day;

        my $firstDay = $current.day-of-week;
        my $day-of-month = 0;
        my (%month, %monthtable);

        for ^6 -> $week {
            my %content = get($token, $current.gist);
            my %table = %content<panes><table>;
            unless %month {
                %month = %content;
                %monthtable = %month<panes><table>;
            }

            for $firstDay .. 7 -> $day {
                $day-of-month++;
                for ^%table<meta><rowCount> -> $row {
                    %monthtable<records>[$row]<data>{"numberday{$day-of-month}"} = %table<records>[$row]<data>{"numberday{$day}"},
                }
            }
            $firstDay = 1;
        }

        show($token, %month, number-of-days => $number-of-days);
    }

    sub get($token, $date is copy = '') {
        trace "sub get $date", $token;
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;
        my $url = "$server/$registration-path?card.datevar=$date";
        if $date ~~ / '.json' $/ {
            # offline
            $date = %*ENV<HOME> ~ "/micronomy/micronomy-$date" unless $date.IO.e;
            return from-json slurp $date;
        }

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
        my %content = get($token, $date) and
            show($token, %content);
        trace "get method done", $token;
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

    sub get-concurrency($token) {
        trace "get concurrency", $token;
        my $state = 'card';
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

        my $retries = 30;
        for 0 .. $retries -> $wait {
            try {
                sleep $wait/10;
                # refresh data? (seems to be required)
                $state = "data";
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

                return $containerInstanceId, $concurrency;
            }

            if $! ~~ X::Cro::HTTP::Error and $!.response.status == 404 and $wait < $retries {
                trace "get-concurrency ($state) received 404 - retrying [{$wait+1}/$retries]", $token;
            } else {
                die $!;
            }
        }
    }

    sub add-data($action, $token, $source, $target, %parameters) {
        trace "add data [$source -> $target] " ~ %parameters{"position-$source"}, $token;
        my $numberOfLines = %parameters<rows>;
        my ($containerInstanceId, $concurrency) = get-concurrency($token);

        my $url = "$server/$instances-path/$containerInstanceId/data/panes/table";
        if (%parameters{"position-$source"} < $numberOfLines) {
            if $action eq "add" {
                $url ~= "?row=" ~ %parameters{"position-$source"};
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
        my ($containerInstanceId, $concurrency) = get-concurrency($token);

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
        my %content = get($token, $date);

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
            for ^7 -> $day {
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

    method set(:$token, :%parameters) {
        trace "set", $token;
        for %parameters.keys.sort({.split('-', 2)[1]//''}) -> $key {
            next if $key ~~ /concurrency/;
            my $value =  %parameters{$key};
            trace "  $key: $value", $token if $value;
        }

        my %content;
        for 0..* -> $row {
            last unless %parameters{"concurrency-$row"};
            my @changes;
            for 1..7 -> $day  {
                my $hours = %parameters{"hours-$row-$day"} || 0;
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
                %content = await $response.body;
            }
        }

        %content ||= get($token, %parameters<date>);
        show($token, %content);
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
        show($token, %content);

        CATCH {
            when X::Cro::HTTP::Error {
                my $body = await .response.body;
                warn "error: [" ~ .response.status ~ "]:\n    " ~ $body.join("\n    ");
                if .response.status == 401 {
                    Micronomy.get-login(reason => "Var vänlig och logga in!");
                } else {
                    %content = get($token, $date);
                    show($token, %content, error => $body<errorMessage>);
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
        set-cookie "sessionToken", "";
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
            set-cookie "sessionToken", $token;
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
        set-cookie "sessionToken", "";
        redirect "/login?reason=Utloggad!", :see-other;
    }
}
