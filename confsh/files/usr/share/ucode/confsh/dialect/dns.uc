// SPDX-License-Identifier: MIT
// EdgeOS-style `service dns ...` over the dnsmasq UCI config (/etc/config/dhcp).
// This is the UCI-native DNS backend driver: like `interfaces wireguard`, it is
// pure EdgeOS-path -> UCI translation and needs no confsh core changes. Other
// backends (bind via nsupdate, PowerDNS via its API) are NOT UCI and would ride
// a backend-driver interface + the commit participant hook, not this module.
'use strict';

import { as_list } from 'confsh.util';

const CFG = 'dhcp';

const GRAMMAR = {
	children: {
		'forwarding': {
			children: {
				'cache-size':  { type: 'number' },
				'name-server': { type: 'ipv4' },   // upstream resolver (list)
				'listen-on':   { type: 'name' }    // interface name (list)
			}
		},
		'host':  { tag: 'name', children: { 'address': { type: 'ipv4' } } },
		'cname': { tag: 'name', children: { 'target':  { type: 'host' } } }
	}
};

function san(s) { return replace(s, /[^A-Za-z0-9]/g, '_'); }

// the dnsmasq instance section (stock config has one; we never create it)
function dnsmasq_id(ctx) {
	for (let s in ctx.sections(CFG))
		if (s.type == 'dnsmasq')
			return s.id;
	ctx.fail('no dnsmasq instance in /etc/config/dhcp (is dnsmasq installed?)');
}

function host_id(ctx, name, create) {
	for (let s in ctx.sections(CFG))
		if (s.type == 'domain' && s.opts.name == name)
			return s.id;
	if (!create) ctx.fail(`Nothing to delete: host ${name} does not exist`);
	let id = `host_${san(name)}`;
	ctx.cur.set(CFG, id, 'domain');
	ctx.cur.set(CFG, id, 'name', name);
	return id;
}

function cname_id(ctx, alias, create) {
	for (let s in ctx.sections(CFG))
		if (s.type == 'cname' && s.opts.cname == alias)
			return s.id;
	if (!create) ctx.fail(`Nothing to delete: cname ${alias} does not exist`);
	let id = `cname_${san(alias)}`;
	ctx.cur.set(CFG, id, 'cname');
	ctx.cur.set(CFG, id, 'cname', alias);
	return id;
}

function list_add(ctx, id, opt, val) {
	let old = ctx.cur.get(CFG, id, opt);
	let items = as_list(old);
	if (index(items, val) < 0) {
		if (type(old) == 'array') ctx.cur.list_append(CFG, id, opt, val);
		else ctx.cur.set(CFG, id, opt, [ ...items, val ]);
	}
}

function list_del(ctx, id, opt, val, label) {
	let items = as_list(ctx.cur.get(CFG, id, opt));
	if (index(items, val) < 0) ctx.fail(`Nothing to delete: ${label} ${val ?? ''} is not set`);
	if (length(items) == 1) ctx.cur.delete(CFG, id, opt);
	else ctx.cur.list_remove(CFG, id, opt, val);
}

function set(ctx, p) {
	let s = p.steps;            // s[0] = 'dns'
	let kind = s[1]?.key;

	if (kind == 'forwarding') {
		let id = dnsmasq_id(ctx);
		if (p.leaf == 'cache-size') ctx.cur.set(CFG, id, 'cachesize', p.value);
		else if (p.leaf == 'name-server') list_add(ctx, id, 'server', p.value);
		else if (p.leaf == 'listen-on') list_add(ctx, id, 'interface', p.value);
	}
	else if (kind == 'host') {
		let id = host_id(ctx, s[1].tag, true);
		if (p.leaf == 'address') ctx.cur.set(CFG, id, 'ip', p.value);
	}
	else if (kind == 'cname') {
		let id = cname_id(ctx, s[1].tag, true);
		if (p.leaf == 'target') ctx.cur.set(CFG, id, 'target', p.value);
	}
	ctx.touch(CFG);
}

function del(ctx, p) {
	let s = p.steps;
	let kind = s[1]?.key;
	let cur = ctx.cur;

	if (kind == 'forwarding') {
		let id = dnsmasq_id(ctx);
		if (p.leaf == 'cache-size') { if (cur.get(CFG, id, 'cachesize') == null) ctx.fail('Nothing to delete: cache-size is not set'); cur.delete(CFG, id, 'cachesize'); }
		else if (p.leaf == 'name-server') list_del(ctx, id, 'server', p.value, 'name-server');
		else if (p.leaf == 'listen-on') list_del(ctx, id, 'interface', p.value, 'listen-on');
	}
	else if (kind == 'host') {
		let id = host_id(ctx, s[1].tag, false);
		if (!p.leaf) cur.delete(CFG, id);
		else if (p.leaf == 'address') { if (cur.get(CFG, id, 'ip') == null) ctx.fail('Nothing to delete: address is not set'); cur.delete(CFG, id, 'ip'); }
	}
	else if (kind == 'cname') {
		let id = cname_id(ctx, s[1].tag, false);
		if (!p.leaf) cur.delete(CFG, id);
		else if (p.leaf == 'target') { if (cur.get(CFG, id, 'target') == null) ctx.fail('Nothing to delete: target is not set'); cur.delete(CFG, id, 'target'); }
	}
	ctx.touch(CFG);
}

function render(ctx) {
	let secs = ctx.sections(CFG);
	let dns = [];

	let dm = filter(secs, s => s.type == 'dnsmasq')[0];
	if (dm) {
		let o = dm.opts, fk = [];
		if (o.cachesize != null) push(fk, { name: 'cache-size', value: o.cachesize });
		for (let v in as_list(o.server)) push(fk, { name: 'name-server', value: v });
		for (let v in as_list(o.interface)) push(fk, { name: 'listen-on', value: v });
		if (length(fk)) push(dns, { name: 'forwarding', children: fk });
	}

	for (let s in secs)
		if (s.type == 'domain' && s.opts.name != null && s.opts.ip != null)
			push(dns, { name: `host ${s.opts.name}`, children: [ { name: 'address', value: s.opts.ip } ] });

	for (let s in secs)
		if (s.type == 'cname' && s.opts.cname != null)
			push(dns, { name: `cname ${s.opts.cname}`,
				children: (s.opts.target != null) ? [ { name: 'target', value: s.opts.target } ] : [] });

	return length(dns) ? [ { name: 'service', children: [ { name: 'dns', children: dns } ] } ] : [];
}

function tags(ctx, steps, key) {
	if (key == 'host')
		return map(filter(ctx.sections(CFG), s => s.type == 'domain' && s.opts.name), s => s.opts.name);
	if (key == 'cname')
		return map(filter(ctx.sections(CFG), s => s.type == 'cname' && s.opts.cname), s => s.opts.cname);
	return [];
}

return {
	mounts: { 'service dns': GRAMMAR },
	set, del, render, tags
};
