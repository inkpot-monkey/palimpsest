# Stalwart Mail Post-Installation Guide

Follow these steps to complete the setup of your Stalwart Mail server on 'kelpy'.

## Prerequisites: Secrets

Before deploying, ensure your `secrets.yaml` (usually in `~/code/nixos/secrets/secrets.yaml`) contains the following key:

```yaml
cloudflare_dns_token: "YOUR_CLOUDFLARE_API_TOKEN"
stalwart_admin_password: "YOUR_SECURE_PASSWORD"
```

This token must have permissions to:

1. **Edit DNS** for your domain (for the setup script and ACME challenges).
1. (Optional) **Read/Edit Email Routing** if you want to automate cleanups (script currently only adds records).

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

This will automatically create or update your MX, SPF, DMARC, and MTA-STS records for `palebluebytes.space`.

### Step 2: DKIM Records

Stalwart generates DKIM keys internally.

1. Check your Stalwart Web Admin (**Management > Directory > Domains > DNS**) for the DKIM `stalwart._domainkey` record.
1. If it differs from what is in your DNS, you can either update it manually in Cloudflare or add it to `parts/apps/dns/dnsconfig.js`.

### Step 3: Reverse DNS (PTR) - Exterior

This cannot be configured in Cloudflare or DnsControl.

- Log in to your **VPS Provider Dashboard** (e.g. vpsFree).
- Find the "Networking" or "IP" settings for this server (`37.205.14.206`).
- Set the **Reverse DNS / PTR Record** to `mail.palebluebytes.xyz`.
- *Without this, most emails will go to Spam.*

## 4. Create Admin User & Mailboxes

1. **Get Initial Admin Password:**
   You have configured this declaratively via Sops!
   Use the password you set in `secrets.yaml` as `stalwart_admin_password`.

1. **Login:**
   Access `https://mail.yourdomain.com`.

1. **Create Users:**

   - Go to **Directory > Accounts**.
   - Create a new account (e.g., `me@yourdomain.com`).
   - **Catch-all Address**: To create a catch-all address, edit the account and add `@yourdomain.com` (without a username part) as an alias. This catches all unmatched emails for that domain.

## 4b. Adding New Domains

To add a new domain (e.g., `palebluebytes.xyz`) to your mail server:

1. **Update NixOS Configuration**:

   - Add the new domain to `custom.profiles.mail.extraDomains` in your host configuration (e.g., in `hosts/kelpy/default.nix`).
   - Rebuild the system: `nixos-rebuild switch --flake ~/code/nixos#kelpy`.
   - This will set up Caddy to serve `autoconfig`, `autodiscover`, and `mta-sts` for the new domain.

1. **Add Domain in Stalwart Web Admin**:

   - Log in to the Web Admin (`https://mail.palebluebytes.space`).
   - Go to **Directory > Domains**.
   - Click **Create Domain** and enter your new domain.

1. **Configure DNS**:

   - Add MX records pointing to `mail.palebluebytes.space`.
   - Add SPF, DMARC, and DKIM records as provided by the Stalwart Web Admin for the new domain.

## 5. Verify Email & Features

1. **Check Autodiscovery:**
   Add your account to Thunderbird or Outlook using only your email address. It should automatically find the correct IMAP and SMTP settings.

1. **JMAP Access:**
   You can now use JMAP clients at `https://mail.palebluebytes.space/jmap`.

1. **Send a Test Email:**
   Send an email from your new account to [check-auth@verifier.port25.com](mailto:check-auth@verifier.port25.com) or use [mail-tester.com](https://www.mail-tester.com).

   - **Troubleshooting DKIM**: If mail-tester says your message is not signed with DKIM (even though DNS records are correct), ensure that the signing policy is active. Go to **Settings > MTA > Inbound > Sender Authentication** and set **DKIM Sign Domain** to return `sender_domain` for local authenticated users (e.g., condition: `is_local_domain(sender_domain) && !is_empty(authenticated_as)`).

1. **Check Score:**
   Ensure you get a 10/10 score. If SPF or DKIM fails, verify your DNS records via `dnscontrol`.
