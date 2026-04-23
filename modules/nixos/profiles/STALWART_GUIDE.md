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
 
 Since we are managing DNS programmatically via `dnscontrol`, the manual import is no longer necessary.
 
 ### Step 1: Push DNS configuration
 Run the following command from your nix directory:
 ```bash
 nix run .#dns -- push
 ```
 This will automatically create or update your MX, SPF, DMARC, and MTA-STS records for `palebluebytes.xyz`.
 
 ### Step 2: DKIM Records
 Stalwart generates DKIM keys internally. 
 1. Check your Stalwart Web Admin (**Management > Directory > Domains > DNS**) for the DKIM `stalwart._domainkey` record.
 2. If it differs from what is in your DNS, you can either update it manually in Cloudflare or add it to `parts/apps/dns/dnsconfig.js`.
 
 ### Step 3: Reverse DNS (PTR) - Exterior
 This cannot be configured in Cloudflare or DnsControl.
 - Log in to your **VPS Provider Dashboard** (e.g. vpsFree).
 - Find the "Networking" or "IP" settings for this server (`37.205.14.206`).
 - Set the **Reverse DNS / PTR Record** to `mail.palebluebytes.xyz`.
 - *Without this, most emails will go to Spam.*

## 4. Create Admin User & Mailboxes

1.  **Get Initial Admin Password:**
    You have configured this declaratively via Sops!
    Use the password you set in `secrets.yaml` as `stalwart_admin_password`.

2.  **Login:**
    Access `https://mail.yourdomain.com`.

3.  **Create Users:**
    - Go to **Directory > Accounts**.
    - Create a new account (e.g., `me@yourdomain.com`).

## 5. Verify Email & Features

1.  **Check Autodiscovery:**
    Add your account to Thunderbird or Outlook using only your email address. It should automatically find the correct IMAP and SMTP settings.

2.  **JMAP Access:**
    You can now use JMAP clients at `https://mail.palebluebytes.xyz/alt/jmap`.

3.  **Send a Test Email:**
    Send an email from your new account to [check-auth@verifier.port25.com](mailto:check-auth@verifier.port25.com) or use [mail-tester.com](https://www.mail-tester.com).
    
4.  **Check Score:**
    Ensure you get a 10/10 score. If SPF or DKIM fails, verify your DNS records via `dnscontrol`.
