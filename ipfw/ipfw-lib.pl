# Functions for managing an ipfw firewall.
# Works on a file as generated by ipfw list and read by ipfw /path/name,
# rather than a script.
# XXX some thing are not supported by ipfw1

do '../web-lib.pl';
&init_config();
do '../ui-lib.pl';
if (&foreign_check("net")) {
	&foreign_require("net", "net-lib.pl");
	$has_net_lib = 1;
	}

# Work out save file
$ipfw_file = "$module_config_directory/ipfw.rules";
if ($config{'save_file'}) {
	$ipfw_file = $config{'save_file'};
	}
elsif ($has_net_lib) {
	# Use entry in rc.conf, if set
	local %rc = &net::get_rc_conf();
	if ($rc{'firewall_type'} =~ /^\//) {
		$ipfw_file = $rc{'firewall_type'};
		}
	}

@actions = ( "allow", "deny", "reject", "reset", "skipto", "fwd", "check-state",
	     "count", "divert", "pipe", "queue", "tee", "unreach" );

@unreaches = ( "net", "host", "protocol", "port", "needfrag", "srcfail",
	       "net-unknown", "host-unknown", "isolated", "net-prohib",
	       "host-prohib", "tosnet", "toshost", "filter-prohib",
	       "host-precedence", "precedence-cutoff" );

@options = ( "bridged", "established", "frag", "in", "out",
	     "keep-state", "setup" );

@one_options = ( "gid", "uid", "icmptypes", "recv", "xmit",
		 "via", "tcpflags" );

@two_options = ( "limit", "mac" );

@multi_options = ( "dst-port", "src-port" );

@icmptypes = ( "echo-reply", undef, undef, "destination-unreachable",
	       "source-quench", "redirect", undef, undef, "echo-request",
	       "router-advertisement", "router-solicitation", "ttl-exceeded",
	       "ip-header-bad", "timestamp-request", "timestamp-reply",
	       "information-request", "information-reply",
	       "address-mask-request", "address-mask-reply" );

@tcpflags = ( "fin", "syn", "rst", "psh", "ack", "urg" );

# Get the detected ipfw version
if (open(VERSION, "$module_config_directory/version")) {
	chop($ipfw_version = <VERSION>);
	close(VERSION);
	}

