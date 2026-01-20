# Stalwart Mail Post-Installation Guide

Follow these steps to complete the setup of your Stalwart Mail server on 'kelpy'.

## Prerequisites: Secrets

Before deploying, ensure your `secrets.yaml` (usually in `~/code/nixos/secrets/secrets.yaml`) contains the following key:

```yaml
cloudflare_dns_token: "YOUR_CLOUDFLARE_API_TOKEN"
stalwart_admin_password: "YOUR_SECURE_PASSWORD"
```

This token must have permissions to:
1.  **Edit DNS** for your domain (for the setup script and ACME challenges).
2.  (Optional) **Read/Edit Email Routing** if you want to automate cleanups (script currently only adds records).

The configuration automatically maps this single key to both Caddy and Stalwart services with appropriate permissions.

## 1. Deploy Configuration

Apply the new NixOS configuration:

```bash
nixos-rebuild switch --flake ~/code/nixos#kelpy
```

Verify the service is running:

```bash
systemctl status stalwart-mail
```

## 2. Initial DNS Setup
 
 Since we are managing DNS manually via Cloudflare:
 
 1.  **Get Zone File**: Copy the zone definitions from your Stalwart Web Admin (or the text provided during setup).
 2.  **Import to Cloudflare**:
     - Go to **Cloudflare Dashboard > DNS > Records**.
     - Click **Import and Export** -> **Import**.
     - Upload your zone file (e.g. `stalwart.txt`).
 3.  This configures A, MX, SPF, DKIM, and SRV records automatically.

## 3. Configure Domain & DKIM

Stalwart does not create the domain automatically. You must do this to generate keys.

1.  **Create Domain:**
    - Go to `https://mail.yourdomain.com` (e.g., `https://mail.palebluebytes.xyz`).
    - Login with admin credentials (see step 5).
    - Navigate to **Management > Directory > Domains**.
    - Click **Create Domain**.
    - Enter your domain name (e.g., `palebluebytes.xyz`) and Save.

2.  **Retrieve DKIM Keys:**
    - Click on the domain you just created.
    - Click the **DNS** tab (or "DNS Records").
    - You will see generated records (MX, SPF, DKIM).
    - **Crucial:** Copy the **DKIM TXT records** (usually one or two, e.g., `202401r._domainkey`).

3.  **Update Cloudflare:**
    - The `setup-mail-dns` script handles A/MX/SPF.
    - You must **manually add** the DKIM TXT records you just copied to Cloudflare.

2.  **Update DNS:**
    Add a TXT record to Cloudflare:
    - **Name:** `<selector>._domainkey` (e.g., `default._domainkey`)
    - **Content:** `v=DKIM1; k=rsa; p=YOUR_PUBLIC_KEY_HERE`

6.  **Reverse DNS (PTR) - CRITICAL**
    This cannot be configured in NixOS or Cloudflare.
    - Log in to your **VPS Provider Dashboard** (e.g. vpsFree).
    - Find the "Networking" or "IP" settings for this server (`37.205.14.206`).
    - Set the **Reverse DNS / PTR Record** to `mail.palebluebytes.xyz`.
    - *Without this, mostly emails will go to Spam.*

7.  **MTA-STS Security (Manual DNS)**
    These records enforce TLS encryption for incoming mail.
    - **CNAME Record**:
        - Name: `mta-sts`
        - Target: `mail.palebluebytes.xyz` (or `kelpy`)
        - Proxy Status: **DNS Only** (Grey Cloud)
    - **TXT Record**:
        - Name: `_mta-sts`
        - Content: `v=STSv1; id=2026012001;` (Update ID if you change policy)

> [!NOTE]
> **TLSA (DANE) Records**: We explicitly **SKIP** these. Since we use Let's Encrypt (which rotates certs every 60 days), hardcoding a TLSA record in manual DNS would break email regularily. MTA-STS provides similar security without this risk.

## 4. Create Admin User & Mailboxes

1.  **Get Initial Admin Password:**
    You have configured this declaratively via Sops!
    Use the password you set in `secrets.yaml` as `stalwart_admin_password`.

2.  **Login:**
    Access `https://mail.yourdomain.com`.

3.  **Create Users:**
    - Go to **Directory > Accounts**.
    - Create a new account (e.g., `me@yourdomain.com`).

## 5. Verify Email

1.  **Send a Test Email:**
    Send an email from your new account to [check-auth@verifier.port25.com](mailto:check-auth@verifier.port25.com) or use [mail-tester.com](https://www.mail-tester.com).
    
2.  **Check Score:**
    Ensure you get a 10/10 score. If SPF or DKIM fails, check your DNS records.

3.  **Receive Email:**
    Reply to the test email and verify you receive it in Stalwart.
