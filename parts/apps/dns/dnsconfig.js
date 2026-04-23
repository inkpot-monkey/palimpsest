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
 * @property {string} primaryDomain
 * @property {string} mailDomain
 */

/**
 * Modern DNS configuration using DnsControl and NixOS infrastructure data.
 * This script is programmatically executed by a Nix app.
 */

/** @type {InfraData} */
const infra = require("./dns-data.json");

const CF = NewDnsProvider("cloudflare");
const REG_NONE = NewRegistrar("none");

const KELPY = infra.nodes.kelpy;
const PRIMARY_DOMAIN = infra.primaryDomain;
const MAIL_DOMAIN = infra.mailDomain;

// common record values
const PROXY_ON = CF_PROXY_ON;
const PROXY_OFF = CF_PROXY_OFF;
const TTL_SHORT = TTL(1);

/**
 * Helper to add service records (A/AAAA) based on node IP addresses.
 * @param {Record<string, ServiceInfo>} svcs
 * @param {boolean} isPublic
 * @returns {any[]}
 */
function getServiceRecords(svcs, isPublic) {
    const recs = [];
    for (const name in svcs) {
        const svc = svcs[name];
        const node = infra.nodes[svc.node];
        if (!node) continue;

        const net = isPublic ? node.public : node.tailscale;
        if (!net || !net.ip4) continue;

        const proxyStatus = isPublic && svc.proxy === true ? PROXY_ON : PROXY_OFF;

        recs.push(A(name, net.ip4, proxyStatus));
        if (net.ip6) {
            recs.push(AAAA(name, net.ip6, proxyStatus));
        }
    }
    return recs;
}

/**
 * Shared Stalwart Mail records
 * @param {string} domain 
 * @param {string} id Unique ID for MTA-STS tracking
 * @returns {any[]}
 */
function getStalwartRecords(domain, id) {
    return [
        A("mail", KELPY.public.ip4),
        AAAA("mail", KELPY.public.ip6),
        MX("@", 10, "mail." + domain + "."),

        // Security: SPF
        TXT("@", "v=spf1 mx ip4:" + KELPY.public.ip4 + (KELPY.public.ip6 ? " ip6:" + KELPY.public.ip6 : "") + " -all"),

        // Security: DMARC (Quarantine)
        TXT("_dmarc", "v=DMARC1; p=quarantine; adkim=s; aspf=s;"),

        // Security: MTA-STS
        CNAME("mta-sts", "mail." + domain + ".", PROXY_OFF),
        TXT("_mta-sts", "v=STSv1; id=" + id + ";"),

        // Client Autoconfig/Autodiscover
        SRV("_submission._tcp", 0, 1, 587, "mail." + domain + "."),
        SRV("_imaps._tcp", 0, 1, 993, "mail." + domain + "."),
    ];
}

/**
 * Helper to add standard server records (A/AAAA root + mail)
 * @param {string} domain 
 * @returns {any[]}
 */
function getBaseServerRecords(domain) {
    const recs = [
        A("@", KELPY.public.ip4),
        AAAA("@", KELPY.public.ip6),
    ];

    if (domain === MAIL_DOMAIN) {
        recs.push(...getStalwartRecords(domain, "2026042302"));
    } else {
        // Fallback: just point the 'mail' subdomain to the server
        recs.push(A("mail", KELPY.public.ip4));
        recs.push(AAAA("mail", KELPY.public.ip6));
    }
    return recs;
}

// --- Domain: palebluebytes.space (Primary) ---
D(
    PRIMARY_DOMAIN,
    REG_NONE,
    DnsProvider(CF),
    getBaseServerRecords(PRIMARY_DOMAIN),
    [
        ALIAS("@", "palebluebytes.palebluebytes.workers.dev.", PROXY_ON),
    ],
    getServiceRecords(infra.services.public, true),
    getServiceRecords(infra.services.private, false),
    IGNORE_NAME("*._domainkey", "TXT"),
    DISABLE_IGNORE_SAFETY_CHECK
);

// --- Domain: palebluebytes.xyz (Secondary) ---
D(
    "palebluebytes.xyz",
    REG_NONE,
    DnsProvider(CF),
    getBaseServerRecords("palebluebytes.xyz"),
    IGNORE_NAME("*._domainkey", "TXT"),
    DISABLE_IGNORE_SAFETY_CHECK
);

