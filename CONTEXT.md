# Palimpsest

A `flake-parts` NixOS configuration for a personal fleet of machines — desktops, a VPS, a Raspberry Pi audio host, and a pair of single-board LLM nodes — plus the bespoke services that run on them. This glossary fixes the language used across the repo so issues, ADRs, and commit messages stay consistent.

## Language

### Fleet & hosts

**Fleet**:
The whole set of machines this repo builds and deploys, as one unit.
_Avoid_: cluster, estate.

**Host**:
A single machine with a `nixosConfiguration`, named by a marine/animal codename (`kelpy`, `porcupineFish`, `stargazer`, …). The RK1 LLM boxes `rk1a`/`rk1b` are hosts too — "node" is just a more specific word for them, not a separate category.
_Avoid_: box, server.

**Always-on host** / **On-demand host**:
A host's **presence** — its intrinsic operational cadence, declared as `settings.nodes.<host>.presence` (`"always-on" | "on-demand"`). An **always-on host** runs 24/7 (`kelpy`, the `rk1a`/`rk1b` nodes, the `porcupineFish` audio host); an **on-demand host** runs only when in use (the interactive workstations and the laptop). This is a *fact about the machine*, not a monitoring policy: alert-worthiness is *derived* from it (an on-demand host being unreachable is expected, never a fault), so there is no separate opt-out. Distinct in shape from an **Expected-up service**, which is a uniform monitor-by-default *policy* with explicit opt-outs — presence is read off the host, not chosen per-host. Emitted as a Prometheus scrape label so boards derive alert-worthiness ([ADR-0026](docs/adr/0026-host-presence-scrape-label.md)).
_Avoid_: server/workstation as the *field* values (the axis is cadence, not machine type; and "server" is an avoided word for a host), role (an avoided word — see Profile).

