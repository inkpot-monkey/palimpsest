//! Portable Web Push request builder — the host-agnostic core of the out-of-band
//! alert relay (ADR-0027).
//!
//! Given a browser `PushSubscription`, a plaintext payload, and VAPID credentials,
//! it produces the `(url, headers, body)` of the HTTPS POST a server sends to the
//! push service. It implements:
//!   - RFC 8291 message encryption (`aes128gcm` content-encoding, RFC 8188),
//!   - RFC 8292 VAPID authentication (ES256 JWT, single `Authorization: vapid` header).
//!
//! It is deliberately **I/O-free**: the ephemeral ECDH key, the salt, and the JWT
//! expiry are *inputs*, not things this crate fetches. The host shell supplies
//! randomness and the clock. That keeps the crate pure (so it unit-tests against
//! the RFC 8291 Appendix A vector) and portable (the same crate compiles into a
//! Cloudflare Worker or a Spin/WASI component unchanged).

use aes_gcm::aead::Aead;
use aes_gcm::{Aes128Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use hkdf::Hkdf;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use sha2::Sha256;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// A subscription key (p256dh / auth) or the ephemeral key was malformed.
    InvalidKey,
    /// AEAD encryption failed (effectively unreachable for valid keys).
    Encrypt,
    /// The endpoint URL had no parseable `scheme://host` origin (needed for the VAPID `aud`).
    Endpoint,
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let s = match self {
            Error::InvalidKey => "invalid key material",
            Error::Encrypt => "payload encryption failed",
            Error::Endpoint => "endpoint has no scheme://host origin",
        };
        f.write_str(s)
    }
}

impl std::error::Error for Error {}

/// A browser push subscription (the fields a PushSubscription serialises to).
pub struct Subscription<'a> {
    pub endpoint: &'a str,
    /// UA public key, 65-byte SEC1 uncompressed point (the `keys.p256dh`).
    pub p256dh: &'a [u8],
    /// Shared auth secret, 16 bytes (the `keys.auth`).
    pub auth: &'a [u8],
}

/// VAPID credentials + the per-request claims the host fills in.
pub struct Vapid<'a> {
    pub signing_key: &'a p256::ecdsa::SigningKey,
    /// base64url of the 65-byte uncompressed VAPID public key (the `k=` parameter).
    pub public_key_b64: &'a str,
    /// `sub` claim, e.g. `mailto:admin@example.com`.
    pub subject: &'a str,
    /// `exp` claim — unix seconds, must be in the future and <= now+24h (host supplies the clock).
    pub exp_unix: u64,
}

/// The randomness the host injects per message (kept out of this crate so it stays pure).
pub struct Ephemeral<'a> {
    /// Application-server ephemeral ECDH private key (fresh per message in production).
    pub secret: &'a p256::SecretKey,
    /// 16-byte content-encoding salt (fresh per message in production).
    pub salt: &'a [u8; 16],
}

/// The HTTPS request to send to the push service.
pub struct PushRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

const RECORD_SIZE: u32 = 4096;