# get_config([file], [&output])
# Returns a list of rules from the firewall file
sub get_config
{
local $file = $_[0] || $ipfw_file;
local @rv;
local $cmt;
local $lnum = 0;
open(LIST, $file);
while(<LIST>) {
	${$_[1]} .= $_ if ($_[1]);
	if (/^(\d+)\s+(.*)/) {
		# an ipfw rule
		local @cmts = split(/\n/, $cmt);
		local $rule = { 'index' => scalar(@rv),
				'line' => $lnum-scalar(@cmts),
				'eline' => $lnum,
				'num' => $1,
				'text' => $2,
				'cmt' => $cmt };
		$cmt = undef;
		local @w = &split_quoted_string($2);

		# Parse counts, if given
		if ($w[0] =~ /^\d+$/) {
			$rule->{'count1'} = shift(@w);
			$rule->{'count2'} = shift(@w);
			}

		# parse the set number
		if ($w[0] eq "set") {
			shift(@w);
			$rule->{'set'} = shift(@w);
			}

		# parse the probability of match
		if ($w[0] eq "prob") {
			shift(@w);
			$rule->{'prob'} = shift(@w);
			}

		# Parse the action
		$rule->{'action'} = shift(@w);
		if ($rule->{'action'} =~ /divert|fwd|forward|pipe|queue|skipto|tee|unreach/) {
			# Action has an arg
			$rule->{'aarg'} = shift(@w);
			}

		# Parse the log section
		if ($w[0] eq "log") {
			$rule->{'log'} = 1;
			shift(@w);
			if ($w[0] eq "logamount") {
				shift(@w);
				$rule->{'logamount'} = shift(@w);
				}
			}

		# Parse the protocol
		local $hasproto;
		if ($w[0] eq "{" || $w[0] eq "(") {
			$rule->{'proto'} = &words_to_orblock(\@w);
			}
		else {
			$rule->{'proto'} = shift(@w);
			$hasproto++ if ($rule->{'proto'} ne "ip" &&
					$rule->{'proto'} ne "any");
			}

		# Parse the source and destination sections
		local $s;
		foreach $s ("from", "to") {
			local $sn = shift(@w);
			next if ($sn ne $s);

			# Parse IP address
			if ($w[0] eq "not") {
				$rule->{$s."_not"} = 1;
				shift(@w);
				}
			if ($w[0] eq "{" || $w[0] eq "(") {
				$rule->{$s} = &words_to_orblock(\@w);
				}
			else {
				$rule->{$s} = shift(@w);
				}

			# Parse ports
			local $pr = $rule->{'proto'};
			if ($w[0] eq "not" && @w > 1 &&
			    ($w[1] =~ /^\d+$/ || $w[1] =~ /,/ ||
                             $w[1] =~ /\-/ ||
                             defined(getservbyname($w[1], $rule->{'proto'})))) {
				shift(@w);
				$rule->{$s."_ports_not"} = 1;
				}
			if ($w[0] =~ /^\d+$/ || $w[0] =~ /,/ ||
			    ($w[0] =~ /^(\S+)\-(\S+)$/ &&
			     &valid_port($1, $pr) &&
			     &valid_port($2, $pr)) ||
			    &valid_port($w[0], $pr)) {
				$rule->{$s."_ports"} = shift(@w);
				}
			}

		# Parse any options
		if ($w[0] eq "{" || $w[0] eq "(") {
			# XXX can be an or-block!
			$rule->{'options'} = &words_to_orblock(\@w);
			}
		else {
			local $nextnot = 0;
			while(@w) {
				local $o = lc(shift(@w));
				$o = "icmptypes" if ($o eq "icmptype");
				if ($o eq "not") {
					$nextnot = 1;
					}
				else {
					if (&indexof($o, @options) >= 0) {
						# Stand-alone option
						$rule->{$o}++;
						$rule->{$o."_not"} = $nextnot;
						}
					elsif (&indexof($o, @one_options) >= 0) {
						# Option with one value
						$rule->{$o} = shift(@w);
						$rule->{$o."_not"} = $nextnot;
						}
					elsif (&indexof($o, @two_options) >= 0) {
						$rule->{$o} = [ shift(@w), shift(@w) ];
						$rule->{$o."_not"} = $nextnot;
						}
					elsif (&indexof($o, @multi_options) >= 0) {
						$rule->{$o} = [ ];
						while(@w && $w[0] =~ /^\d+$/) {
							push(@{$rule->{$o}}, shift(@w));
							}
						$rule->{$o."_not"} = $nextnot;
						}
					else {
						# Unknown option!!
						push(@{$rule->{'unknown'}}, "not") if ($nextnot);
						push(@{$rule->{'unknown'}}, $o);
						}
					$nextnot = 0;
					}
				}
			}

		push(@rv, $rule);
		}
	elsif (/^#\s*(.*)/) {
		# A comment, which applies to the next rule
		$cmt .= "\n" if ($cmt);
		$cmt .= $1;
		}
	}
close(LIST);
return \@rv;
}

# valid_port(text, protocol)
sub valid_port
{
return 1 if ($_[0] =~ /^\d+$/);
return 1 if (defined(getservbyname($_[0], $_[1])));
return 0;
}

# save_config(&rules)
# Updates the firewall file with a list of rules
sub save_config
{
open(LIST, ">$ipfw_file");
foreach $r (@{$_[0]}) {
	local @lines = &rule_lines($r);
	local $l;
	foreach $l (@lines) {
		print LIST $l,"\n";
		}
	}
close(LIST);
}

