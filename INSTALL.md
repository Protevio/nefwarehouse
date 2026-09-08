# Installing everything on the server

From a blank Hetzner box to the landing page and the warehouse system both
live on `nefwarehouse.com`.

There are **two repositories**. This one is public and holds the landing page
and the whole server configuration. The warehouse system lives in its own
**private** repository — its source says a great deal about your stock, your
suppliers and your customers, and none of that belongs in the open.

Everything runs in PowerShell on your own machine except step 4, which runs on
the server.

---

## What ends up running

```
                    the internet
                         │
                    Caddy  :443           certificates, one hostname
                     ├── /                the landing page, from disk
                     └── everything else  → wms :3000
                                              │
                                          postgres    no port to the outside
```

Three containers on one private network. Only Caddy is reachable from outside.
The database has no published port at all, because it does not need one and a
database with a port open to the internet is a database that gets found.

---

## 1. On your own machine

**Git**:

```powershell
git --version
winget install --id Git.Git -e     # only if that failed
```

**OpenSSH client** — built into Windows 10 and 11:

```powershell
ssh -V
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0   # only if that failed
```

Nothing else. No Node, no Docker locally — the server builds everything.

---

## 2. A deploy key

One key, used by both repositories. No passphrase; nothing can type one during
a deploy.

```powershell
ssh-keygen -t ed25519 -C "deploy@github" -f $env:USERPROFILE\.ssh\nefwarehouse_deploy -N '""'
```

---

## 3. Two repositories

**This one** (`Protevio/nefwarehouse`, public) — unzip the contents in, then:

```powershell
cd C:\dev\nefwarehouse
git add -A
git commit -m "Landing page, Caddy, compose"
git push
```

**The warehouse system** — `Protevio/nefwams`. Check it is set to **private**
before the first push: Settings → General → Danger Zone → Change visibility.
Then:

```powershell
cd C:\dev\namdhari-wms
git init
git add -A
git commit -m "Warehouse system"
git branch -M main
git remote add origin https://github.com/Protevio/nefwams.git
git push -u origin main
```

Before that first commit, check `.gitignore` covers `node_modules`, `.next`,
`.env` and `uploads`. The `.env` especially must never be pushed.

Both pushes will fail at the copy step until the server exists. Expected.

---

## 4. The server

```powershell
scp .\infra\bootstrap.sh root@SERVER:/root/
ssh root@SERVER "bash /root/bootstrap.sh '$(Get-Content $env:USERPROFILE\.ssh\nefwarehouse_deploy.pub)'"
```

Two or three minutes. It installs Docker, rsync, ufw and unattended security
updates, makes a `deploy` user, adds 2 GB of swap, and **generates a database
password** into `/srv/nefwarehouse/infra/env/`. You never see or type that
password; nothing outside those two files needs it.

Keep the last lines it prints — that is the server's fingerprint, for step 6.

---

## 5. DNS

Cloudflare, DNS → Records. Both with the proxy **OFF** (grey cloud):

```
A   @      your server's address
A   www    your server's address
```

Grey matters. A proxied record answers the certificate challenge itself, Caddy
never sees it, and the failure looks exactly like the server being down. Turn
the proxy on afterwards, with SSL/TLS → Overview set to **Full (strict)**.

```powershell
nslookup nefwarehouse.com
```

---

## 6. Secrets, in both repositories

Settings → Secrets and variables → Actions. The same three values in each:

```
SSH_HOST          the server's address
SSH_KEY           Get-Content $env:USERPROFILE\.ssh\nefwarehouse_deploy | Set-Clipboard
SSH_KNOWN_HOSTS   ssh-keyscan -t ed25519 SERVER | Set-Clipboard
```

Paste straight from the clipboard. Do not route them through an editor that
might trim a line.

---

## 7. Deploy, in this order

**Landing page first.** In `nefwarehouse`: Actions → Deploy → Run workflow.
This starts Caddy and Postgres and gets the certificate.

```powershell
curl.exe -I https://nefwarehouse.com
```