/// Encrypt `payload` for `sub` using RFC 8291 (`aes128gcm`). Returns the full body
/// (the RFC 8188 content-encoding header followed by the single ciphertext record).
pub fn encrypt(sub: &Subscription, payload: &[u8], eph: &Ephemeral) -> Result<Vec<u8>, Error> {
    if sub.auth.len() != 16 {
        return Err(Error::InvalidKey);
    }
    let ua_public = p256::PublicKey::from_sec1_bytes(sub.p256dh).map_err(|_| Error::InvalidKey)?;
    let as_point = eph.secret.public_key().to_encoded_point(false); // 65-byte uncompressed
    let as_public: &[u8] = as_point.as_bytes();

    // ECDH shared secret (x-coordinate, 32 bytes).
    let shared = p256::ecdh::diffie_hellman(eph.secret.to_nonzero_scalar(), ua_public.as_affine());
    let ecdh_secret = shared.raw_secret_bytes();

    // RFC 8291 §3.4: derive the input keying material from the auth secret.
    //   key_info = "WebPush: info" || 0x00 || ua_public || as_public
    //   IKM      = HKDF(salt = auth_secret, ikm = ecdh_secret, info = key_info, L = 32)
    let mut key_info = Vec::with_capacity(14 + 65 + 65);
    key_info.extend_from_slice(b"WebPush: info\x00");
    key_info.extend_from_slice(ua_public.to_encoded_point(false).as_bytes());
    key_info.extend_from_slice(as_public);
    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(sub.auth), ecdh_secret.as_ref())
        .expand(&key_info, &mut ikm)
        .map_err(|_| Error::Encrypt)?;

    // RFC 8188: content-encryption key + nonce from the salt.
    let prk = Hkdf::<Sha256>::new(Some(eph.salt.as_slice()), &ikm);
    let mut cek = [0u8; 16];
    prk.expand(b"Content-Encoding: aes128gcm\x00", &mut cek)
        .map_err(|_| Error::Encrypt)?;
    let mut nonce = [0u8; 12];
    prk.expand(b"Content-Encoding: nonce\x00", &mut nonce)
        .map_err(|_| Error::Encrypt)?;

    // Single record: plaintext followed by the 0x02 last-record padding delimiter.
    let mut plain = Vec::with_capacity(payload.len() + 1);
    plain.extend_from_slice(payload);
    plain.push(0x02);
    // aes-gcm 0.10 uses generic-array 0.14 in its public API; Nonce::from_slice is
    // the only way to get &Nonce<Aes128Gcm> from &[u8] until aes-gcm moves to ≥0.11.
    // KeyInit::new_from_slice avoids the deprecated Key::from_slice path.
    #[allow(deprecated)]
    let nonce_ref = Nonce::from_slice(&nonce);
    let ciphertext = Aes128Gcm::new_from_slice(&cek)
        .expect("cek is always 16 bytes")
        .encrypt(nonce_ref, plain.as_slice())
        .map_err(|_| Error::Encrypt)?;

    // RFC 8188 §2.1 content-coding header: salt(16) || rs(4 BE) || idlen(1) || keyid(as_public).
    let mut body = Vec::with_capacity(16 + 4 + 1 + 65 + ciphertext.len());
    body.extend_from_slice(eph.salt);
    body.extend_from_slice(&RECORD_SIZE.to_be_bytes());
    body.push(as_public.len() as u8);
    body.extend_from_slice(as_public);
    body.extend_from_slice(&ciphertext);
    Ok(body)
}