# rule_lines(&rule, [nocomment])
# Returns the lines of text to make up a rule
sub rule_lines
{
local ($rule) = @_;
local @cmts = $_[1] ? ( ) : map { "# $_" } split(/\n/, $rule->{'cmt'});
if (defined($rule->{'text'})) {
	# Assume un-changed
	return (@cmts, $rule->{'num'}." ".$rule->{'text'});
	}
else {
	# Need to construct
	local @w;

	# Add the basic rule parameters
	push(@w, $rule->{'num'});
	push(@w, "set", $rule->{'set'}) if (defined($rule->{'set'}));
	push(@w, "prob", $rule->{'prob'}) if (defined($rule->{'prob'}));
	push(@w, $rule->{'action'});
	push(@w, $rule->{'aarg'}) if (defined($rule->{'aarg'}));
	if ($rule->{'log'}) {
		push(@w, "log");
		push(@w, "logamount", $rule->{'logamount'})
			if (defined($rule->{'logamount'}));
		}
	push(@w, &orblock_to_words($rule->{'proto'}));

	# Add the from and to sections
	local $s;
	foreach $s ("from", "to") {
		push(@w, $s);
		push(@w, "not") if ($rule->{$s."_not"});
		push(@w, &orblock_to_words($rule->{$s}));
		if (defined($rule->{$s."_ports"})) {
			push(@w, "not") if ($rule->{$s."_ports_not"});
			push(@w, $rule->{$s."_ports"});
			}
		}

	# Add the options
	if (ref($rule->{'options'})) {
		push(@w, &orblock_to_words($rule->{'options'}));
		}
	else {
		local $o;
		foreach $o (@options) {
			if ($rule->{$o}) {
				push(@w, "not") if ($rule->{$o."_not"});
				push(@w, $o);
				}
			}
		foreach $o (@one_options) {
			if (defined($rule->{$o})) {
				push(@w, "not") if ($rule->{$o."_not"});
				push(@w, $o);
				push(@w, $rule->{$o});
				}
			}
		foreach $o (@two_options, @multi_options) {
			if (defined($rule->{$o})) {
				push(@w, "not") if ($rule->{$o."_not"});
				push(@w, $o);
				push(@w, @{$rule->{$o}});
				}
			}
		push(@w, @{$rule->{'unknown'}});
		}

	# Create the resulting rule string
	local @w = map { $_ =~ /\(|\)/ ? "\"$_\"" : $_ } @w;
	return (@cmts, join(" ", @w));
	}
}

sub describe_rule
{
local $r = $_[0];
local @rv;
if ($r->{'proto'} ne 'all' && $r->{'proto'} ne 'ip') {
	push(@rv, &text($r->{'proto_not'} ? 'desc_proto_not' : 'desc_proto',
			"<b>".uc($r->{'proto'})."</b>"));
	}
if ($r->{'from'} ne 'any') {
	push(@rv, &text($r->{'from_not'} ? 'desc_from_not' : 'desc_from',
		$r->{'from'} eq 'me' ? $text{'desc_me'} : "<b>$r->{'from'}</b>"));
	}
if ($r->{'from_ports'} ne '') {
	push(@rv, &text($r->{'from_ports_not'} ? 'desc_from_ports_not'
					       : 'desc_from_ports',
			"<b>$r->{'from_ports'}</b>"));
	}
if ($r->{'to'} ne 'any') {
	push(@rv, &text($r->{'to_not'} ? 'desc_to_not' : 'desc_to',
		$r->{'to'} eq 'me' ? $text{'desc_me'} : "<b>$r->{'to'}</b>"));
	}
if ($r->{'to_ports'} ne '') {
	push(@rv, &text($r->{'to_ports_not'} ? 'desc_to_ports_not'
					       : 'desc_to_ports',
			"<b>$r->{'to_ports'}</b>"));
	}
push(@rv, $text{'desc_in'}) if ($r->{'in'});
push(@rv, $text{'desc_out'}) if ($r->{'out'});
local $o;
foreach $o (@options) {
	if ($r->{$o} && $r->{$o."_not"}) {
		push(@rv, $text{'desc_'.$o.'_not'});
		}
	elsif ($r->{$o}) {
		push(@rv, $text{'desc_'.$o});
		}
	}
foreach $o (@one_options) {
	local $v = $r->{$o};
	if ($o eq "icmptypes") {
		$v = join(",", map { $icmptypes[$_] || $_ }
				split(/,/, $v));
		}
	if ($r->{$o} && $r->{$o."_not"}) {
		push(@rv, &text('desc_'.$o.'_not', "<b>$v</b>"));
		}
	elsif ($r->{$o}) {
		push(@rv, &text('desc_'.$o, "<b>$v</b>"));
		}
	}
if ($r->{'mac'}) {
	if ($r->{'mac'}->[0] eq "any") {
		push(@rv, &text('desc_mac1', "<b>$r->{'mac'}->[1]</b>"));
		}
	elsif ($r->{'mac'}->[1] eq "any") {
		push(@rv, &text('desc_mac2', "<b>$r->{'mac'}->[0]</b>"));
		}
	else {
		push(@rv, &text('desc_mac', "<b>$r->{'mac'}->[0]</b>",
					    "<b>$r->{'mac'}->[1]</b>"));
		}
	}
if ($r->{'limit'}) {
	$limit = &text('desc_limit', $text{'desc_'.$r->{'limit'}->[0]}, $r->{'limit'}->[1]);
	}
if ($r->{'dst-port'}) {
	push(@rv, &text('desc_dstport', join(", ", @{$r->{'dst-port'}})));
	}
if ($r->{'src-port'}) {
	push(@rv, &text('desc_srcport', join(", ", @{$r->{'src-port'}})));
	}
return @rv ? &text($_[1] ? 'desc_where' : 'desc_if',
		   join(" $text{'desc_and'} ", @rv)).$limit
	   : $text{$_[1] ? 'desc_all' : 'desc_always'}.$limit;
}

