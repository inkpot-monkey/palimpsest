interface NetInfo {
  ip4: string;
  ip6?: string;
}

interface NodeInfo {
  hostName: string;
  domain?: string;
  tailscale?: NetInfo;
  public?: NetInfo;
}

interface ServiceInfo {
  edge: string;
  port?: number;
  proxy?: boolean;
}

// One record exactly as Stalwart's /api/dns/records returns it (FQDN name, textual content).
interface StalwartRecord {
  type: string;
  name: string;
  content: string;
}

interface InfraData {
  nodes: Record<string, NodeInfo>;
  services: {
    public: Record<string, ServiceInfo>;
    private: Record<string, ServiceInfo>;
  };
  primaryDomain: string;
  mail: {
    domain: string;
    extraDomains?: string[];
  };
  // The authoritative mail/security records (MX, SPF, DMARC, TLSRPT, SRV, DKIM, DANE, …)
  // for each domain, fetched from Stalwart's management API by the `dns` app at run time.
  mailRecords?: Record<string, StalwartRecord[]>;
  // "all" (default) manages the whole zone; "mail" manages ONLY the mail/security records
  // for the mail domains and IGNOREs everything else — used by the acme cert-renewal hook
  // to reconcile DANE/TLSA without touching service records. See the loop below.
  scope?: string;
}

/**
 * DnsControl configuration — the SINGLE SOURCE OF TRUTH for the whole zone.
 *
 * Ownership is explicit:
 *   - Per-service A/AAAA records come from `settings.services`.
 *   - The mail/security records (MX, SPF, DMARC, TLSRPT, SRV, DKIM, DANE/TLSA, the extra
 *     domains' mail CNAME) come straight from Stalwart — the `dns` app fetches them from
 *     /api/dns/records and we emit them verbatim, so they can never drift from the authority.
 *   - The few records Stalwart doesn't manage (the primary's mail host A/AAAA and the
 *     Caddy-served MTA-STS + autoconfig/autodiscover) are added below. The apex itself is a
 *     Cloudflare Worker Custom Domain (worker-managed), so dnscontrol IGNOREs it.
 *
 * In-flight ACME DNS-01 challenge records are IGNOREd so a push can't delete one mid-renewal
 * (both Caddy and Stalwart issue certs via Cloudflare DNS-01).
 */

// @ts-ignore
const infra: InfraData = require("./dns-data.json");

const CF = NewDnsProvider("cloudflare");
const REG_NONE = NewRegistrar("none");

const KELPY = infra.nodes.kelpy;
const PUB4 = KELPY.public!.ip4;
const PUB6 = KELPY.public!.ip6;

// common record values. PROXY_ON is used by any public service that opts in via
// `proxy = true`; PROXY_OFF keeps records DNS-only (grey-cloud).
const PROXY_ON = CF_PROXY_ON;
const PROXY_OFF = CF_PROXY_OFF;

/**
 * Per-service A/AAAA records. Public services resolve to a node's public IP (optionally
 * Cloudflare-proxied); private services resolve, DNS-only, to a node's tailscale IP —
 * not publicly routable, so they're reachable only from the tailnet.
 */
