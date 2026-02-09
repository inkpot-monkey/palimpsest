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

## 2. DNS Setup
 
 Since we are managing DNS manually via Cloudflare, we will import the Stalwart zone file and then apply critical fixes.
 
 ### Step 1: Import Zone File
 1.  **Get Zone File**: Copy the zone definitions from your Stalwart Web Admin (Management > Directory > Domains > DNS).
 2.  **Import to Cloudflare**:
     - Go to **Cloudflare Dashboard > DNS > Records**.
     - Click **Import and Export** -> **Import**.
     - Upload or paste your zone file.
     - This creates your MX, DKIM, DMARC, and SRV records.
 
 ### Step 2: Critical Adjustments (Do this immediately)
 1.  **DELETE TLSA Records**:
     - **Action:** Delete all records starting with `_25._tcp.mail`.
     - **Reason:** These bind email security to your *current* certificate. Since Let's Encrypt rotates certs every 60 days, these records will expire and **break your email**. We use MTA-STS (Step 3) instead.
 
 2.  **FIX SPF Records**:
     - Stalwart often generates invalid syntax (`ra=postmaster`).
     - **Action**: Edit the **TXT** record for `@` (and `mail` if present).
     - **Change**: `v=spf1 mx ra=postmaster -all`
     - **To**: `v=spf1 mx ip4:37.205.14.206 -all`
     - (Replace with your actual server IP).
 
 ### Step 3: Add Advanced Security (MTA-STS)
 Add these records manually to enforce TLS encryption safely:
 - **CNAME Record**:
     - Name: `mta-sts`
     - Target: `mail.palebluebytes.xyz`
     - Proxy Status: **DNS Only** (Grey Cloud)
 - **TXT Record**:
     - Name: `_mta-sts`
     - Content: `v=STSv1; id=2026012001;`
 
 ### Step 4: Reverse DNS (PTR) - Exterior
 This cannot be configured in Cloudflare.
 - Log in to your **VPS Provider Dashboard** (e.g. vpsFree).
 - Find the "Networking" or "IP" settings for this server (`37.205.14.206`).
 - Set the **Reverse DNS / PTR Record** to `mail.palebluebytes.xyz`.
 - *Without this, mostly emails will go to Spam.*

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