# words_to_orblock(&words)
sub words_to_orblock
{
local $st = shift(@{$_[0]});
while($_[0]->[0] ne $st) {
	push(@or, shift(@{$_[0]}));
	}
shift(@{$_[0]});
return \@or;
}

# orblock_to_words(&block)
sub orblock_to_words
{
if (ref($_[0])) {
	return ( "{", @{$_[0]}, "}" ); 
	}
else {
	return ( $_[0] );
	}
}

# real_action(name)
# Returns the proper name for some action
sub real_action
{
return $_[0] =~ /accept|pass|permit/ ? "allow" :
       $_[0] =~ /drop/ ? "deny" :
       $_[0] =~ /forward/ ? "fwd" : $_[0];
}

sub list_protocols
{
local @stdprotos = ( 'tcp', 'udp', 'icmp' );
local @otherprotos;
open(PROTOS, "/etc/protocols");
while(<PROTOS>) {
	s/\r|\n//g;
	s/#.*$//;
	push(@otherprotos, $1) if (/^(\S+)\s+(\d+)/);
	}
close(PROTOS);
@otherprotos = sort { lc($a) cmp lc($b) } @otherprotos;
return &unique(@stdprotos, @otherprotos);
}

# apply_rules(&rules)
# Apply the supplied firewall rules
sub apply_rules
{
local $conf = $_[0];
$conf ||= &get_config();
local $dir = `pwd`;
chop($dir);
chdir("/");
&system_logged("$config{'ipfw'} -f flush >/dev/null 2>&1");
local $r;
foreach $r (@$conf) {
	if ($r->{'num'} != 65535) {	# skip auto-added final rule
		local ($line) = &rule_lines($r, 1);
		local $cmd = "$config{'ipfw'} add $line";
		$out = &backquote_logged("$cmd 2>&1 </dev/null");
		return "<tt>$cmd</tt> failed : <tt>$out</tt>" if ($?);
		}
	}
chdir($dir);
return undef;
}

# disable_rules()
# Returns the system to an 'accept all' state
sub disable_rules
{
local $dir = `pwd`;
chop($dir);
chdir("/");
&system_logged("$config{'ipfw'} -f flush >/dev/null 2>&1");
&system_logged("$config{'ipfw'} add allow ip from any to any >/dev/null 2>&1");
chdir($dir);
return undef;
}

# interface_choice(name, value, noignored)
sub interface_choice
{
local @ifaces;
if ($has_net_lib) {
	return &net::interface_choice($_[0], $_[1],
		$_[2] ? undef : "&lt;$text{'edit_ignored'}&gt;");
	}
else {
	return "<input name=$_[0] size=6 value='$_[1]'>";
	}
}

