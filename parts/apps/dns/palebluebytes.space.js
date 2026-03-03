var infra = require("./dns-data.json");

var CF = NewDnsProvider("cloudflare");
var REG_NONE = NewRegistrar("none");

var kelpyPub = infra.nodes.kelpy.public;

var records = [
	A("@", kelpyPub.ip4, CF_PROXY_ON),
	AAAA("@", kelpyPub.ip6, CF_PROXY_ON),


	MX("@", 11, "route1.mx.cloudflare.net."),
	MX("@", 63, "route2.mx.cloudflare.net."),
	MX("@", 94, "route3.mx.cloudflare.net."),

	TXT("@", "v=spf1 include:_spf.mx.cloudflare.net ~all"),
	TXT(
		"cf2024-1._domainkey",
		"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78km4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB",
	),
];

// Helper to add service records from nested categories
function addServices(svcs, isPublic) {
	for (var name in svcs) {
		var svc = svcs[name];
		var node = infra.nodes[svc.node];
		if (node) {
			var net = isPublic ? node.public : node.tailscale;

			// Default to OFF. If it's public AND proxy is exactly true, turn it ON.
			var proxyStatus =
				isPublic && svc.proxy === true ? CF_PROXY_ON : CF_PROXY_OFF;

			records.push(A(name, net.ip4, proxyStatus));
			if (net.ip6) {
				records.push(AAAA(name, net.ip6, proxyStatus));
			}
		}
	}
}

// Add services from both categories
addServices(infra.services.public, true);
addServices(infra.services.private, false);

D("palebluebytes.space", REG_NONE, DnsProvider(CF), records);
