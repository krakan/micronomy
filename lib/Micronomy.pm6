use Cro::HTTP::Router;
use Cro::HTTP::Client;
use Cro::WebApp::Template;
use URI::Encode;
use JSON::Fast;

class Micronomy {
    my $server = "https://b3iaccess.deltekenterprise.com";
    my $registration = "containers/v1/b3/timeregistration/data;any";
    my @days = <Sön Mån Tis Ons Tor Fre Lör Sön>;

    sub show($token, %content, :$error) {
        my %card = %content<panes><card><records>[0]<data>;
        my %meta = %content<panes><card><records>[0]<meta>;
        my %table = %content<panes><table>;

        my $state = 'Öppen';
        $state = 'Avlämnad' if %table<records>[0]<data><submitted>;
        $state = 'Godkänd' if %card<approvedvar>;
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
            state => $state,
            next => $next,
            previous => $previous,
            card => %card,
            meta => %meta,
            table => %table,
            error => $error,
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
            given $status {
                when "nil" {
                    $status = "";
                }
                when "approved" {
                    $status = "<span style='color:green;'>✔</span>";
                }
                when "denied" {
                    $status = "<span style='color:red;'>✘</span>";
                }
                default {
                    $status = "<span style='color:red;'>$status</span>";
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

        template 'resources/templates/timesheet.html.tmpl', %data;

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

    method get-month(:$token, :$date) {
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

    sub get($token, $date is copy) {
        $date ||= DateTime.now.earlier(hours => 12).yyyy-mm-dd;
        my $uri = "$server/$registration?card.datevar=$date";

        if $date ~~ / '.json' $/ {
            # offline
            $date = %*ENV<HOME> ~ "/micronomy/micronomy-$date" unless $date.IO.e;
            return from-json slurp $date;
        }

        my $request = Cro::HTTP::Client.get(
            $uri,
            headers => {
                Authorization => "X-Reconnect $token",
            },
        );
        my $response = await $request;
        return await $response.body;

        CATCH {
            when X::Cro::HTTP::Error {
                warn "error: " ~ .response.status;
                Micronomy.get-login() if .response.status == 401;
                return {};
            }
            Micronomy.get-login(reason => "Ogiltig session! ")
        }
    }

    method get(:$token, :$date) {
        my %content = get($token, $date) and
            show($token, %content);
    }

    method set(:$token, :%parameters) {
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
                my $concurrency = %parameters{"concurrency-$row"};
                my $uri = "$server/$registration/table/$row?card.datevar=%parameters<date>";
                my $response = await Cro::HTTP::Client.post(
                    $uri,
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

    method submit(:$token, :$date, :$reason, :$concurrency) {
        my $uri = "$server/$registration/card/0/action;name=submittimesheet?card.datevar=$date";
        $uri ~= "&card.resubmissionexplanationvar=$reason" if $reason;
        my $response = await Cro::HTTP::Client.post(
            $uri,
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
                warn "error: " ~ .response.status;
                if .response.status == 401 {
                    Micronomy.get-login(reason => "Var vänlig och logga in!");
                } else {
                    %content = get($token, $date);
                    show($token, %content, error => 'failed to submit week');
                }
                return {};
            }
        }
    }

    method get-login(:$username, :$reason) {
        my %data = (
            username => $username,
            reason => $reason,
        );
        set-cookie "sessionToken", "";
        template 'resources/templates/login.html.tmpl', %data;
    }

    method login(:$username, :$password) {
        my ($token, $status);
        if $username and $password {
            my $uri = "$server/containers/v1/b3/api_currentemployee/data;any";
            my $response = await Cro::HTTP::Client.get(
                $uri,
                auth => {
                    username => $username,
                    password => $password
                },
                headers => {
                    Maconomy-Authentication => 'X-Reconnect',
                    Set-Cookie => 'sessionToken=',
                },
            );
            my @headers = $response.headers;
            for @headers -> $header {
                next if $header.name.lc ne 'maconomy-reconnect';
                $token = $header.value;
                last;
            }

            CATCH {
                when X::Cro::HTTP::Error {
                    my $error = (await .response.body)<errorMessage>;
                    $error = $error ?? '[' ~ .response.status ~ '] ' ~ $error !! .message();
                    $status = uri_encode_component($error);
                }
            }
        }
        if $token {
            set-cookie "sessionToken", $token;
            redirect "/", :see-other;
        } else {
            $status //= '';
            redirect "/login?username=$username&reason=$status", :see-other;
        }
    }

    method logout(:$token) {
        my $status;
        if $token {
            my $uri = "$server/containers/v1/b3/api_currentemployee/data;any";
            my $response = await Cro::HTTP::Client.get(
                $uri,
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
