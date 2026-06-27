//! Cloudflare Worker shell for the out-of-band web-push relay (ADR-0027).
//!
//! The thin, swappable platform adapter around `push-relay-core`: HTTP routing,
//! Workers KV (subscription storage), secrets, outbound `fetch`, and serving the
//! PWA. All the crypto lives in the portable core crate; this file is the part
//! that would be rewritten (small) to move the relay to Spin/WASI.
//!
//! Routes:
//!   GET  /                 → the PWA
//!   GET  /sw.js,/manifest.json,/icon.svg
//!   GET  /vapidPublicKey   → the VAPID public key (the PWA's applicationServerKey)
//!   POST /sub              → register a subscription under a topic (subscribe = knowing the topic)
//!   POST /<topic> or POST / → ntfy-style publish (Bearer publish-token; topic in
//!                            the path or the JSON body) → web-push every subscriber
//!   POST /heartbeat        → dead-man's beat from rk1b (Bearer publish-token)
//!   (cron) scheduled       → alert the phone if rk1b's heartbeat goes silent
//!
//! Bindings (wrangler.toml): KV namespace `SUBS`; secrets `VAPID_PRIVATE`,
//! `PUBLISH_TOKEN`, `SUBSCRIBE_TOPIC` (the one canonical phrase /sub validates
//! against); vars `VAPID_PUBLIC`, `VAPID_SUBJECT`.
//!
//! NOTE: scaffold — verify at deploy (push-relay issues 01–03, 05). The core crate
//! it calls is unit-tested; this shell's Workers-API glue is exercised on deploy.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::json;
use worker::*;

#[derive(Deserialize)]
struct SubBody {
    topic: String,
    endpoint: String,
    p256dh: String, // base64url
    auth: String,   // base64url
}

#[derive(Serialize, Deserialize)]
struct StoredSub {
    endpoint: String,
    p256dh: String,
    auth: String,
}

const TTL_SECONDS: u32 = 86_400;

#[event(fetch)]
async fn fetch(mut req: Request, env: Env, _ctx: Context) -> Result<Response> {
    let method = req.method();
    let path = req.path();

    match (method.clone(), path.as_str()) {
        (Method::Get, "/") => serve(include_str!("../../public/index.html"), "text/html"),
        (Method::Get, "/sw.js") => serve(include_str!("../../public/sw.js"), "text/javascript"),
        (Method::Get, "/manifest.json") => serve(
            include_str!("../../public/manifest.json"),
            "application/manifest+json",
        ),
        (Method::Get, "/icon.svg") => serve(include_str!("../../public/icon.svg"), "image/svg+xml"),
        (Method::Get, "/vapidPublicKey") => {
            serve_owned(env.var("VAPID_PUBLIC")?.to_string(), "text/plain")
        }
        (Method::Post, "/sub") => subscribe(&mut req, &env).await,
        (Method::Post, "/heartbeat") => heartbeat(&mut req, &env).await,
        (Method::Post, p) => publish(&mut req, &env, p.trim_start_matches('/')).await,
        _ => Response::error("not found", 404),
    }
}

// --- dead-man's switch (ADR-0027 / push-relay issue 06) ---------------------
// The one failure the out-of-band push can't catch is a full-site blackout: it
// takes out rk1b too, so nothing at home is left to *send* an alert. So invert
// the logic — rk1b beats to `/heartbeat` on a schedule, and a Cloudflare Cron
// Trigger (the `scheduled` handler) alerts the phone on the *silence*. The whole
// decision lives off-site; the only home component is the beat, whose absence is
// the signal.

/// rk1b is the always-on watcher and the meaningful liveness sentinel.
const DEADMAN_HOST: &str = "rk1b";
/// Alert once no beat has arrived for this long (≈ 3 missed 5-min beats).
const DEADMAN_STALE_MS: u64 = 15 * 60 * 1000;

fn heartbeat_key(host: &str) -> String {
    format!("heartbeat:{host}")
}
fn deadman_state_key(host: &str) -> String {
    format!("deadman:{host}")
}

/// Record a liveness beat (Bearer publish-token). rk1b only beats while its Gatus
/// watcher is active, so silence means "monitoring stopped", not just "box up".
async fn heartbeat(req: &mut Request, env: &Env) -> Result<Response> {
    let token = env.secret("PUBLISH_TOKEN")?.to_string();
    if !authorized(req, &token) {
        return Response::error("unauthorized", 401);
    }
    let raw = req.text().await.unwrap_or_default();
    let host = serde_json::from_str::<serde_json::Value>(&raw)
        .ok()
        .as_ref()
        .and_then(|v| v.get("host"))
        .and_then(|x| x.as_str())
        .unwrap_or(DEADMAN_HOST)
        .to_string();
    let kv = env.kv("SUBS")?;
    let now = Date::now().as_millis();
    kv.put(&heartbeat_key(&host), now.to_string())?
        .execute()
        .await?;
    Response::ok("beat")
}

