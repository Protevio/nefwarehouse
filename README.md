# nefwarehouse.com

The public front door for Namdhari's Euro Fresh, and the deployment the
warehouse system will move into.

Right now it is one page: a split wall with two doors, **Partner** and
**Warehouse**. Neither opens yet — they widen under the cursor to say that they
will.

## What is here

    site/                 the page. No build step, no dependencies.
    infra/Caddyfile       hostnames, certificates, headers
    infra/docker-compose.yml
    infra/bootstrap.sh    one-time server setup
    .github/workflows/    push to main, it goes live

Open `site/index.html` in a browser; that is the whole development setup. The
homepage is deliberately dependency-free: its job is to prove a server, a
certificate and a pipeline work, and it should not be the thing that fails.

## The server

Hetzner CX23 in Helsinki, Ubuntu. Two vCPUs, 4 GB, 40 GB. Caddy in Docker
serves `site/` and handles certificates by itself.

The address is in the `SSH_HOST` secret and deliberately not written down here.
This repository is public, and once Cloudflare's proxy is on, the whole point is
that nobody knows which machine is behind it — an origin address in a public
README hands that back and lets anyone skip Cloudflare entirely.

## Setting it up once

The short version is below. **[INSTALL.md](INSTALL.md)** is the same thing step
by step, including what to install on your own machine and what to do when a
step fails.

1. **A deploy key**, on your own machine:

       ssh-keygen -t ed25519 -C 'deploy@github' -f ~/.ssh/nefwarehouse_deploy

2. **The server**, as root:

       ssh root@<server address>
       bash bootstrap.sh "$(cat ~/.ssh/nefwarehouse_deploy.pub)"

   Installs Docker, makes a `deploy` user, adds 2 GB of swap, closes everything
   but ssh and the web.

3. **DNS in Cloudflare** — proxy OFF (grey cloud) for both:

       A   @     <server address>
       A   www   <server address>

   Leave it grey until the certificate is issued. A proxied record answers the
   ACME challenge itself, Caddy never sees it, and the failure looks like the
   server is down. Turn the proxy on afterwards with SSL mode **Full (strict)**.

4. **Three repository secrets**, under Settings → Secrets and variables →
   Actions:

       SSH_HOST          the server's address
       SSH_KEY           contents of ~/.ssh/nefwarehouse_deploy  (the private one)
       SSH_KNOWN_HOSTS   output of: ssh-keyscan -t ed25519 <server address>

5. Push to `main`.

## Deploying

`git push`. That is all. The workflow copies `site/` and `infra/`, starts or
reloads Caddy, and then asks the server for the page — so a green run means it
answered, not merely that files copied.

## Once the proxy is on

Cloudflare only protects what goes through it. With the proxy on, close 80 and
443 to everything except Cloudflare's own ranges, or the origin stays reachable
directly and the proxy is decoration:

    for ip in $(curl -s https://www.cloudflare.com/ips-v4); do ufw allow from $ip to any port 80,443 proto tcp; done
    for ip in $(curl -s https://www.cloudflare.com/ips-v6); do ufw allow from $ip to any port 80,443 proto tcp; done
    ufw delete allow 80/tcp && ufw delete allow 443/tcp && ufw delete allow 443/udp

Do this only after the certificate exists, and keep ssh open to yourself.

## When the warehouse system moves in

**Make this repository private first**, or move the warehouse system into its
own private one. The homepage is fine in the open; the warehouse system is your
stock, your suppliers and your customers, and its source would say a great deal
about all three.


The landing page owns the root and its own two images. Everything else on the
host is already routed to the warehouse system, so `/partner` and `/login` are
real paths and the two doors on the page point at them today — they answer with
a 503 until the service exists.

Connecting it is one line: in `infra/Caddyfile`, uncomment `reverse_proxy
wms:3000` and delete the `respond` beneath it. Then add the `wms` and
`postgres` services in `infra/docker-compose.yml`, where they are already
written out commented. Postgres stays on Docker's internal network with no port
of its own.

The database and the inspection photographs live on **named volumes**, not in
the deploy folder. A deploy replaces files; nothing that replaces files should
be able to reach the stock ledger or the evidence.

Certificates live in the `caddy_data` volume. Deleting it means re-issuing
everything, and Let's Encrypt has weekly limits, so leave it alone.
