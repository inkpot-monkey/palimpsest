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

/**
 * `manage_single_redirects` is dnscontrol's own opt-in gate, and it is a gate because the
 * behaviour behind it is destructive: with it on, dnscontrol deletes any Cloudflare
 * Single Redirect it does not find in this file, **including every rule created in the
 * web dashboard**. The zone's redirects are therefore this file's exclusively — adding
 * one through the UI means losing it on the next push. That is the same bargain this
 * config already makes for DNS records, extended to redirects, and it is only acceptable
 * because nothing else edits this zone by hand.
 */
const CF = NewDnsProvider("cloudflare", { manage_single_redirects: true });
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

/**
 * The IPv6 discard prefix (RFC 6666). Nothing listens there and nothing is meant to.
 */
const BLACKHOLE6 = "100::";

/**
 * Hostnames that exist only for Cloudflare to act on at the edge: no origin, no node,
 * no Caddy vhost, no uptime probe.
 *
 * These are deliberately NOT `settings.services` entries. A service entry means a real
 * listener on a node — it points at that node's IP, Caddy fronts it, and ADR-0019
 * uptime-probes it by default. A redirect has none of those things, so registering one
 * as a service would demand an origin that does not exist and a probe that could only
 * ever fail. Hardcoded here for the same reason `mta-sts` and `autoconfig` are: the
 * hostname IS the configuration, and there is nothing about it to derive.
 *
 * The address is a black hole because the request never reaches an origin — a
 * Cloudflare Single Redirect rule on the zone answers it at the edge first. The record
 * exists so that the hostname resolves and so that the rule has traffic to act on.
 *
 * **Proxied is load-bearing, not a preference.** Rules only run on proxied traffic;
 * grey-cloud one of these and it resolves, fails TLS against a black hole, and the rule
 * never fires, with nothing anywhere saying why.
 *
 * **The record and its rule are declared together and emitted together**, because either
 * one alone is a fault rather than a partial success: a record with no rule serves an
 * error page from a black hole, and a rule with no record never sees a request. Keeping
 * them in one entry is what stops a push from ever creating half of a redirect.
 */
interface EdgeRedirect {
  /** Where the host sends people. The path is collapsed to this, whatever was asked for. */
  target: string;
  /** Any of 301, 302, 303, 307, 308. */
  code: number;
}

const EDGE_ONLY: Record<string, EdgeRedirect> = {
  // Rations, the food Facet of Inventoria. A sibling of the app's host rather than a
  // subdomain of it, because a TLS wildcard matches one label and stops:
  // `*.palebluebytes.space` covers this, while `rations.inventoria.palebluebytes.space`
  // would need Advanced Certificate Manager.
  //
  // **302 and not 301**, decided on inventoria#276 §4.4 and worth not quietly
  // "improving" later. A 301 caches hard enough that a future misconfiguration *serving*
  // the app on this host would barely reach users — which reads as safety until you
  // notice it makes that misconfiguration invisible rather than harmless.
  //
  // The path is collapsed rather than preserved because the app has no client-side
  // routing, only query params, so there is no path to carry over. See inventoria#312.
  rations: {
    target: "https://inventoria.palebluebytes.space/food/",
    code: 302,
  },
};

function getEdgeOnlyRecords(domain: string): any[] {
  const recs: any[] = [];
  for (const name in EDGE_ONLY) {
    recs.push(AAAA(name, BLACKHOLE6, PROXY_ON));
    recs.push(edgeRedirect(name + "." + domain, EDGE_ONLY[name]));
  }
  return recs;
}

/**
 * One dynamic Single Redirect: collapse the path onto `target`, carry the query.
 *
 * dnscontrol only maintains **dynamic** redirects, so the static form's "preserve query
 * string" checkbox is not available and the query has to be carried by the expression
 * itself. `http.request.uri` is path *and* query, so stripping everything up to the first
 * `?` leaves `?foo=bar` when there is a query and the empty string when there is not,
 * which is exactly what that checkbox does.
 *
 * **The trailing `?` is deliberate and is the cheapest option this plan allows.** Two
 * tidier forms were written and both were refused by Cloudflare at push time:
 *
 *   - `substring(http.request.uri, len(http.request.uri.path))` — inside a rewrite
 *     expression `len()` takes a literal, not a field (`expected argument of kind
 *     Literal, but got Field`, error 20083).
 *   - `regex_replace(http.request.uri, "^[^?]*", "")` — `not entitled: the use of
 *     function regex_replace is not allowed, a Business plan or a WAF Advanced plan is
 *     required`.
 *
 * The expression language has no conditional on this plan either, so appending the query
 * only when one exists is not expressible. Hence `?` unconditionally: a request with a
 * query lands correctly, and one without lands on `…/food/?`, which is a cosmetic wart on
 * an address bar and nothing more. The alternative that avoids it is a *static* redirect
 * with Cloudflare's "preserve query string" checkbox, which dnscontrol does not manage —
 * so it would move this rule back into the dashboard and out of version control.
 *
 * Both rejections are recorded because they only happen on **push**: `preview` is happy
 * with all three, and the DNS record is created before the rule fails, so the next person
 * to "simplify" this gets a half-applied change and a hostname that resolves to nothing.
 *
 * **dnscontrol deletes any Single Redirect it does not recognise, including every rule
 * created in the web UI.** That is this feature's sharp edge and the reason the whole
 * redirect lives here rather than half here and half in the dashboard: once dnscontrol
 * manages one rule in a zone it is the only thing that may manage any of them.
 */
function edgeRedirect(host: string, r: EdgeRedirect): any {
  return CF_SINGLE_REDIRECT(
    "redirect " + host,
    r.code,
    'http.host eq "' + host + '"',
    'concat("' + r.target + '?", http.request.uri.query)',
  );
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

  // Service records and the edge-only redirect hosts are both the primary zone's; the
  // extra mail domains carry mail records and nothing else.
  const serviceRecs = isPrimary
    ? getServiceRecords(infra.services.public, true)
        .concat(getServiceRecords(infra.services.private, false))
        .concat(getEdgeOnlyRecords(domain))
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