#[event(scheduled)]
async fn scheduled(_event: ScheduledEvent, env: Env, _ctx: ScheduleContext) {
    if let Err(e) = run_deadman(&env).await {
        console_log!("deadman: error: {e:?}");
    }
}

/// Cron-driven silence detector: alert once on staleness, recover once on return,
/// no re-alerts in between (quiet semantics mirror the rest of ADR-0026).
async fn run_deadman(env: &Env) -> Result<()> {
    let kv = env.kv("SUBS")?;
    // No beat ever recorded (fresh deploy / OOB disabled) → nothing to judge yet.
    let last_seen = match kv.get(&heartbeat_key(DEADMAN_HOST)).text().await? {
        Some(s) => s.parse::<u64>().unwrap_or(0),
        None => return Ok(()),
    };
    let now = Date::now().as_millis();
    let silent_ms = now.saturating_sub(last_seen);
    let stale = silent_ms > DEADMAN_STALE_MS;
    let alerted = kv
        .get(&deadman_state_key(DEADMAN_HOST))
        .text()
        .await?
        .as_deref()
        == Some("alerted");

    if stale && !alerted {
        let topic = env.secret("SUBSCRIBE_TOPIC")?.to_string();
        let mins = silent_ms / 60_000;
        deliver(
            env,
            &topic,
            "⚠️ rk1b is silent",
            &format!(
                "No heartbeat from {DEADMAN_HOST} for {mins} min — the site may be down (power/ISP). The normal alert paths can't reach you."
            ),
        )
        .await?;
        kv.put(&deadman_state_key(DEADMAN_HOST), "alerted")?
            .execute()
            .await?;
    } else if !stale && alerted {
        let topic = env.secret("SUBSCRIBE_TOPIC")?.to_string();
        deliver(
            env,
            &topic,
            "✅ rk1b heartbeat resumed",
            &format!("{DEADMAN_HOST} is beating again — the site is back."),
        )
        .await?;
        kv.put(&deadman_state_key(DEADMAN_HOST), "ok")?
            .execute()
            .await?;
    }
    Ok(())
}

fn serve(body: &str, content_type: &str) -> Result<Response> {
    serve_owned(body.to_string(), content_type)
}

fn serve_owned(body: String, content_type: &str) -> Result<Response> {
    let mut res = Response::ok(body)?;
    res.headers_mut().set("content-type", content_type)?;
    Ok(res)
}

fn subs_key(topic: &str) -> String {
    format!("subs:{topic}")
}

/// Register a device under the topic. Knowing the topic phrase IS the subscribe
/// capability (ntfy's model). This relay serves exactly ONE topic — the fleet's
/// alert phrase — so we validate the phrase against the canonical `SUBSCRIBE_TOPIC`
/// secret and reject a wrong one outright (otherwise a mistyped phrase silently
/// subscribes the device to a topic nobody publishes to, and it never sees an alert).
async fn subscribe(req: &mut Request, env: &Env) -> Result<Response> {
    let body: SubBody = match req.json().await {
        Ok(b) => b,
        Err(_) => return Response::error("bad subscription body", 400),
    };
    let canonical = env.secret("SUBSCRIBE_TOPIC")?.to_string();
    if body.topic != canonical {
        return Response::error("incorrect phrase", 403);
    }
    let kv = env.kv("SUBS")?;
    let key = subs_key(&body.topic);
    let mut list: Vec<StoredSub> = load_subs(&kv, &key).await;
    if !list.iter().any(|s| s.endpoint == body.endpoint) {
        list.push(StoredSub {
            endpoint: body.endpoint,
            p256dh: body.p256dh,
            auth: body.auth,
        });
        save_subs(&kv, &key, &list).await?;
    }
    Response::ok("subscribed")
}