sub create_firewall_init
{
&foreign_require("init", "init-lib.pl");
&foreign_require("cron", "cron-lib.pl");
&cron::create_wrapper("$module_config_directory/start.pl",
		      $module_name, "start.pl");
&cron::create_wrapper("$module_config_directory/stop.pl",
		      $module_name, "stop.pl");
&init::enable_at_boot($module_name,
		      "Start firewall",
		      "$module_config_directory/start.pl",
		      "$module_config_directory/stop.pl");
}

# list_cluster_servers()
# Returns a list of servers on which the firewall is managed
sub list_cluster_servers
{
&foreign_require("servers", "servers-lib.pl");
local %ids = map { $_, 1 } split(/\s+/, $config{'servers'});
return grep { $ids{$_->{'id'}} } &servers::list_servers();
}

# add_cluster_server(&server)
sub add_cluster_server
{
local @sids = split(/\s+/, $config{'servers'});
$config{'servers'} = join(" ", @sids, $_[0]->{'id'});
&save_module_config();
}

# delete_cluster_server(&server)
sub delete_cluster_server
{
local @sids = split(/\s+/, $config{'servers'});
$config{'servers'} = join(" ", grep { $_ != $_[0]->{'id'} } @sids);
&save_module_config();
}

# server_name(&server)
sub server_name
{
return $_[0]->{'desc'} ? $_[0]->{'desc'} : $_[0]->{'host'};
}

# copy_to_cluster([force])
# Copy all firewall rules from this server to those in the cluster
sub copy_to_cluster
{
return if (!$config{'servers'});		# no servers defined
return if (!$_[0] && $config{'cluster_mode'});	# only push out when applying
local $s;
foreach $s (&list_cluster_servers()) {
	&remote_foreign_require($s, "ipfw", "ipfw-lib.pl");
	local $rfile = &remote_eval($s, "ipfw", "\$ipfw_file");
	&remote_write($s, $ipfw_file, $rfile);
	}
}

# apply_cluster_configuration()
# Activate the current configuration on all servers in the cluster
sub apply_cluster_configuration
{
return undef if (!$config{'servers'});
if ($config{'cluster_mode'}) {
	&copy_to_cluster(1);
	}
local $s;
foreach $s (&list_cluster_servers()) {
	&remote_foreign_require($s, "ipfw", "ipfw-lib.pl");
	local $err = &remote_foreign_call($s, "ipfw", "apply_rules");
	if ($err) {
		return &text('apply_remote', $s->{'host'}, $err);
		}
	}
return undef;
}

# check_boot()
# Returns 1 if enabled at boot via an init script, 2 if enabled via rc.conf,
# -1 if a different file is enabled at boot, 0 otherwise
sub check_boot
{
&foreign_require("init", "init-lib.pl");
local $atboot = &init::action_status($module_name);
if ($atboot == 2) {
	return 1;
	}
if ($has_net_lib && defined(&net::get_rc_conf)) {
	local %rc = &net::get_rc_conf();
	if ($rc{'firewall_enable'} ne 'YES') {
		# Disabled
		return 0;
		}
	elsif ($rc{'firewall_type'} eq $ipfw_file) {
		return 2;
		}
	elsif ($rc{'firewall_type'}) {
		# A *different* file is enabled
		return -1;
		}
	}
return 0;
}

# enable_boot()
# Make sure ipfw gets started at boot. Uses rc.conf if possible
sub enable_boot
{
return 0 if (&check_boot());	# Already on
if ($has_net_lib && defined(&net::get_rc_conf) && -r "/etc/rc.conf") {
	local %rc = &net::get_rc_conf();
	&lock_file("/etc/rc.conf");
	&net::save_rc_conf('firewall_type', $ipfw_file);
	&net::save_rc_conf('firewall_enable', 'YES');
	&net::save_rc_conf('firewall_quiet', 'YES');
	&unlock_file("/etc/rc.conf");
	return 2;
	}
&create_firewall_init();
return 1;
}

sub disable_boot
{
local $mode = &check_boot();
return 0 if ($mode <= 0);
if ($mode == 1) {
	# Turn off init script
	&init::disable_at_boot($module_name);
	}
elsif ($mode == 2) {
	# Take out rc.conf entry
	&lock_file("/etc/rc.conf");
	&net::save_rc_conf('firewall_enable', 'NO');
	&unlock_file("/etc/rc.conf");
	}
return $mode;
}

1;
