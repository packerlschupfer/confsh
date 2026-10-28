# bind backend driver PoC for `service dns`

Proves the **non-UCI backend** half of the backend-driver design
(halcycon/confsh#8). The same `service dns host|cname …` grammar the dnsmasq
(UCI) driver serves is applied to **bind via `nsupdate`/TSIG** — not by editing
zone files.

- `setup.sh` — stands up an isolated dynamic zone (`lab.example`, TSIG,
  127.0.0.1#5354) so it never touches a real resolver.
- `dns-bind host-add|host-del|cname-add|cname-del <name> [val]` — the driver.

Why nsupdate, not file editing: deletes work, bind keeps its `.jnl` journal, the
change is atomic and validated by bind, and there's **no `rndc freeze/thaw`
hazard** — which is exactly why the file-backed engine in #3 was the wrong model.

Verified on the test EdgeRouter (OpenWrt, `bind-server` via apk): add A + CNAME,
query with dig, delete A (query returns empty), journal written.
