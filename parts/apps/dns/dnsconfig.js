/** @typedef {Object} NodeInfo
 * @property {string} hostName
 * @property {string} [domain]
 * @property {{ip4: string, ip6?: string}} [tailscale]
 * @property {{ip4: string, ip6?: string}} [public]
 */

/** @typedef {Object} ServiceInfo
 * @property {string} node
 * @property {number} [port]
 * @property {boolean} [proxy]
 */

/** @typedef {Object} InfraData
 * @property {Record<string, NodeInfo>} nodes
 * @property {{public: Record<string, ServiceInfo>, private: Record<string, ServiceInfo>}} services
 */

/**
 * Modern DNS configuration using DnsControl and NixOS infrastructure data.
 * This script is programmatically executed by a Nix app.
 */

/** @type {InfraData} */
var infra = require("./dns-data.json");

var CF = NewDnsProvider("cloudflare");
var REG_NONE = NewRegistrar("none");

var domain = "palebluebytes.space";

var records = [
    // Cloudflare Email Routing
    MX("@", 11, "route1.mx.cloudflare.net.", TTL(1)),
    MX("@", 63, "route2.mx.cloudflare.net.", TTL(1)),
    MX("@", 94, "route3.mx.cloudflare.net.", TTL(1)),

    TXT("@", "v=spf1 include:_spf.mx.cloudflare.net ~all"),
    ALIAS("@", "palebluebytes.palebluebytes.workers.dev.", CF_PROXY_ON),

    // DKIM for Cloudflare Email Routing
    TXT(
        "cf2024-1._domainkey",
        "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78km4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB",
        TTL(1)
    ),
];

/**
 * Helper to add service records (A/AAAA) based on node IP addresses.
 * @param {Record<string, ServiceInfo>} svcs
 * @param {boolean} isPublic
 */
function addServices(svcs, isPublic) {
    for (var name in svcs) {
        var svc = svcs[name];
        var node = infra.nodes[svc.node];
        if (!node) {
            console.warn("Warning: Node " + svc.node + " not found for service " + name);
            continue;
        }

        var net = isPublic ? node.public : node.tailscale;
        if (!net || !net.ip4) {
            console.warn(
                "Warning: No " + (isPublic ? "public" : "tailscale") +
                " IPv4 found for node " + svc.node + " (service " + name + ")"
            );
            continue;
        }

        // Proxy is only possible for public services and if explicitly enabled
        var proxyStatus = isPublic && svc.proxy === true ? CF_PROXY_ON : CF_PROXY_OFF;

        records.push(A(name, net.ip4, proxyStatus));
        if (net.ip6) {
            records.push(AAAA(name, net.ip6, proxyStatus));
        }
    }
}

// Add services from categories defined in Nix
addServices(infra.services.public, true);
addServices(infra.services.private, false);

// Define the domain with its provider and records
D(
    domain,
    REG_NONE,
    DnsProvider(CF),
    records,
    // Ignore records managed externally (e.g. by Cloudflare Dashboard)
    IGNORE_NAME("@", "MX"),
    IGNORE_NAME("@", "TXT"),
    IGNORE_NAME("cf2024-1._domainkey", "TXT"),
    DISABLE_IGNORE_SAFETY_CHECK
);