function getServiceRecords(
  svcs: Record<string, ServiceInfo>,
  isPublic: boolean,
): any[] {
  const recs: any[] = [];
  for (const name in svcs) {
    if (name === "mail") continue; // mail host is emitted by getMailRecords

    const svc = svcs[name];
    const node = infra.nodes[svc.edge];
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

// FQDN ("mail.example.com." / "example.com.") -> dnscontrol label ("mail" / "@").
function relLabel(fqdn: string, domain: string): string {
  const s = fqdn.charAt(fqdn.length - 1) === "." ? fqdn.slice(0, -1) : fqdn;
  if (s === domain) return "@";
  const suffix = "." + domain;
  const i = s.length - suffix.length;
  if (i > 0 && s.slice(i) === suffix) return s.slice(0, i);
  return s;
}

// Map one Stalwart record to its dnscontrol equivalent (content is whitespace-delimited).
function emitStalwart(domain: string, r: StalwartRecord): any {
  const n = relLabel(r.name, domain);
  const p = r.content.split(" ");
  switch (r.type) {
    case "A":
      return A(n, r.content);
    case "AAAA":
      return AAAA(n, r.content);
    case "CNAME":
      return CNAME(n, r.content);
    case "TXT":
      return TXT(n, r.content);
    case "MX":
      return MX(n, parseInt(p[0], 10), p.slice(1).join(" "));
    case "SRV":
      return SRV(
        n,
        parseInt(p[0], 10),
        parseInt(p[1], 10),
        parseInt(p[2], 10),
        p.slice(3).join(" "),
      );
    case "TLSA":
      return TLSA(
        n,
        parseInt(p[0], 10),
        parseInt(p[1], 10),
        parseInt(p[2], 10),
        p.slice(3).join(" "),
      );
    default:
      throw "unsupported Stalwart record type: " + r.type;
  }
}

/**
 * The records for a mail domain that Stalwart does NOT manage — the apex Worker, the
 * primary's mail-host address (Stalwart omits it), and the Caddy-served MTA-STS +
 * autoconfig/autodiscover endpoints — followed by everything Stalwart does manage.
 */
function getMailRecords(domain: string, isPrimary: boolean): any[] {
  const recs: any[] = [];

  // The primary domain holds the real mail-host A/AAAA; extra domains get a CNAME to it
  // straight from Stalwart, so nothing to add for them here.
  if (isPrimary) {
    recs.push(A("mail", PUB4));
    if (PUB6) recs.push(AAAA("mail", PUB6));
  }

  // MTA-STS + mail-client autoconfig (served by Caddy — not part of Stalwart's record set).
  recs.push(CNAME("mta-sts", "mail." + domain + "."));
  recs.push(TXT("_mta-sts", "v=STSv1; id=2026051001;"));
  recs.push(CNAME("autoconfig", "mail." + domain + "."));
  recs.push(CNAME("autodiscover", "mail." + domain + "."));

  // Everything Stalwart manages (MX, SPF, DMARC, TLSRPT, SRV, DKIM, DANE, …), verbatim.
  const stalwart = (infra.mailRecords && infra.mailRecords[domain]) || [];
  for (let k = 0; k < stalwart.length; k++)
    recs.push(emitStalwart(domain, stalwart[k]));

  return recs;
}

// Every mail domain (primary first); the primary zone also carries the service records.
const primary = infra.mail.domain;
const mailDomains = [primary].concat(infra.mail.extraDomains || []);

// "mail" scope reconciles only the mail/security records and leaves the rest of each zone
// untouched (IGNORE everything else). The cert-renewal hook uses it to push refreshed
// DANE/TLSA without risking any other record. "all" (default) manages the whole zone.
const mailOnly = infra.scope === "mail";

for (let d = 0; d < mailDomains.length; d++) {
  const domain = mailDomains[d];
  const isPrimary = domain === primary;

  if (mailOnly) {
    // Declare only the mail records; IGNORE("*") leaves every other record in the zone
    // alone. The managed mail records deliberately overlap that wildcard, so the ignore
    // safety check must be disabled for this domain.
    D(
      domain,
      REG_NONE,
      DnsProvider(CF),
      getMailRecords(domain, isPrimary),
      DISABLE_IGNORE_SAFETY_CHECK,
      IGNORE("*", "*", "*"),
    );
    continue;
  }

  const serviceRecs = isPrimary
    ? getServiceRecords(infra.services.public, true).concat(
        getServiceRecords(infra.services.private, false),
      )
    : [];

  // The primary apex is a Cloudflare Worker Custom Domain (worker-managed): leave its
  // address record alone. dnscontrol still manages the apex MX/TXT (mail) for every domain.
  const apexIgnore = isPrimary ? [IGNORE("@", "A,AAAA,CNAME")] : [];

  D(
    domain,
    REG_NONE,
    DnsProvider(CF),
    serviceRecs,
    getMailRecords(domain, isPrimary),
    apexIgnore,
    // Never purge in-flight ACME DNS-01 challenges (Caddy + Stalwart both use them).
    IGNORE("_acme-challenge", "TXT"),
    IGNORE("_acme-challenge.**", "TXT"),
  );
}