`HTTP/2 200`. Until the warehouse system is up, `/login` answers 502 — correct,
nothing is behind it yet.

**Then the warehouse system.** In `Protevio/nefwams`: Actions → Deploy →
Run workflow. It typechecks, tests and builds on GitHub first, so a broken build
never reaches the server. Then it copies the source up, builds the image there,
and waits for the app to answer its own health check before calling it done.

The first build takes five to eight minutes on two shared cores. Later ones are
faster.

The container brings the database schema up to date every time it starts, with
a command that refuses to do anything destructive. There is no `db push` to run
by hand and nothing to seed.

---

## 8. The first sign-in

A fresh database has no accounts. Open a shell in the container and use
whichever `prisma/` script creates your first manager:

```powershell
ssh deploy@SERVER "cd /srv/nefwarehouse/infra && docker compose exec -it wms sh"
```

Then open <https://nefwarehouse.com>, click **Warehouse**, and sign in. Leave
"Remember this device" ticked on your own machines; untick it on the shared
tablet, so its session ends when the browser closes instead of leaving the next
person signed in as the last one.

---

## 9. Backups, before you rely on any of it

```powershell
ssh root@SERVER "(crontab -l 2>/dev/null; echo '0 2 * * * bash /srv/nefwarehouse/infra/backup.sh >> /srv/nefwarehouse/backups/log 2>&1') | crontab -"
```

Nightly, into `/srv/nefwarehouse/backups`: the database and the photographs,
three weeks kept. Nothing else is worth copying — the code is in git and the
containers are in a Dockerfile.

Run it once by hand now, and then **restore one into a spare database**. A
backup nobody has ever restored is a hope, not a backup — and this script has
already been wrong once, archiving an empty folder every night while reporting
success. It now refuses to finish if the dump is tiny or if there are
photographs on disk that did not make it into the archive.

Turn on Hetzner's own backups too. They cover the machine itself going, which a
file in a folder on that machine does not.

---

## Day to day

`git push` in either repository — `nefwarehouse` for the landing page and the
server configuration, `nefwams` for the warehouse system. That is the whole
deployment.

```powershell
# what is running
ssh deploy@SERVER "cd /srv/nefwarehouse/infra && docker compose ps"

# what the app is saying
ssh deploy@SERVER "cd /srv/nefwarehouse/infra && docker compose logs wms --tail 80"

# after editing infra/env/wms.env, to put email settings in
ssh deploy@SERVER "cd /srv/nefwarehouse/infra && docker compose up -d wms"
```

---

## When it goes wrong

**`bootstrap.sh: line 2: $'\r': command not found`**
Windows line endings. `.gitattributes` prevents it, but if you copied the file
by hand: `sed -i 's/\r$//' /root/bootstrap.sh` and run it again.

**Deploy fails with `Permission denied (publickey)`**
`SSH_KEY` is wrong — usually the public key pasted instead of the private one.

**Deploy fails with `Host key verification failed`**
`SSH_KNOWN_HOSTS` is stale. If you rebuilt the server, its fingerprint changed.

**`https://` never works but `http://` does**
Caddy could not get a certificate, nearly always because the Cloudflare proxy
was on. Turn it grey, then `docker compose logs caddy --tail 50`.

**Every page is a 502**
The warehouse system is not running. `docker compose logs wms --tail 80`. The
usual cause on first boot is the schema step refusing to run because it would
lose data — it names the table.

**Sign-in bounces straight back to the form**
The app is not seeing HTTPS, so it refuses to set a secure cookie. Check the
`header_up X-Forwarded-Proto` line is still in the Caddyfile.

**The build is killed partway**
Out of memory. `free -h` should show 2 GB of swap; if it does not, run
`bootstrap.sh` again.

---

## What must never be run against this database

```
npm run db:seed
npm run db:fresh
npm run db:reset-data
npm run db:restart
```

Those load development data. On the live warehouse they destroy the ledger.
Nothing in either deploy workflow calls them, and nothing should.
