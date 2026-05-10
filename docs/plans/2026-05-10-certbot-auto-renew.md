# Certbot Auto-Renewal Docker Service Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a certbot service to docker-compose.yml that automatically renews Let's Encrypt certificates every 12 hours, eliminating the need for manual renewal.

**Architecture:** Add a `certbot` service using the official `certbot/certbot` image with an entrypoint that loops `certbot renew` every 12 hours. Nginx reloads via a post-renewal deploy hook script that runs `docker compose exec nginx nginx -s reload`. The hook is mounted into the certbot container from the host.

**Tech Stack:** Docker Compose, certbot/certbot image, nginx:alpine, shell scripts.

---

## Background

Current renewal config (`nginx/certs/renewal/wiki.astroicers.link.conf`) uses:
- **authenticator:** `webroot`
- **webroot_path:** `/var/www/certbot`
- **domains:** `wiki.astroicers.link`, `auth.astroicers.link`

Nginx already mounts:
- `./nginx/certs:/etc/letsencrypt:ro` — certs (read-only)
- `./nginx/www:/var/www/certbot:ro` — ACME challenge dir (read-only)

The certbot container needs **write** access to both. We will change nginx's cert volume to read-only (it already is), and give certbot read-write access.

---

## Task 1: Create the post-renewal deploy hook

**Files:**
- Create: `scripts/deploy-hook.sh`

**Step 1: Create the hook script**

```bash
#!/bin/sh
# Reload nginx after cert renewal so new certs are picked up
docker compose -f /outline-docker/docker-compose.yml exec -T nginx nginx -s reload
```

> **Note:** The `-T` flag disables pseudo-TTY allocation (required in non-interactive contexts). The path `/outline-docker/docker-compose.yml` is the host path mounted into the certbot container — see Task 2.

**Step 2: Make it executable**

```bash
chmod +x /home/ubuntu/outline-docker/scripts/deploy-hook.sh
```

**Step 3: Verify**

```bash
ls -la /home/ubuntu/outline-docker/scripts/deploy-hook.sh
```
Expected: `-rwxr-xr-x` permissions.

---

## Task 2: Add certbot service to docker-compose.yml

**Files:**
- Modify: `docker-compose.yml`

**Step 1: Add the certbot service block**

Add after the `nginx` service, before `volumes:`:

```yaml
  certbot:
    image: certbot/certbot
    entrypoint: /bin/sh -c "trap exit TERM; while :; do certbot renew --deploy-hook /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh; sleep 12h & wait $${!}; done"
    volumes:
      - ./nginx/certs:/etc/letsencrypt
      - ./nginx/www:/var/www/certbot
      - ./scripts/deploy-hook.sh:/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /home/ubuntu/outline-docker/docker-compose.yml:/outline-docker/docker-compose.yml:ro
    depends_on:
      - nginx
    restart: unless-stopped
```

