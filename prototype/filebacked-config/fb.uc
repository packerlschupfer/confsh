#!/usr/bin/ucode
// SPDX-License-Identifier: MIT
// confsh RFC #3 PoC: a file-backed config provider engine + a bind zone
// provider, demonstrating configure/set/show/commit/rollback over real files
// with validate + freeze/thaw safety. Standalone (not wired into confsh core).
'use strict';

import * as fs from 'fs';

const LIVE    = getenv('FB_LIVE')    ?? '/tmp/fb/live';
const SESSION = getenv('FB_SESSION') ?? '/tmp/fb/session';
const ARCHIVE = getenv('FB_ARCHIVE') ?? '/tmp/fb/archive';
const ZONE    = getenv('FB_ZONE')    ?? 'lab.example';

function sh(cmd) { return system(cmd); }
function have(tool) { return sh(`command -v ${tool} >/dev/null 2>&1`) == 0; }

// ===================== PROVIDER INTERFACE =====================
// files(dir,zone) parse(dir,zone)->{pre,recs} render(dir,zone,parsed)
// validate(dir,zone)->[ok,msg] freeze(zone) thaw(zone)
// ==============================================================

const RTYPES = [ 'A', 'AAAA', 'CNAME' ];

function zonefile(dir, zone) { return `${dir}/db.${zone}`; }

// Whitespace-tokenise a line (ucode's regex engine lacks non-capturing groups,
// so we avoid regex for record parsing).
function fields(line) {
	let out = [], cur = '';
	for (let i = 0; i < length(line); i++) {
		let c = substr(line, i, 1);
		if (c == ' ' || c == '\t') { if (cur != '') { push(out, cur); cur = ''; } }
		else cur += c;
	}
	if (cur != '') push(out, cur);
	return out;
}

const bind = {
	files: (dir, zone) => [ zonefile(dir, zone) ],

	parse: function(dir, zone) {
		let txt = fs.readfile(zonefile(dir, zone)) ?? '';
		let pre = [], recs = [];
		for (let line in split(txt, '\n')) {
			let f = fields(line);
			let i = index(f, 'IN');
			// name [TTL] IN <A|AAAA|CNAME> <value>
			if (i >= 1 && i + 2 < length(f) + 1 && index(RTYPES, f[i + 1]) >= 0 && f[i + 2] != null)
				push(recs, { name: f[0], ttl: (i == 2) ? f[1] : null, type: f[i + 1], value: f[i + 2] });
			else if (line != '') push(pre, line);
		}
		return { pre, recs };
	},

	render: function(dir, zone, parsed) {
		// bump the SOA serial so secondaries notice the change
		let pre = map(parsed.pre, (l) => {
			let m = match(l, /^([ \t]*)([0-9]+)([ \t]*;[ \t]*[Ss]erial.*)$/);
			return m ? `${m[1]}${int(m[2]) + 1}${m[3]}` : l;
		});
		let recs = sort(parsed.recs, (a, b) =>
			((a.name + a.type + a.value) < (b.name + b.type + b.value)) ? -1 : 1);
		let lines = [ ...pre ];
		for (let r in recs)
			push(lines, sprintf('%-20s %sIN %-5s %s', r.name, r.ttl ? `${r.ttl} ` : '', r.type, r.value));
		fs.writefile(zonefile(dir, zone), join('\n', lines) + '\n');
	},

	validate: function(dir, zone) {
		if (!have('named-checkzone')) return [ true, 'named-checkzone absent — skipped' ];
		let rc = sh(`named-checkzone ${zone} ${zonefile(dir, zone)} >/dev/null 2>&1`);
		return [ rc == 0, rc == 0 ? 'named-checkzone OK' : 'named-checkzone FAILED' ];
	},

	// dynamic-zone safety: freeze before editing the file, thaw (reloads) after
	freeze: function(zone) {
		if (!have('rndc')) { print(`  [freeze] would run: rndc freeze ${zone}\n`); return; }
		sh(`rndc freeze ${zone} 2>/dev/null`);
	},
	thaw: function(zone) {
		if (!have('rndc')) { print(`  [thaw]   would run: rndc thaw ${zone}  (reloads the zone)\n`); return; }
		sh(`rndc thaw ${zone} 2>/dev/null`);
	}
};

