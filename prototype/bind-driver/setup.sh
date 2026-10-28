#!/bin/sh
# Stand up an isolated dynamic bind zone (TSIG, port 5354) to test the driver.
# Needs: bind-server bind-client bind-ddns-confgen bind-dig bind-check.
set -e
mkdir -p /tmp/dnslab
tsig-keygen -a hmac-sha256 svc-dns > /tmp/dnslab/svc-dns.key
cat > /tmp/dnslab/db.lab.example <<ZONE
\$TTL 300
@   IN SOA ns.lab.example. root.lab.example. ( 1 3600 600 86400 300 )
@   IN NS  ns.lab.example.
ns  IN A   127.0.0.1
ZONE
cat > /tmp/dnslab/named.conf <<CONF
include "/tmp/dnslab/svc-dns.key";
options { directory "/tmp/dnslab"; pid-file "/tmp/dnslab/named.pid";
          listen-on port 5354 { 127.0.0.1; }; listen-on-v6 { none; };
          recursion no; allow-query { 127.0.0.1; }; };
zone "lab.example" { type master; file "/tmp/dnslab/db.lab.example";
                     allow-update { key "svc-dns"; }; };
CONF
named-checkconf /tmp/dnslab/named.conf
[ -f /tmp/dnslab/named.pid ] && kill "$(cat /tmp/dnslab/named.pid)" 2>/dev/null || true
named -c /tmp/dnslab/named.conf