**Why each volume:**
- `./nginx/certs` — read/write so certbot can write renewed certs (note: **remove** `:ro` from nginx's cert volume too — see Step 2)
- `./nginx/www` — read/write so certbot can write ACME challenge files
- `deploy-hook.sh` — the reload script, mounted read-only
- `/var/run/docker.sock` — so deploy hook can run `docker compose exec nginx`
- `docker-compose.yml` — so `docker compose` inside certbot knows the project

**Step 2: Change nginx cert volume from read-only to read-write**

In the `nginx` service, change:
```yaml
      - ./nginx/certs:/etc/letsencrypt:ro
```
to:
```yaml
      - ./nginx/certs:/etc/letsencrypt:ro
```
(No change needed — nginx keeps `:ro`. Only certbot gets read-write access.)

**Step 3: Verify docker-compose.yml is valid**

```bash
cd /home/ubuntu/outline-docker && docker compose config --quiet && echo "OK"
```
Expected: `OK` with no errors.

---

## Task 3: Update deploy hook to use correct docker socket path

**Files:**
- Modify: `scripts/deploy-hook.sh`

The hook runs **inside** the certbot container. It needs `docker` CLI available. The official `certbot/certbot` image does **not** include docker CLI — we need a different approach.

**Revised approach:** Use a `curl` call to the Docker socket directly to send a SIGHUP to the nginx container (which triggers reload), OR switch to a simpler method: write a sentinel file that nginx's entrypoint watches.

**Simplest reliable approach:** Mount the Docker socket and install docker CLI inside certbot via a custom entrypoint, OR use `docker` exec from the host via a host-path script.

**Best practice for this setup:** Replace the deploy hook with a **shared volume sentinel file**. After renewal, certbot touches `/var/run/certbot-renewed`. A lightweight nginx reload sidecar watches for this file and runs `nginx -s reload`.

**Even simpler:** Use `post_hook` in the certbot renewal config to call `nginx -s reload` directly via the shared Docker socket using `curl`:

```sh
#!/bin/sh
curl --unix-socket /var/run/docker.sock \
  -X POST "http://localhost/containers/outline-docker-nginx-1/kill?signal=HUP"
```

This sends SIGHUP to nginx, which triggers a graceful reload without restarting the container.

**Step 1: Rewrite deploy-hook.sh**

```bash
#!/bin/sh
# Send SIGHUP to nginx container via Docker socket to trigger cert reload
curl -s --unix-socket /var/run/docker.sock \
  -X POST "http://localhost/containers/outline-docker-nginx-1/kill?signal=HUP"
echo "Sent HUP to nginx"
```

**Step 2: Verify curl is available in certbot image**

```bash
docker run --rm certbot/certbot sh -c "which curl || echo 'no curl'"
```

If no curl: use `wget` equivalent or switch to the `docker` CLI approach below.

**Alternative if no curl:** Add `curl` via the entrypoint:

```yaml
entrypoint: /bin/sh -c "apk add --no-cache curl docker-cli && trap exit TERM; while :; do certbot renew --deploy-hook /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh; sleep 12h & wait $${!}; done"
```

---

## Task 4: Start the certbot service and verify

**Step 1: Start only the certbot service**

```bash
cd /home/ubuntu/outline-docker && docker compose up -d certbot
```

**Step 2: Verify it's running**

```bash
docker compose ps certbot
```
Expected: `running`

**Step 3: Check certbot logs**

```bash
docker compose logs certbot
```
Expected: Certbot runs, prints renewal status (likely "not yet due" since we just renewed), then sleeps 12h.

**Step 4: Verify nginx reload works by simulating the hook**

```bash
docker compose exec certbot sh /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```
Expected: nginx reloads (check `docker compose logs nginx` for reload message).

---

## Task 5: Update Makefile with cert-related targets

**Files:**
- Modify: `Makefile`

**Step 1: Add targets**

Add to the "服務管理" section:

```makefile
cert-renew:
	docker compose exec certbot certbot renew --force-renewal

cert-status:
	docker compose exec certbot certbot certificates
```

**Step 2: Add to help text**

```makefile
	@echo "  make cert-renew     強制更新 SSL 憑證"
	@echo "  make cert-status    查看憑證狀態"
```

**Step 3: Verify**

```bash
cd /home/ubuntu/outline-docker && make help | grep cert
```
Expected: shows `cert-renew` and `cert-status`.

---

## Verification (End-to-End)

1. **Check certbot service is running:**
   ```bash
   docker compose ps certbot
   ```

2. **Check cert expiry (should be ~90 days from renewal):**
   ```bash
   docker compose exec certbot certbot certificates
   ```

3. **Force test renewal + hook:**
   ```bash
   make cert-renew
   docker compose logs --tail=20 certbot
   docker compose logs --tail=10 nginx
   ```
   Expected: certbot renews, hook fires, nginx logs show reload.

4. **Confirm HTTPS still works:**
   ```bash
   curl -I https://wiki.astroicers.link
   ```
   Expected: `HTTP/2 200` or redirect.

---

## Notes

- The `nginx/www` volume in nginx service is currently `:ro` — change to writable so certbot can write challenge files: `./nginx/www:/var/www/certbot` (no `:ro`).
- Container name `outline-docker-nginx-1` is the default compose naming. Verify with `docker compose ps` if it differs.
- The 12h sleep loop means renewal is checked twice daily; Let's Encrypt only actually renews when < 30 days remain.
