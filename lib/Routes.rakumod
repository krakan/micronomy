use Cro::HTTP::Router;
use Micronomy;

sub routes() is export {
    route {
        get -> 'login', :$username = '', :$reason = '' {
            get-login(username => $username.lc, reason => $reason)
        }

        post -> 'login' {
            request-body -> (:$username = '', :$password = '') {
                login(username => $username.lc, password => $password)
            }
        }

        get -> :$sessionToken is cookie = '', :$date = '' {
            if $sessionToken {
                get(token => $sessionToken, :$date)
            } else {
                redirect "/login", :see-other;
            }
        }

        get -> 'demo' {
            login(username => "demo", password => "demo")
        }

        post -> :$sessionToken is cookie = '' {
            request-body -> (*%parameters) {
                my $status = set(:%parameters, token => $sessionToken);
                response.status = $status if $status;
            }
        }

        get -> 'month', :$sessionToken is cookie = '', :$date = '' {
            get-month(token => $sessionToken, :$date)
        }

        post -> 'month', :$sessionToken is cookie = '' {
            request-body -> (*%parameters) {
                get-month(token => $sessionToken, date => %parameters<date>)
            }
        }

        get -> 'period',
               :$sessionToken is cookie = '',
               :$date = Date.today.truncated-to('month'),
               :$end-date = Date.today.truncated-to('month').later(months => 1).pred, {
            get-period(token => $sessionToken,
                       start-date => Date.new($date),
                       end-date => Date.new($end-date),
                      )
        }

        post -> 'period', :$sessionToken is cookie = '' {
            request-body -> (*%parameters) {
                my $hours-cache = %parameters<set-cache> ?? 1 !! %parameters<unset-cache> ?? -1 !! 0;
                get-period(token => $sessionToken,
                           start-date => Date.new(%parameters<date>),
                           end-date => Date.new(%parameters<end-date>),
                           hours-cache => $hours-cache,
                          );
            }
        }

        post -> 'edit', :$sessionToken is cookie = '' {
            if $sessionToken {
                request-body -> (*%parameters) {
                    edit(:%parameters, token => $sessionToken)
                }
            } else {
                redirect "/login", :see-other;
            }
        }

        post -> 'submit', :$sessionToken is cookie = '' {
            if $sessionToken {
                request-body -> (*%parameters) {
                    submit(:%parameters, token => $sessionToken)
                }
            } else {
                redirect "/login", :see-other;
            }
        }

        get -> 'submit', :$sessionToken is cookie = '' {
            redirect "/", :see-other;
        }

        post -> 'logout', :$sessionToken is cookie = '' {
            if $sessionToken {
                request-body -> (:$username = '') {
                    logout(username => $username, token => $sessionToken)
                }
            } else {
                redirect "/login", :see-other;
            }
        }

        post -> 'calendar', :$sessionToken is cookie = '' , :$date {
                if $sessionToken {
                    request-body -> (:$date){
                        calendar(date => $date);
                    }
                } else {
                    redirect "/login", :see-other;
                }
        }

        get -> 'styles', *@path {
            static "resources/styles", @path;
        }
        get -> 'script', *@path {
            static "resources/script", @path;
        }
        get -> 'clockicon.svg', *@path  {
            static "resources/clockicon.svg", @path;
        }
        get -> 'favicon.ico', *@path  {
            static "resources/clockicon.svg", @path;
        }
        get -> 'b3.svg', *@path {
            static "resources/b3.svg", @path;
        }
    }
}