/// ntfy-style publish: Bearer publish-token, body = plain text or `{title,message}`.
/// Encrypts to every subscriber under `<topic>` and fans out; prunes 404/410.
///
/// `path_topic` is the topic from the URL path (`POST /<topic>`, the curl form).
/// Real ntfy clients (e.g. Gatus) instead POST to the base URL with the topic in
/// the JSON body, so when the path topic is empty we fall back to the body's
/// `topic` field — making this a drop-in ntfy publish endpoint either way.
async fn publish(req: &mut Request, env: &Env, path_topic: &str) -> Result<Response> {
    let token = env.secret("PUBLISH_TOKEN")?.to_string();
    if !authorized(req, &token) {
        return Response::error("unauthorized", 401);
    }

    let raw = req.text().await.unwrap_or_default();
    let parsed = serde_json::from_str::<serde_json::Value>(&raw).ok();
    let obj = parsed.as_ref().filter(|v| v.is_object());

    let topic = if !path_topic.is_empty() {
        path_topic.to_string()
    } else {
        obj.and_then(|v| v.get("topic"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string()
    };
    if topic.is_empty() {
        return Response::error("no topic (path or body)", 400);
    }

    let (title, message) = match obj {
        Some(v) => (
            v.get("title")
                .and_then(|x| x.as_str())
                .unwrap_or("infra alert")
                .to_string(),
            v.get("message")
                .or_else(|| v.get("body"))
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
        ),
        None => ("infra alert".to_string(), raw.clone()),
    };
    let sent = deliver(env, &topic, &title, &message).await?;
    Response::ok(format!("delivered to {sent}"))
}

/// Encrypt + sign `title`/`message` and fan out to every subscriber under `topic`,
/// pruning any 404/410 (gone) subscriptions. Returns how many were delivered.
/// Shared by the HTTP publish path and the dead-man's scheduled handler.
async fn deliver(env: &Env, topic: &str, title: &str, message: &str) -> Result<u32> {
    let payload = json!({ "title": title, "body": message }).to_string();

    let signing_key = vapid_signing_key(env)?;
    let vapid_public = env.var("VAPID_PUBLIC")?.to_string();
    let subject = env.var("VAPID_SUBJECT")?.to_string();

    let kv = env.kv("SUBS")?;
    let key = subs_key(topic);
    let list = load_subs(&kv, &key).await;
    if list.is_empty() {
        return Ok(0);
    }

    let mut alive: Vec<StoredSub> = Vec::with_capacity(list.len());
    let mut sent = 0u32;
    let now = (Date::now().as_millis() / 1000) as u64;
    for s in list {
        match send_one(
            &s,
            payload.as_bytes(),
            &signing_key,
            &vapid_public,
            &subject,
            now,
        )
        .await
        {
            Ok(code) if code == 404 || code == 410 => continue, // prune dead subscription
            Ok(_) => {
                sent += 1;
                alive.push(s);
            }
            Err(_) => alive.push(s), // transient — keep it
        }
    }
    save_subs(&kv, &key, &alive).await?;
    Ok(sent)
}

fn authorized(req: &Request, token: &str) -> bool {
    // Gatus's ntfy client requires its configured token to start with `tk_` (it
    // validates the format, like a real ntfy access token), so it sends
    // `Bearer tk_<token>`. curl/manual callers send the bare token. Accept either.
    req.headers()
        .get("authorization")
        .ok()
        .flatten()
        .map(|h| h == format!("Bearer {token}") || h == format!("Bearer tk_{token}"))
        .unwrap_or(false)
}

fn vapid_signing_key(env: &Env) -> Result<p256::ecdsa::SigningKey> {
    let raw = env.secret("VAPID_PRIVATE")?.to_string();
    let bytes = URL_SAFE_NO_PAD
        .decode(raw.trim())
        .map_err(|_| Error::RustError("bad VAPID_PRIVATE".into()))?;
    p256::ecdsa::SigningKey::from_slice(&bytes)
        .map_err(|_| Error::RustError("bad VAPID key".into()))
}

/// Encrypt + sign for one subscription and POST it to the push service. Returns the HTTP status.
async fn send_one(
    s: &StoredSub,
    payload: &[u8],
    signing_key: &p256::ecdsa::SigningKey,
    vapid_public_b64: &str,
    subject: &str,
    now: u64,
) -> Result<u16> {
    let p256dh = URL_SAFE_NO_PAD
        .decode(&s.p256dh)
        .map_err(|_| err("p256dh"))?;
    let auth = URL_SAFE_NO_PAD.decode(&s.auth).map_err(|_| err("auth"))?;

    // Fresh ephemeral key + salt per message (the randomness the pure core needs as input).
    let ephemeral = p256::SecretKey::random(&mut OsRng);
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);

    let sub = push_relay_core::Subscription {
        endpoint: &s.endpoint,
        p256dh: &p256dh,
        auth: &auth,
    };
    let vapid = push_relay_core::Vapid {
        signing_key,
        public_key_b64: vapid_public_b64,
        subject,
        exp_unix: now + 12 * 3600,
    };
    let eph = push_relay_core::Ephemeral {
        secret: &ephemeral,
        salt: &salt,
    };
    let pr = push_relay_core::build_push_request(&sub, payload, &vapid, &eph, TTL_SECONDS)
        .map_err(|e| err(&e.to_string()))?;

    let headers = Headers::new();
    for (k, v) in &pr.headers {
        headers.set(k, v)?;
    }
    let body = js_sys::Uint8Array::from(pr.body.as_slice());
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));
    let out = Request::new_with_init(&pr.url, &init)?;
    let resp = Fetch::Request(out).send().await?;
    Ok(resp.status_code())
}

async fn load_subs(kv: &kv::KvStore, key: &str) -> Vec<StoredSub> {
    match kv.get(key).text().await {
        Ok(Some(s)) => serde_json::from_str(&s).unwrap_or_default(),
        _ => Vec::new(),
    }
}

async fn save_subs(kv: &kv::KvStore, key: &str, list: &[StoredSub]) -> Result<()> {
    let val = serde_json::to_string(list).map_err(|_| err("serialize subs"))?;
    kv.put(key, val)?.execute().await?;
    Ok(())
}

fn err(msg: &str) -> Error {
    Error::RustError(msg.to_string())
}