const provider = bind;

// ===================== ENGINE =====================

function copy_files(from, to) {
	fs.mkdir(to);
	for (let f in provider.files(from, ZONE)) {
		let base = split(f, '/')[length(split(f, '/')) - 1];
		sh(`cp -a '${f}' '${to}/${base}' 2>/dev/null`);
	}
}

function archive_live() {
	fs.mkdir(ARCHIVE);
	let n = length(fs.lsdir(ARCHIVE) ?? []) + 1;
	copy_files(LIVE, `${ARCHIVE}/${n}`);
	return n;
}

function need_session() {
	if (!fs.stat(zonefile(SESSION, ZONE)))
		die('No session — run "configure" first');
}

function cmd_configure() {
	sh(`rm -rf '${SESSION}'`);
	copy_files(LIVE, SESSION);
	print(`configure: session opened for zone ${ZONE}\n`);
}

function cmd_set(name, t, value) {
	need_session();
	let p = provider.parse(SESSION, ZONE);
	for (let r in p.recs)
		if (r.name == name && r.type == t && r.value == value) { print('set: already present\n'); return; }
	push(p.recs, { name, type: t, value });
	provider.render(SESSION, ZONE, p);
	print(`set: ${name} ${t} ${value}\n`);
}

function cmd_delete(name, t, value) {
	need_session();
	let p = provider.parse(SESSION, ZONE);
	let before = length(p.recs);
	p.recs = filter(p.recs, r => !(r.name == name && r.type == t && (value == null || r.value == value)));
	if (length(p.recs) == before) die(`Nothing to delete: ${name} ${t} ${value ?? ''}`);
	provider.render(SESSION, ZONE, p);
	print(`delete: ${name} ${t} ${value ?? '(all)'}\n`);
}

function key(r) { return `${r.name} ${r.type} ${r.value}`; }

function cmd_show() {
	need_session();
	let live = {}, sess = {};
	for (let r in provider.parse(LIVE, ZONE).recs) live[key(r)] = true;
	for (let r in provider.parse(SESSION, ZONE).recs) sess[key(r)] = true;
	let all = {};
	for (let k in live) all[k] = true;
	for (let k in sess) all[k] = true;
	for (let k in sort(keys(all))) {
		let mark = (live[k] && sess[k]) ? ' ' : (sess[k] ? '+' : '-');
		print(`${mark} ${k}\n`);
	}
}

function cmd_commit() {
	need_session();
	let v = provider.validate(SESSION, ZONE);
	print(`commit: validate — ${v[1]}\n`);
	if (!v[0]) die('commit refused: validation failed');
	let n = archive_live();
	print(`commit: archived current as revision ${n}\n`);
	provider.freeze(ZONE);
	copy_files(SESSION, LIVE);
	provider.thaw(ZONE);
	print('commit: applied\n');
}

function cmd_rollback(nstr) {
	let n = int(nstr);
	let dir = `${ARCHIVE}/${n}`;
	if (!fs.stat(zonefile(dir, ZONE))) die(`No such revision: ${n}`);
	archive_live();                       // keep current as a new revision too
	provider.freeze(ZONE);
	copy_files(dir, LIVE);
	provider.thaw(ZONE);
	sh(`rm -rf '${SESSION}'`); copy_files(LIVE, SESSION);
	print(`rollback: restored revision ${n} and applied\n`);
}

function cmd_commits() {
	for (let d in sort(fs.lsdir(ARCHIVE) ?? [])) print(`revision ${d}\n`);
}

// ===================== dispatch =====================
let a = ARGV;
let cmd = a[0];
switch (cmd) {
case 'configure': cmd_configure(); break;
case 'set':       cmd_set(a[1], a[2], a[3]); break;
case 'delete':    cmd_delete(a[1], a[2], a[3]); break;
case 'show':      cmd_show(); break;
case 'commit':    cmd_commit(); break;
case 'rollback':  cmd_rollback(a[1]); break;
case 'commits':   cmd_commits(); break;
default:          die(`usage: fb.uc configure|set|delete|show|commit|rollback|commits`);
}
