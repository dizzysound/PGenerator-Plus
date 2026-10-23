#!/usr/bin/perl
# Regression tests for the WebUI cross-site request guard.
#
# The WebUI used to answer every request with "Access-Control-Allow-Origin: *",
# so any web page open on the calibration PC could read the API (the AP
# passphrase, the config) and post to it. It now sends no CORS grant, refuses
# a cross-site POST/PUT by comparing Origin with Host, and acts on the
# restart, reboot and power endpoints for POST only. Every in-repo caller has
# to keep working: same-origin browser calls, and non-browser clients that
# send no Origin.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 26;

sub slurp {
 my ($path)=@_;
 open(my $fh,'<',$path) or die "$path: $!";
 local $/;
 return scalar <$fh>;
}

my $pm_src = slurp("$Bin/../usr/share/PGenerator/webui.pm");
my $js_src = slurp("$Bin/../usr/share/PGenerator/webui-app.js");
my $dep_src = slurp("$Bin/../github-deployer/server.py");

# ── response headers ──
my ($cors_line) = $pm_src =~ /^\s*my \$cors="([^"]*)";/m;
ok(defined $cors_line, 'handler builds the shared $cors header block');
unlike($cors_line, qr/Access-Control/i, '$cors carries no Access-Control header');
unlike($pm_src, qr/Access-Control-Allow-Origin/, 'webui.pm never grants a cross-origin read');

# ── origin guard ──
my ($guard) = $pm_src =~ /(sub webui_foreign_origin \(\$\$\) \{.*?\n\})/s;
ok($guard, 'webui.pm origin guard extracted');
eval $guard; die "guard eval failed: $@" if $@;

sub req {
 my ($host,$origin)=@_;
 my $r = "POST /api/reboot HTTP/1.1\r\n";
 $r .= "Host: $host\r\n" if defined $host;
 $r .= "Origin: $origin\r\n" if defined $origin;
 return $r."Content-Length: 0\r\n\r\n";
}

is(webui_foreign_origin('POST', req('192.168.1.5','http://192.168.1.5')), 0,
   'same-origin POST by IP is accepted');
is(webui_foreign_origin('POST', req('pgenerator.local','http://pgenerator.local')), 0,
   'same-origin POST by mDNS name is accepted');
is(webui_foreign_origin('POST', req('192.168.1.5:8080','http://192.168.1.5:8080')), 0,
   'same-origin POST on a non-default port is accepted');
is(webui_foreign_origin('POST', req('192.168.1.5','http://192.168.1.5:80')), 0,
   'an explicit default port in Origin still matches');
is(webui_foreign_origin('POST', req('192.168.1.5:80','http://192.168.1.5')), 0,
   'an explicit default port in Host still matches');
is(webui_foreign_origin('POST', req('PGenerator.LOCAL','http://pgenerator.local')), 0,
   'host comparison ignores case');
is(webui_foreign_origin('POST', req('192.168.1.5',undef)), 0,
   'non-browser POST without Origin is accepted');
is(webui_foreign_origin('POST', req(undef,undef)), 0,
   'HTTP/1.0 style POST without Host or Origin is accepted');
is(webui_foreign_origin('POST', req('192.168.1.5','http://evil.example')), 1,
   'POST from another site is refused');
is(webui_foreign_origin('PUT', req('192.168.1.5','http://evil.example')), 1,
   'PUT from another site is refused');
is(webui_foreign_origin('POST', req('192.168.1.5','http://192.168.1.5.evil.example')), 1,
   'a look-alike host suffix is refused');
is(webui_foreign_origin('POST', req('192.168.1.5','http://192.168.1.5:8080')), 1,
   'same host on another port is a different origin');
is(webui_foreign_origin('POST', req('192.168.1.5','null')), 1,
   'Origin: null (sandboxed frame, file page) is refused');
is(webui_foreign_origin('POST', req('192.168.1.5','http://192.168.1.5/path')), 1,
   'a malformed Origin with a path is refused');
is(webui_foreign_origin('POST', req(undef,'http://192.168.1.5')), 1,
   'an Origin with no Host to compare against is refused');
is(webui_foreign_origin('GET', req('192.168.1.5','http://evil.example')), 0,
   'reads are left to the missing CORS grant, not the guard');
is(webui_foreign_origin('OPTIONS', req('192.168.1.5','http://evil.example')), 0,
   'a preflight is not refused here; it simply gets no CORS grant');
is(webui_foreign_origin(undef, req('192.168.1.5','http://evil.example')), 0,
   'an unparsed method does not warn or refuse');

# ── routing: the guard runs before any handler, and the destructive routes need POST ──
like($pm_src, qr/elsif\(\$origin_foreign\) \{.*?403 Forbidden/s,
     'a foreign origin gets 403 ahead of every route');
like($pm_src, qr/\$path eq "\/api\/restart" \|\| \$path eq "\/api\/reboot" \|\| \$path eq "\/api\/power"\) && \$method ne "POST"\) \{.*?405 Method Not Allowed\\r\\nAllow: POST/s,
     'restart, reboot and power answer 405 unless the method is POST');

# ── in-repo callers ──
my @raw_restart = $js_src =~ /fetchJSON\('\/api\/(?:restart|reboot|power)'(?!\/)[^)]*\)/g;
my @not_post = grep { !/method:'POST'/ } @raw_restart;
is(scalar(@not_post), 0,
   'every WebUI call to restart, reboot or power is a POST'
   .(@not_post ? ': '.join('; ',@not_post) : ''));
like($dep_src, qr{wget -q -O - --post-data= http://127\.0\.0\.1/api/restart},
     'the deploy console restarts the renderer with a POST');
