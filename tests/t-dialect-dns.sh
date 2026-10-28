# SPDX-License-Identifier: MIT
# EdgeOS-style `service dns` dialect over the dnsmasq UCI (/etc/config/dhcp).
. /src/tests/lib.sh

# /etc/config/dhcp isn't a fixture (it's the stock image file, mutated by other
# tests), so start from a known-clean dnsmasq instance for isolation.
cat > /etc/config/dhcp <<'DHCP'
config dnsmasq
	option domainneeded '1'
	option localise_queries '1'
DHCP

out=$(cs <<'EOF'
configure
set service dns forwarding cache-size 1000
set service dns forwarding name-server 1.1.1.1
set service dns forwarding name-server 9.9.9.9
set service dns forwarding listen-on lan
set service dns host nas.lan address 192.168.1.10
set service dns host printer.lan address 192.168.1.20
set service dns cname www.lan target nas.lan
show service dns
commit
EOF
) || fail "dns script failed: $out"

contains "$out" "forwarding {"
contains "$out" "cache-size 1000"
contains "$out" "+    name-server 1.1.1.1"
contains "$out" "+host nas.lan {"
contains "$out" "address 192.168.1.10"
contains "$out" "+cname www.lan {"

eq "$(uci get dhcp.@dnsmasq[0].cachesize)" "1000"
contains "$(uci get dhcp.@dnsmasq[0].server)" "1.1.1.1"
contains "$(uci get dhcp.@dnsmasq[0].server)" "9.9.9.9"
contains "$(uci get dhcp.@dnsmasq[0].interface)" "lan"
eq "$(uci get dhcp.host_nas_lan)" "domain"
eq "$(uci get dhcp.host_nas_lan.name)" "nas.lan"
eq "$(uci get dhcp.host_nas_lan.ip)" "192.168.1.10"
eq "$(uci get dhcp.cname_www_lan.cname)" "www.lan"
eq "$(uci get dhcp.cname_www_lan.target)" "nas.lan"

out=$(confsh show configuration commands service dns)
contains "$out" "set service dns forwarding cache-size '1000'"
contains "$out" "set service dns host nas.lan address '192.168.1.10'"
contains "$out" "set service dns cname www.lan target 'nas.lan'"

for bad in "forwarding cache-size abc" "forwarding name-server notip" "host x.lan address nope"; do
	out=$(printf 'configure\nset service dns %s\n' "$bad" | confsh -s 2>&1) && fail "'$bad' must fail"
	contains "$out" "failed"
done

out=$(cs <<'EOF'
configure
_confsh_be complete set service ""
echo --svc
_confsh_be complete set service dns ""
echo --dns
_confsh_be complete set service dns host ""
echo --hosts
EOF
) || fail "completion failed: $out"
contains "$out" "dns"
contains "$(printf '%s\n' "$out" | sed -n '/--svc/,/--dns/p')" "forwarding"
contains "$(printf '%s\n' "$out" | sed -n '/--dns/,/--hosts/p')" "nas.lan"

cs <<'EOF' || fail "delete failed"
configure
delete service dns forwarding name-server 1.1.1.1
delete service dns host printer.lan
delete service dns cname www.lan
commit
EOF
not_contains "$(uci get dhcp.@dnsmasq[0].server)" "1.1.1.1"
uci -q get dhcp.host_printer_lan && fail "printer host should be gone"
uci -q get dhcp.cname_www_lan && fail "cname should be gone"
# nas.lan host survived the deletes
contains "$(confsh show configuration service dns)" "host nas.lan {"
