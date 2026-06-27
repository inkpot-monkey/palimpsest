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
//!   POST /<topic>          → ntfy-style publish (Bearer publish-token) → web-push every subscriber
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
        (Method::Post, p) => publish(&mut req, &env, p.trim_start_matches('/')).await,
        _ => Response::error("not found", 404),
    }
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
async fn publish(req: &mut Request, env: &Env, topic: &str) -> Result<Response> {
    let token = env.secret("PUBLISH_TOKEN")?.to_string();
    if !authorized(req, &token) {
        return Response::error("unauthorized", 401);
    }

    let raw = req.text().await.unwrap_or_default();
    let (title, message) = match serde_json::from_str::<serde_json::Value>(&raw) {
        Ok(v) if v.is_object() => (
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
        _ => ("infra alert".to_string(), raw.clone()),
    };
    let payload = json!({ "title": title, "body": message }).to_string();

    let signing_key = vapid_signing_key(env)?;
    let vapid_public = env.var("VAPID_PUBLIC")?.to_string();
    let subject = env.var("VAPID_SUBJECT")?.to_string();

    let kv = env.kv("SUBS")?;
    let key = subs_key(topic);
    let list = load_subs(&kv, &key).await;
    if list.is_empty() {
        return Response::error("no subscribers for topic", 404);
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
    Response::ok(format!("delivered to {sent}"))
}

fn authorized(req: &Request, token: &str) -> bool {
    req.headers()
        .get("authorization")
        .ok()
        .flatten()
        .map(|h| h == format!("Bearer {token}"))
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
