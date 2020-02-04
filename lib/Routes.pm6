use Cro::HTTP::Router;
use Micronomy;

sub routes() is export {
    route {
        get -> 'login', :$username = '', :$reason = '' {
            Micronomy.get-login(username => $username, reason => $reason)
        }

        post -> 'login' {
            request-body -> (:$username = '', :$password = '') {
                Micronomy.login(username => $username, password => $password)
            }
        }

        get -> :$sessionToken is cookie, :$date = '' {
            if $sessionToken {
                Micronomy.get(token => $sessionToken, date => $date)
            } else {
                redirect "/login", :see-other;
            }
        }

        post -> :$sessionToken is cookie = '' {
            request-body -> (*%parameters) {
                Micronomy.set(parameters => %parameters, token => $sessionToken)
            }
        }

        post -> 'edit', :$sessionToken is cookie = '' {
            if $sessionToken {
                request-body -> (*%parameters) {
                    Micronomy.edit(parameters => %parameters, token => $sessionToken)
                }
            } else {
                redirect "/login", :see-other;
            }
        }

        post -> 'submit', :$sessionToken is cookie = '' {
            if $sessionToken {
                request-body -> (:$date = '', :$reason = '', :$concurrency = '') {
                    Micronomy.submit(date => $date, reason => $reason, token => $sessionToken, concurrency => $concurrency)
                }
            } else {
                redirect "/login", :see-other;
            }
        }

        post -> 'logout', :$sessionToken is cookie = '' {
            if $sessionToken {
                request-body -> (:$username = '') {
                    Micronomy.logout(username => $username, token => $sessionToken)
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
        get -> 'favicon.ico' {
            static "resources/b3.png";
        }
    }
}