/// Build the single `Authorization: vapid t=<jwt>, k=<pub>` header value (RFC 8292).
/// `audience` is the `scheme://host` origin of the push endpoint.
pub fn vapid_authorization(audience: &str, v: &Vapid) -> String {
    use p256::ecdsa::{signature::Signer, Signature};

    let header = URL_SAFE_NO_PAD.encode(br#"{"typ":"JWT","alg":"ES256"}"#);
    let claims = format!(
        r#"{{"aud":"{}","exp":{},"sub":"{}"}}"#,
        audience, v.exp_unix, v.subject
    );
    let claims = URL_SAFE_NO_PAD.encode(claims.as_bytes());
    let signing_input = format!("{header}.{claims}");
    // ES256: SHA-256 + deterministic (RFC 6979) ECDSA — no RNG needed, output is fixed-size r||s.
    let sig: Signature = v.signing_key.sign(signing_input.as_bytes());
    let sig = URL_SAFE_NO_PAD.encode(sig.to_bytes());
    format!("vapid t={signing_input}.{sig}, k={}", v.public_key_b64)
}

/// Origin (`scheme://host[:port]`) of a URL — the VAPID `aud`.
fn origin_of(url: &str) -> Result<String, Error> {
    let scheme_end = url.find("://").ok_or(Error::Endpoint)?;
    let after = &url[scheme_end + 3..];
    let host_len = after.find('/').unwrap_or(after.len());
    if host_len == 0 {
        return Err(Error::Endpoint);
    }
    Ok(url[..scheme_end + 3 + host_len].to_string())
}

/// Build the full push request: encrypt the payload and attach VAPID + content headers.
/// `ttl_seconds` is the push service's store-and-forward lifetime.
pub fn build_push_request(
    sub: &Subscription,
    payload: &[u8],
    vapid: &Vapid,
    eph: &Ephemeral,
    ttl_seconds: u32,
) -> Result<PushRequest, Error> {
    let body = encrypt(sub, payload, eph)?;
    let audience = origin_of(sub.endpoint)?;
    let authorization = vapid_authorization(&audience, vapid);
    Ok(PushRequest {
        url: sub.endpoint.to_string(),
        headers: vec![
            ("Authorization".into(), authorization),
            ("Content-Encoding".into(), "aes128gcm".into()),
            ("Content-Type".into(), "application/octet-stream".into()),
            ("TTL".into(), ttl_seconds.to_string()),
        ],
        body,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b64(s: &str) -> Vec<u8> {
        URL_SAFE_NO_PAD.decode(s).unwrap()
    }

    // RFC 8291 Appendix A — the canonical worked example. Encrypting the example
    // plaintext with the example UA key, auth secret, ephemeral key, and salt MUST
    // reproduce the example body exactly. This proves interop correctness, not just
    // self-consistency.
    #[test]
    fn rfc8291_appendix_a_vector() {
        let plaintext = "When I grow up, I want to be a watermelon";
        let auth = b64("BTBZMqHH6r4Tts7J_aSIgg");
        let p256dh = b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
        let as_private = b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
        let salt: [u8; 16] = b64("DGv6ra1nlYgDCS1FRnbzlw").try_into().unwrap();
        let expected = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";

        let secret = p256::SecretKey::from_slice(&as_private).unwrap();

        // Sanity: the derived ephemeral public key matches the example's as_public.
        let as_public = b64("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8");
        assert_eq!(
            secret.public_key().to_encoded_point(false).as_bytes(),
            as_public.as_slice()
        );

        let sub = Subscription {
            endpoint: "https://push.example.net/x",
            p256dh: &p256dh,
            auth: &auth,
        };
        let body = encrypt(
            &sub,
            plaintext.as_bytes(),
            &Ephemeral {
                secret: &secret,
                salt: &salt,
            },
        )
        .unwrap();
        assert_eq!(URL_SAFE_NO_PAD.encode(&body), expected);
    }

    // The VAPID JWT (ES256) is non-deterministic to compare byte-for-byte across
    // libraries, so verify it round-trips: the signature validates against the key,
    // and the header/claims decode to the expected shape.
    #[test]
    fn vapid_jwt_roundtrips() {
        use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};

        let signing_key = p256::ecdsa::SigningKey::from_slice(&b64(
            "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
        ))
        .unwrap();
        let verifying = VerifyingKey::from(&signing_key);
        let pub_b64 = URL_SAFE_NO_PAD.encode(verifying.to_encoded_point(false).as_bytes());

        let v = Vapid {
            signing_key: &signing_key,
            public_key_b64: &pub_b64,
            subject: "mailto:admin@example.com",
            exp_unix: 1_700_000_000,
        };
        let auth = vapid_authorization("https://push.example.net", &v);

        // "vapid t=<h>.<c>.<s>, k=<pub>"
        let t = auth.strip_prefix("vapid t=").unwrap();
        let (jwt, k) = t.split_once(", k=").unwrap();
        assert_eq!(k, pub_b64);
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let sig = Signature::from_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
        verifying.verify(signing_input.as_bytes(), &sig).unwrap();

        let claims = String::from_utf8(URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert!(claims.contains(r#""aud":"https://push.example.net""#));
        assert!(claims.contains(r#""sub":"mailto:admin@example.com""#));
        assert!(claims.contains(r#""exp":1700000000"#));
    }

    #[test]
    fn origin_parsing() {
        assert_eq!(origin_of("https://a.b.c/d/e?f=g").unwrap(), "https://a.b.c");
        assert_eq!(
            origin_of("https://host:8443/p").unwrap(),
            "https://host:8443"
        );
        assert!(origin_of("notaurl").is_err());
    }
}