**Tailnet node**:
A host that is **registered on the tailnet** and therefore has a **MagicDNS** name (`<hostName>.<tailnet>`), declared as `settings.nodes.<host>.onTailnet` (default `true`). Nearly every node is one; `potbelliedSeahorse` is not — it is a **nebula** lighthouse and runs no tailscale. Deliberately *orthogonal to* **presence**: a powered-off **on-demand host** is still a tailnet node, still resolves, and is still *meant* to read `up == 0`, whereas a non-tailnet node has no name to resolve at all — so monitoring **filters** on this but only **labels** by presence. The distinction is load-bearing because scrape targets are addressed by name: scraping a non-tailnet node yields not a `down` target but an unresolvable one, and **blocky** counts every such lookup as an error without logging it (palimpsest#165). The flag is a *declaration*, reconciled against each host's real `services.tailscale.enable` by the `host_fleet_coherence` check so it cannot drift from the machine.
_Avoid_: monitored (this is reachability, not policy — see **Expected-up service**), online/offline (that is presence), MagicDNS-enabled (MagicDNS is the tailnet's resolver feature, not a per-host toggle).

**Profile**:
A toggleable feature bundle enabled through the `custom.*` namespace, composing existing modules rather than being a long-running program itself. Two kinds, structurally distinct: a **NixOS profile** is fleet-shared (under `modules/nixos/profiles/`, toggled via `custom.profiles.*`); a **home profile** is per-user (under `users/<user>/home/`, toggled via `custom.home.profiles.*`).
_Avoid_: role, preset.

**Service module**:
A bespoke long-running program packaged and wired by this repo under `modules/nixos/services/` (e.g. the git-annex module, the music-sync drain). Distinct from a profile, which only toggles and configures.
_Avoid_: daemon, app.

**`custom.*`**:
The repo's own NixOS/home-manager option namespace (`custom.profiles.*`, `custom.home.profiles.*`, `custom.rk1.*`). All first-party configuration hangs off it. It stops where the contract's does: everything the contract puts on a host — the bound accounts, the machine's declared modes, the derived display surface — lives under `contract.*`, one prefix per party ([contract ADR-0026](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0026-one-option-prefix-per-party.md)). `custom.users.*` was this repo's spelling of that before the rule; it is `contract.users.*` now.

### Secrets

**Stash**:
The separate private git repository (`stash.git`) that holds all sops-encrypted secrets, consumed by this repo as the `secrets` flake input. Edits only take effect after commit + push + relock.
_Avoid_: vault, the secrets folder (it is a repo, not just a directory).

**Fleet secret / User secret**:
The Stash's two ownership classes. A *fleet secret* (`profiles/*.yaml`) is owned and consumed by the fleet itself — its host services, operator apps, and monitoring. A *user secret* (`users/<name>.yaml`) belongs to the **User** bundle and leaves with it when the user is extracted to its own repo. The invariant between them is **consumption purity**: fleet infrastructure must never depend on a *user* secret, so lifting a user out breaks nothing on the fleet. A user-owned credential that does fleet work is therefore relocated into a fleet file ([ADR-0025](docs/adr/0025-fleet-user-secret-consumption-purity.md)).
_Avoid_: treating the Stash as one undifferentiated bag — ownership is the seam the user's extraction hinges on.

**Admin key**:
The single age recipient (`&admin`) that can decrypt every secret in the fleet and re-key the rest. It is the same key as the user's personal SSH login/signing key.
_Avoid_: master key, root key.

**Signing key**:
The dedicated, non-admin key used for commit signing (and other private-key needs) on headless or code-executing hosts, so the admin key never has to leave a trusted machine.

**Operator read**:
An operator reading a single **secret** out of the **Stash** by hand at the terminal (the `secret` command). Distinct from feature-driven **provisioning**: the backend-agnostic rule (**Platform interface**) governs a *feature* getting a secret onto a *host*, so it never names sops — but this path is a human reading their own stash, and so deliberately *does* name the sops backend. It reads the **editable working-tree checkout**, not the flake-pinned/deployed value, so it answers "what is in my stash right now", never "what is host X actually running". Confined to the workstation, the only place the **admin key** and the checkout both live.
_Avoid_: fetch/pull (reserve for git); it reads a value, it does not sync the stash.

### Users & the host↔user contract

The split HAPPENED: hosts live here, the operator's users live in their own flake
(`git+ssh://git@github.com/palebluebytes/users`, private), and the interface between them is a third
repo ([`palebluebytes/host-user-contract`](https://github.com/palebluebytes/host-user-contract),
public, released). Any host binds any user by NAME and on rebuild that person's account and home
transparently work, while the host decides what the account may DO.

The contract's own `CONTEXT.md` is the authoritative glossary for its vocabulary and states the
distinctions this repo must not blur (mode vs grant, affordance vs grant vs granted, deny vs ban).
What follows is only what THIS repo needs: the terms that appear in its files, and the places where
the fleet — not the contract — makes the decision.

**User**:
A **member** of the pinned `users` flake: a directory holding `identity.json` (public identity +
login credential) and `user.nix` (which session shapes this person runs in, and the home for each).
Distinct from the **system account** (`users.users.<name>`) a host materialises from that identity
when it binds them. A user asks for **no powers at all** — it says only which shapes it runs in —
so an account's powers come from the host's **affordances** and the **mode** it was bound in, never
from anything the user wrote.
_Avoid_: account (reserve for the unix system account), profile.

**Contract** (the *contract kit*):
The small shared flake this repo and the `users` flake both depend on. It ships (1) the **schema** —
the identity option set, the mode registry and the feature registry; (2) the host-invariant
**realization** that turns that schema into a system account with the groups its grant and mode
confer; (3) the **producer surface** a users repo bakes homes through; and (4) a **conformance
suite** proving the promises against synthetic users on synthetic hosts, surfaced into this repo's
own `nix flake check` as `contract_conformance`. It is neither host nor user but the agreed
interface between them. Consumed as a flake input with `nixpkgs.follows`; edit behaviour THERE, then
`nix flake update contract` here ([contract ADR-0004](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0004-extract-contract-flake.md)).
Everything it puts on a host lives under `contract.*` — one option prefix per party
([contract ADR-0026](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0026-one-option-prefix-per-party.md)),
which is where this repo's own `custom.*` namespace stops.
_Avoid_: api, sdk, common.

**Mode** (session shape):
What a home IS — today `cli` (the **floor**, which every host runs) and `gui`. A host declares the
modes THE MACHINE CAN RUN as `contract.modes` (in `hosts/default.nix`: `[ "gui" ]` for the three
desktop seats, nothing at all for the servers, since the floor is implicit and unexcludable). A user
declares which modes it runs in, and a home is built per mode — so the bind SELECTS one rather than
composing them. A mode carries its own groups (a graphical session's input devices), which is why a
display is never a feature and a host never "grants gui": it runs the gui mode.
A mode may also publish **mode parameters** — `gui.desktop = "plasma"`, the user's intent, carried
in the binding index — which the seat may honour or ignore; the **session type** (wayland/x11) is
the seat's own business and no part of the contract.
_Avoid_: variant, profile, "the gui grant", calling the mode set a grant set.

**Affordance**:
What THIS host is willing to confer on ONE named person, stated at that person's bind and nowhere
else (`bindUsers { inkpotmonkey = { sudo = true; containers = true; }; }`). A decision about a
person, as against `contract.modes`, which is a capability of the box. It is now the WHOLE of the
grant: since a user asks for no powers, there is no user-side offer left to intersect with, so what
the bind states is exactly what the account gets.
_Avoid_: offer (retired — a user no longer asks for features), granting a mode.

**Grant**:
What a bound account HOLDS, written by the bind into `contract.users.<user>.granted.<feature>` and
readable there. Host-write-only: a user repo can never set its own grant, and **deny is simply the
absence of a grant** — an unafforded feature is off, and asking for nothing is never an error. The
privileged-group **clamp** is the teeth: groups a user names for itself are dropped unless granted,
which is why the hand-written break-glass `admin` on weedySeadragon must be afforded `sudo`
explicitly to keep its wheel (asserted by the `host_fleet_coherence` check).
_Avoid_: veto, "default-open".

**Feature** (capability):
A named power a host may confer, from the contract's own registry: `sudo`, `containers`,
`virtualization`, `nix-daemon`. Each confers privileged groups and nothing else — features are
about POWERS, so a display is a mode and not a feature. This fleet affords `sudo` + `containers` to
its operator and `sudo` alone to the laptop's co-admin; `virtualization` and `nix-daemon` are
afforded nowhere.
_Avoid_: flag, module (the gate is not itself a module), role (the `workstation` role was retired
in favour of these atomic powers).

**contractPackage** (the pre-built binding):
The artifact the `users` flake publishes per user × mode × system: home-manager's activation package
plus a `contract-manifest.json` sidecar declaring the contract version, the username and the mode.
A host binds it by reading the **binding index** — `contractUsers.<system>.<user>`, plain data with
no import-from-derivation — so it picks a package by READING rather than by building every one to
look inside. The home is therefore built with the users repo's OWN toolchain, and this fleet holds
zero users-repo internals: no package names, no variant labels, no identity paths. At activation a
`contract-activate-<user>` oneshot runs it inside a real login session
(`runuser -l`), which the `contract_seat` check boots and asserts.
_Avoid_: activationPackage (home-manager's own term for what this wraps), variant.

**Declaration** vs **Configuration**:
A user's **declaration** (`user.nix`) is READ AS DATA by bare `evalModules` with no home-manager
present — which is what lets a host learn somebody's modes without building anything. The
**configuration** is the home-manager module a mode points at, and is BUILT. The two are never the
same file.
_Avoid_: manifest for the declaration (the manifest is the contractPackage's json sidecar).

**Prohibition** vs **Incapacity**:
Two reasons a host lacks something, only one of which is a security statement. A **prohibition** is
a host forbidding what it otherwise could run — the security verb. An **incapacity** is a host
simply not being able to: a headless server has no display, so it declares no gui mode, which is a
fact about the machine and not a policy. Do not model incapacity as a ban; it dilutes the one word
that carries weight.
_Avoid_: "deny" for both (deny is the absence of a grant; prohibit is the active security veto).

**Safe set** (runtime-eligible features):
The features a RUNTIME binding could confer on a walk-up user without operator authorship — derived,
never declared, as those conferring no privileged group. **It is empty today**, and that is the
model working rather than a gap: every feature in the registry confers privileged groups, so
privilege is build-time-only and a flake URL typed at a greeter can escalate to nothing. What such a
user would still get is a graphical session, because gui is a **mode** the machine runs and not a
feature anybody grants.
_Avoid_: default-granted (that describes the disposition, not the membership rule).

**Binding path**:
How a person is bound to a host. This fleet uses **build-time binding** exclusively and operator-
authored: `hosts/default.nix` names each user and its affordances, and `bindContractUsers` reads the
index, selects the mode, confers the grant and realizes the account. The contract also ships a
**runtime binding** — the greeter, taking a flake URL, a username and a password — which **no host
here runs**: the desktop seats are SDDM + Plasma, and stargazer's `regreet` is explicitly disabled
in favour of it. The greeter's proofs are the contract's own; what this repo proves is its own bind
(`contract_seat`, `host_fleet_coherence`).
_Avoid_: enable (a user is never bound by enabling itself; the host's bind binds).

**Platform interface**:
The backend-neutral secrets seam: a consumer declares a *logical* secret and reads its resolved
runtime path, never naming sops. **It is this repo's own now** — it formerly lived in the contract,
which has since narrowed to "no secrets beyond the login credential" and dropped it, so the fleet
declares the interface as well as binding it (`modules/homeManager/options.nix`, types matching the
retired seam verbatim). Cite it as a fleet concept; the contract carries no secrets seam.
_Avoid_: secrets backend (that is the *implementation* of this interface — sops — not the interface).

### Matrix bridging

**The bridge**:
The hand-written Rust `jmap-matrix-bridge` appservice that connects a JMAP mailbox (Stalwart) to Matrix. Unqualified, "the bridge" means this one. It lives in its own repo (`palebluebytes/jmap-matrix-bridge`), consumed here as the `jmap-bridge` flake input; only the host glue (`modules/nixos/profiles/matrix/jmap-bridge.nix`) is in this repo. See [ADR-0016](docs/adr/0016-jmap-bridge-own-repo.md).
_Avoid_: connector, gateway.

**Homeserver**:
The Matrix server the fleet runs — `tuwunel` (conduwuit lineage). Bridges register with it declaratively via its appservice directory.

**Ghost**:
A Matrix puppet user (`@_jmap_*`) the bridge creates to represent an external email correspondent inside Matrix.
_Avoid_: puppet (reserve for double-puppeting), bot, virtual user.

**Contact room / Thread room**:
The Matrix room a bridged email conversation lives in. Email rooms are scoped **per email thread**, not per correspondent.
_Avoid_: channel, chat.

**Double-puppet**:
Logging the bridge in *as the real user* (not a ghost) so the user's own Matrix account appears to send bridged messages and auto-joins rooms. Established with a one-time login token, never declaratively.

### Agent sessions

**Server-side session**:
An agent session that runs inside the **opencode** server's instance on `rk1b` and is owned by that server rather than by whichever client started it. It outlives every client — a command can be sent, the laptop closed, the work continues — and any client (phone browser, Emacs, `opencode attach` over ssh) can reach the same session afterwards. Its working tree is on `rk1b`, addressed by the `x-opencode-directory` header; its status is read from the server's event stream, because there is no local process to watch.
_Avoid_: detached session (names a transient state, not where it runs — see **Detached**), remote session (true from the laptop, false from the phone).

**Laptop-local session**:
An agent session that *is* a process in an Emacs buffer on `sawtoothShark` — today a `claude` CLI in a `ghostel` PTY. It cannot outlive its client, because the process is the session. Retained as the fallback for trees `rk1b` does not have, for work needing a seat or a GUI, and for `claude`-only affordances.
_Avoid_: local session (a **server-side session** is local to `rk1b`), interactive session (both kinds are interactive).

**Detached**:
The state of a **server-side session** that has no client attached right now. It is a condition a session moves in and out of, not a kind of session: attaching Emacs makes a session un-detached without making it any less server-side. A **laptop-local session** can never be detached.
_Avoid_: backgrounded, headless, orphaned (nothing is unowned — the server owns it).

**Server-side tree**:
A working tree on `rk1b` that a **server-side session** can be started in. Trees are drawn from a small declared set rather than from every repository the operator owns, because a session is only findable if a client already knows the directory to ask about — an undeclared tree yields sessions nobody can get back to. A server-side tree carries the **same path as the laptop's tree for the same repository**, so one directory string names the same tree from every client.
_Avoid_: remote tree (true from the laptop, false from the phone), checkout (a session's tree is usually a worktree of one).

**Session branch**:
The branch a **server-side session**'s commits land on, named for the session itself. It is what makes a session's work identifiable after the fact and lets concurrent sessions share a repository without contending. A session branch always starts from an **explicitly named ref**, never from whatever its tree happened to be on, so a stale tree cannot silently become the basis of new work.
_Avoid_: agent branch (names the actor, not the unit of work), feature branch (a session branch is neither scoped to a feature nor meant to be long-lived).

### Local LLMs

**RK1 node** (or just **node**):
Either of the pair of Turing-Pi RK1 single-board computers, `rk1a` and `rk1b` (RK3588, 32 GB). A node is also a host (see **Host**); "node" just emphasises its place in this pair. The local-LLM serving stack was **retired** (ADR-0027): `rk1a` is the **voice node** (Home Assistant + Wyoming, moved off `rk1b` with fresh state, fits its 29 GB eMMC), and `rk1b` is the **media + monitoring node** (Navidrome on its NVMe `/var/cache`, plus the monitoring server and the aarch64 remote builder).

**Voice node**:
`rk1a` specifically — runs Home Assistant plus a local Wyoming voice pipeline (faster-whisper STT + piper TTS, CPU) for the smart-home setup (`custom.profiles.homeassistant`).

**Gateway**:
The `litellm` proxy on `kelpy` that presents remote (cloud) models under stable backend names (e.g. `qwen3-coder`, `deepseek-flash`). It no longer fronts a local model — the RK1 local LLM was retired (ADR-0027).

### Storage & data classes

> Fleet data splits into three classes by lifecycle, each with its own tool. The split exists because "retention", "backup", and "archival" name *different* mechanisms that were previously conflated.

**Blob**:
A large file that rarely mutates — a document, a media file, a photo, an ISO. Blobs live in **git-annex treated as a distributed filesystem**: the annex *is* the primary store, holding each blob as content under a tracked number of replicas spread across hosts and remotes, not a backup of a copy that lives elsewhere.
_Avoid_: asset, attachment.

**Telemetry**:
Constantly-appended time-series — VictoriaMetrics samples and VictoriaLogs lines. Aged out by a **retention** window, but **not disposable**: it must survive loss of the host that collects it (if `rk1b` dies, recent telemetry should still be recoverable). So telemetry has both a retention window *and* a backup, unlike a pure scratch cache.
_Avoid_: metrics (one of its two kinds), logs (the other), monitoring data.

**Service state**:
Small, mutating state that must survive disk loss — sops material, a service's `/var/lib` directory, an sqlite DB. Backed up by **restic** to off-site (rsync.net).
_Avoid_: persistent data (too broad — telemetry persists too).

**Retention** (telemetry-only):
The auto-deletion window after which old samples/log-lines are dropped, sized so a class of telemetry *cannot* outgrow its disk partition. The word is reserved for this TSDB-native expiry — it is **not** backup (off-site copy) nor archival (git-annex replicas).
_Avoid_: using "retention" for backup keep-policy or for how long blobs are kept.

**Backup**:
A point-in-time off-site copy made by **restic**, kept under a keep-daily/weekly/monthly policy, used to *restore* after data loss. Distinct from **archival** (git-annex replication of blobs) and from **retention** (in-place expiry).
_Avoid_: archive, snapshot (reserve "snapshot" for a TSDB-consistent point-in-time the backup is taken *from*).

### Networking & DNS

> The tailnet's DNS is **split-horizon with ad-blocking**, served by **blocky** ([ADR-0011](docs/adr/0011-blocky-runtime-tailscale-dns.md), [ADR-0023](docs/adr/0023-fleet-dns-dual-blocky.md)). The terms below fix how names resolve and who depends on the DNS plane.

**Dual blocky**:
The fleet's DNS redundancy: **blocky** runs on both `kelpy` and `rk1b`, and both are the tailnet's **global nameservers**. `rk1b` replaced `porcupineFish`, whose IP had drifted out of the admin console. Redundancy works because, with **Override local DNS** on, tailscale queries all global nameservers **in parallel and takes the fastest** — so one being down is invisible, not a failover delay. Both run identical config, so the winning answer is the same.
_Avoid_: primary/secondary DNS (there is no failover order — it is parallel), failover.

**Global nameserver**:
A resolver IP set in the **tailscale admin console** that clients with `acceptDns = true` (and the unmanaged phone) send all queries to. The fleet's are `kelpy` and `rk1b`'s tailscale IPs. Entered as **IPs, not MagicDNS names**, so they drift on a full reflash and must be re-entered by hand — the drift that silently killed the old `porcupineFish` secondary. Distinct from a blocky **upstream** (where blocky itself forwards) and a **local blocky** (a host resolving via its own `127.0.0.1`).
_Avoid_: DNS server (ambiguous).

**Split-horizon**:
Serving a different answer for `*.palebluebytes.space` inside the tailnet than the public internet does — blocky maps a service FQDN to a node's **tailscale** IP (private services) or **public** IP (public services), so `monitoring.palebluebytes.space` resolves to the tailnet address for tailnet clients. The reason a co-equal public resolver cannot be mixed into the nameserver list: it does not know these answers.
_Avoid_: split DNS (tailscale's feature of that name is a different, per-domain mechanism we do not use here).

**Fail-open** (rejected as a public nameserver):
The idea of listing a public resolver (`1.1.1.1`) as an extra **global nameserver** so devices keep internet if every blocky is down. **Not done** ([ADR-0023](docs/adr/0023-fleet-dns-dual-blocky.md)): under parallel-query it wins most races against blocky's DoH, gutting **ad-block** and hijacking **split-horizon**. The two blockies are the availability story instead.
_Avoid_: fallback resolver, upstream (blocky's real upstreams are a separate thing).

**acceptDns posture**:
Per-host choice of whether tailscale manages the host's resolver. **Clients** (phone, the roaming laptops) set `true` → they use the **global nameservers** and get **ad-block** + internal names. **Servers** set `false` → independent of the DNS plane (LAN DNS + build-time `/etc/hosts` pins), so a blocky/`kelpy` outage cannot break them; the two DNS hosts are `false` *and* run a **local blocky**. Laptops deliberately stay clients rather than running a local blocky, because a local DoH resolver breaks **captive portals** while roaming.
_Avoid_: MagicDNS toggle (`acceptDns` is broader than MagicDNS).

**Service FQDN**:
The full `<service>.palebluebytes.space` name a service is reached by. Kept full (never bare `<service>`) because Caddy fronts services with public **Let's Encrypt** certs and a browser validates the cert against the typed name — no public CA issues for a bare single-label name, so shortening breaks HTTPS. Host **codenames** are already bare via **MagicDNS** (`ssh rk1b`); only *service* names are constrained.
_Avoid_: short name, hostname (a service FQDN is not a host).

**Tailnet-scoped**:
The access posture of a **private service**: reachable only from the tailnet, enforced at the Caddy edge by refusing any request whose source address is outside the tailnet's range. It is a **membership** boundary, not an **identity** one — it admits *every* node on the tailnet with no per-user granularity, and the tailnet is deliberately not single-person (friends join it to reach the **friends' music platform**, [ADR-0027](docs/adr/0027-navidrome-friends-music-platform.md)). So "tailnet-scoped" answers *how the service is reached*, never *who may use it*: a service whose exposure is privileged (code execution, credential writes) needs its own authentication as well, and each new private service must decide that for itself rather than inheriting it.
_Avoid_: private (says which registry half it sits in, not what guards it), internal-only (names the mechanism), authenticated, secured (it is neither).

### Monitoring & alerting

> The existing **monitoring stack** (VictoriaMetrics/VictoriaLogs/Grafana/Vector/node-exporter) is *collection-only* — it stores metrics and logs but raises no alerts. The terms below name the alerting tier layered on top of it.

**Peer IP pin**:
The build-time `/etc/hosts` entry (via `networking.hosts`) that maps a node's **tailscale IP** — read from the `settings.nodes` declaration — to its hostname, so the **monitoring server** can resolve scrape targets and a **client**'s Vector can reach its receiver. Membership comes from the **declaration**; resolution is the pinned tailscale IP, consulted by glibc *before* any resolver — deliberately *not* DNS, because the tailnet's DNS is centralised on `kelpy`'s blocky and the monitoring host must stay independent of the host it watches. Build-time is safe because a tailscale IP drifts only on a full reflash, which forces the redeploy that regenerates the pin. See [ADR-0022](docs/adr/0022-monitoring-runtime-peer-resolution.md).
_Avoid_: `file_sd` (considered and rejected — a runtime generator buys nothing here), DNS resolution (the whole point is to avoid the kelpy-hosted DNS plane).

**Uptime watcher** (or **watcher**):
The off-host process that probes the fleet's services over the network and alerts when one stops answering — Gatus on the always-on media + monitoring node `rk1b`, deliberately *not* on `kelpy`, so it can still observe `kelpy` itself failing. Distinct from the **monitoring stack**, which only collects.
_Avoid_: monitor, uptime robot.

**Reachability probe**:
A black-box check that a service *answers* on its endpoint (HTTP/TCP/ICMP). Catches a service that is down **or** running-but-degraded, but is blind to a service with no listening port.
_Avoid_: ping (too narrow), healthcheck (reserve for a single named check).

**Unit-state check**:
The white-box counterpart, run on the host itself: it asserts each **expected-up service**'s systemd unit is actually `active`. It catches what a reachability probe cannot — a port-less service, or a unit that exits *cleanly yet dead* (Stalwart's store-misconfig abort exits `0`, so it is `inactive`, never `failed`, and an `OnFailure=`/failed-state alert would miss it).
_Avoid_: failure hook (it must catch inactive-not-failed, not only failures).

**Expected-up service**:
A service classified as one that must always be `active`, and therefore subject to alerting. Classification is **monitor-by-default** — derived from the `settings.services.*` registry so a new service is watched unless explicitly opted out — and enforced by a `nix flake check` that fails on any unclassified service, so nothing can silently go unmonitored.
_Avoid_: critical service (criticality is a separate axis), watched service.

**Infra Alerts room**:
The dedicated Matrix room (inside the **Hookshot Space**) where uptime alerts land, delivered through a hookshot generic webhook so the **watcher** and the **unit-state check** share one delivery path. Kept apart from operational rooms so alerts stay scannable and muteable. It is the **primary** channel, used only while `kelpy` is up.
_Avoid_: alerts channel.

**Out-of-band channel**:
A notification path that shares none of `kelpy`'s failure domain, used for the alerts the Matrix path can't carry (because Matrix runs on `kelpy`). Its one realized kind is an **off-site push** delivered through the **Push relay** — `rk1b`'s **watcher** notifies it when the Matrix delivery path itself is down, reporting "`kelpy` / the Matrix path is down" while the site is still online. Its named-but-unbuilt counterpart is an external **dead-man's switch** that would report a *full-site blackout* by alerting on the *silence* of an expected periodic ping — the only mechanism needing nothing at home alive. The deliberate counterpart to the rejected idea of a highly-available Matrix.
_Avoid_: fallback channel (too vague), secondary Matrix.

**Push relay**:
The self-hosted, ntfy-compatible **web-push** service that realizes the **Out-of-band channel** — hosted off-site (a Cloudflare Worker today) so it survives `kelpy` being down, it accepts a publish from the **watcher** and delivers a browser push notification to the operator's installed phone PWA. Deliberately *ntfy-shaped* so the **watcher** drives it through Gatus's stock `ntfy` alerter and any ntfy client can target it. Chosen over the public ntfy.sh (paid) and a self-hosted ntfy on home hardware (wrong failure domain).
_Avoid_: ntfy (the relay is ntfy-*compatible*, not ntfy), push server.

### Audio & music

**Audio host**:
`porcupineFish`, the Raspberry Pi 4 + HiFiBerry DAC that drives the speakers. An **always-on host** whose whole job is owning its audio device — treated as a self-contained appliance, so audio decisions (Spotify, playback) live on it rather than depending on another host.
_Avoid_: media host (reserve for `rk1b`, which serves the *library*), audio server.

**Device owner**:
The single process that holds the DAC's ALSA hardware device (`hw:sndrpihifiberry`) — which only one process may open at a time. As of [ADR-0031](docs/adr/0031-porcupinefish-sound-server-audio.md) this is **`snapclient`**, held open 24/7 so the I²S clock never churns (the wedge cure); every source feeds `snapserver` rather than opening the card itself. Previously it was `spotifyd` directly.
_Avoid_: sink, output (too generic — this is specifically the exclusive ALSA holder).

**Communal speaker**:
The model for the **audio host** as *a place, not a person*: all playback through its speakers is one **listening identity**, not attributed per-human. Per-person stats still accrue when someone plays on their *own* device as themselves; attributing *speaker* plays per-person is a deliberately-deferred future improvement (ADR-0031).
_Avoid_: shared speaker (ambiguous — this is about identity, not access), multi-user speaker.

**Listening identity**:
Who a play is attributed to for stats. On the **communal speaker** the identity is the dedicated `music-assistant` Navidrome account (Navidrome native counts) and a single **ListenBrainz** account (the unified cross-source history for Spotify + Navidrome). Distinct from the human who pressed play, which this model does not track for speaker plays.
_Avoid_: listener, user (overloaded — reserve **User** for the host↔user bundle).

**Control plane** (audio):
Which app drives which source to the **audio host**. Two, kept separate by design: the **Spotify plane** (native Spotify app → the Pi's librespot Connect stream) and the **library plane** (Home Assistant / Music Assistant → the Navidrome library). Each source keeps its best remote; they are not unified into one app.
_Avoid_: remote, controller (reserve for a specific process).

**Stream-switcher** (the arbiter):
The watcher on the **audio host** that makes play-in-either-source "just work". Each source feeds `snapserver` as a *separate* stream, and snapcast does not auto-follow the active one; the switcher subscribes to the control API and, on a debounced `idle → playing` edge, binds the **device owner**'s group to the stream that just started. Event-driven off stream *status* (not silence-sniffing) and debounced so a between-tracks idle dip never flaps the output — last-activated-wins ([#96](docs/adr/0031-porcupinefish-sound-server-audio.md)).
_Avoid_: router, mixer (it routes *which* stream plays, it does not mix or set volume).

**Volume reference**:
How volume is controlled on the speaker, per source (not one shared number). **Music Assistant** drives `snapclient`'s **hardware "Digital" mixer** directly for its own volume. **Spotify** is controlled by the **phone app slider**, which drives librespot's own volume (`--volume-ctrl cubic`) — librespot 0.8's pipe backend can't report volume without also applying it, so the app slider *can't* drive the hardware mixer without double-attenuating. To keep Spotify from inheriting the low level MA may have left on the shared mixer, the **stream-switcher** pins the hardware mixer to a reference (100%) whenever it routes to Spotify, leaving the app slider as the only gain that varies (#96).
_Avoid_: "single master" (deliberately abandoned — the app-slider requirement forced per-source volume), software volume (only Spotify's is digital; MA's is the hardware mixer).
_Avoid_: software volume (the point is that it's the DAC's hardware mixer, at full bit-depth).
