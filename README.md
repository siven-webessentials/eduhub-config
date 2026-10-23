# EDU-HUB-2: Full-Stack HTTPS Dev Environment (+ Adminer)

Personal notes: Next.js + Spring Boot + Postgres, running in Docker Compose behind Traefik with local HTTPS, and Adminer for browsing the database.

Each phase ends with a check, so you know it works before moving on.

## Table of contents

**Part 1: Full-stack dev setup**

- [The plan](#the-plan)
- [Phase 0: Install the tools](#phase-0-install-the-tools-once)
- [Phase 1: Next.js frontend](#phase-1-create-the-nextjs-frontend-and-test-it)
- [Phase 2: Spring Boot backend](#phase-2-create-the-spring-boot-backend-and-test-it)
- [Phase 3: Config folder](#phase-3-prepare-the-config-folder)
- [Phase 4: Makefile](#phase-4-makefile-hosts--certificates)
- [Phase 5: Docker Compose](#phase-5-docker-compose)
- [Phase 6: Start everything](#phase-6-start-everything)
- [Phase 7: Verify hot reload](#phase-7-verify-hot-reload)
- [Daily commands](#daily-commands)
- [Troubleshooting](#troubleshooting)

**Part 2: Adminer the professional way**

- [Adminer setup](#part-2-adding-adminer-the-professional-way)

---

# Part 1: Full-stack dev setup

## The plan

```
EDU-HUB-2/
├── eduhub-config/          # docker-compose, Traefik config, certs, .env, Makefile
│   ├── docker-compose.yml
│   ├── .env
│   ├── .env.example
│   ├── Makefile
│   ├── certs/              # generated: local-cert.pem + local-key.pem
│   └── traefik/tls.yml
├── eduhub-core/            # Spring Boot (Maven)
└── eduhub-webclient/       # Next.js (pnpm)
```

How the pieces connect:

- Browser → `https://eduhub.test` → **Traefik** (TLS ends here)
- Traefik sends `/` to Next.js (port 3000) and `/api/*` to Spring Boot (port 8080)
- Spring Boot talks to Postgres inside the Docker network

Two decisions made:

- **Domain `eduhub.test`**, not `.local`. `.test` is reserved for testing and never collides with a real domain. `.local` is used by mDNS and can cause slow lookups.
- **One domain, path-based routing** (`/api` goes to the backend). The browser sees a single origin, so you avoid CORS problems entirely.

---

## Phase 0: Install the tools (once)

Check each one:

```bash
docker --version
docker compose version
node --version        # 20+ is fine
java --version        # needs 21 for the first local test
```

Then install pnpm and mkcert:

```bash
npm install -g pnpm   # or: corepack enable
# mkcert (makes certificates your browser trusts):
# macOS:
brew install mkcert nss
# Ubuntu/Debian:
sudo apt install libnss3-tools mkcert
```

If `apt` can't find `mkcert`, download it from github.com/FiloSottile/mkcert/releases.

---

## Phase 1: Create the Next.js frontend and test it

```bash
cd EDU-HUB-2/eduhub-webclient
pnpm create next-app@latest .
```

Answer the prompts (TypeScript yes, ESLint yes, Tailwind as you like, App Router yes, pnpm). The `.` means "create it in this folder".

```bash
pnpm dev
```

Open http://localhost:3000. If you see the Next.js welcome page, stop with `Ctrl+C`. ✅

---

## Phase 2: Create the Spring Boot backend and test it

1. Go to **https://start.spring.io** and choose:
   - Project: **Maven**, Language: **Java**
   - Spring Boot: the latest **stable** version (no SNAPSHOT)
   - Group: `com.eduhub`, Artifact: `eduhub-core`
   - Packaging: **Jar**, Java: **21**
   - Dependencies: **Spring Web**, **Spring Data JPA**, **PostgreSQL Driver**, **Spring Boot DevTools**, **Spring Boot Actuator**
2. Click **Generate**, then unzip the contents **directly into** `eduhub-core/`, so `pom.xml` sits at `eduhub-core/pom.xml`.

3. Add a test endpoint. Create `HelloController.java` in the same package as the main `@SpringBootApplication` class (e.g. `src/main/java/com/eduhub/eduhubcore/`). Fix the `package` line to match:

```java
package com.eduhub.eduhubcore;

import java.util.Map;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api")
public class HelloController {
    @GetMapping("/hello")
    public Map<String, String> hello() {
        return Map.of("message", "Hello from Spring Boot");
    }
}
```

4. Replace `src/main/resources/application.properties`:

```properties
spring.application.name=eduhub-core
spring.datasource.url=${DB_URL:jdbc:postgresql://localhost:5432/eduhub}
spring.datasource.username=${DB_USERNAME:eduhub}
spring.datasource.password=${DB_PASSWORD:change_me}
spring.jpa.hibernate.ddl-auto=update
server.forward-headers-strategy=framework
```

5. Because we added JPA, the app needs a database to start. Start a throwaway Postgres:

```bash
docker run --name eduhub-pg-test -e POSTGRES_DB=eduhub -e POSTGRES_USER=eduhub \
  -e POSTGRES_PASSWORD=change_me -p 5432:5432 -d postgres:17
```

6. Run the backend:

```bash
cd eduhub-core
./mvnw spring-boot:run
```

7. Open http://localhost:8080/api/hello. You should see the JSON message. Stop with `Ctrl+C`, then delete the test DB:

```bash
docker rm -f eduhub-pg-test
```

✅

---

## Phase 3: Prepare the config folder

```bash
cd EDU-HUB-2/eduhub-config
mkdir certs traefik
```

### `.env`

```env
HOST_NAME=eduhub.test
POSTGRES_DB=eduhub
POSTGRES_USER=eduhub
POSTGRES_PASSWORD=change_me_to_something_strong
```

Also copy it to `.env.example` with fake values. You commit that one; the real `.env` stays private.

> **About keeping keys in `.env`:** passwords and the hostname go in `.env`. The certificate and private key are **files**, and Traefik reads them from files. Its file provider can't read them from environment variables. So they live in `certs/`, and we keep that folder out of git.

### `.gitignore` (in `EDU-HUB-2/`)

```gitignore
eduhub-config/.env
eduhub-config/certs/
node_modules/
.next/
target/
```

### `traefik/tls.yml`

```yaml
tls:
  certificates:
    - certFile: /certs/local-cert.pem
      keyFile: /certs/local-key.pem
```

---

## Phase 4: Makefile (hosts + certificates)

Create `eduhub-config/Makefile`. **Indented lines must start with a TAB, not spaces**, or `make` fails.

```makefile
include .env
export

.PHONY: hosts certs up down logs ps

hosts:
	@grep -q " $(HOST_NAME)$$" /etc/hosts || sudo bash -c "echo 0.0.0.0 $(HOST_NAME) >> /etc/hosts"
	@echo "hosts entry OK for $(HOST_NAME)"

certs:
	mkdir -p certs
	mkcert -install
	mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem $(HOST_NAME)

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

ps:
	docker compose ps
```

The `grep` check stops the line from being added twice if you run `make hosts` again. If `0.0.0.0` ever misbehaves, use `127.0.0.1` instead.

Run it:

```bash
make hosts
make certs
ls certs     # should show local-cert.pem and local-key.pem
```

✅

---

## Phase 5: Docker Compose

Create `eduhub-config/docker-compose.yml`:

```yaml
name: eduhub

services:
  traefik:
    image: traefik:v3.6
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.file.filename=/etc/traefik/dynamic/tls.yml
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --log.level=INFO
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/tls.yml:/etc/traefik/dynamic/tls.yml:ro
      - ./certs:/certs:ro

  postgres:
    image: postgres:17
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10

  core:
    image: maven:3.9-eclipse-temurin-21
    working_dir: /app
    command: mvn spring-boot:run
    environment:
      DB_URL: jdbc:postgresql://postgres:5432/${POSTGRES_DB}
      DB_USERNAME: ${POSTGRES_USER}
      DB_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ../eduhub-core:/app
      - maven_cache:/root/.m2
    depends_on:
      postgres:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.http.routers.api.rule=Host(`${HOST_NAME}`) && PathPrefix(`/api`)
      - traefik.http.routers.api.entrypoints=websecure
      - traefik.http.routers.api.tls=true
      - traefik.http.services.api.loadbalancer.server.port=8080

  webclient:
    image: node:22-alpine
    working_dir: /app
    command: sh -c "corepack enable && pnpm install && pnpm dev -H 0.0.0.0"
    environment:
      HOST_NAME: ${HOST_NAME}
      WATCHPACK_POLLING: "true"
    volumes:
      - ../eduhub-webclient:/app
      - webclient_node_modules:/app/node_modules
    labels:
      - traefik.enable=true
      - traefik.http.routers.web.rule=Host(`${HOST_NAME}`)
      - traefik.http.routers.web.entrypoints=websecure
      - traefik.http.routers.web.tls=true
      - traefik.http.services.web.loadbalancer.server.port=3000

volumes:
  postgres_data:
  maven_cache:
  webclient_node_modules:
```

What the less obvious parts do:

- **`../eduhub-core:/app`** mounts your source into the container. This is what gives you hot reload without building an image.
- **`webclient_node_modules` volume** keeps `node_modules` inside Docker, so your host's copy doesn't clash with the container's (different OS, different native binaries).
- **`maven_cache` volume** stops Maven from re-downloading every dependency on each restart.
- **`PathPrefix(/api)`** is a longer rule than the web router's, so Traefik automatically picks it for `/api` requests.
- **`WATCHPACK_POLLING`** makes file watching reliable on Docker Desktop (Mac/Windows). It is harmless on Linux.

### One small Next.js change

Open `eduhub-webclient/next.config.ts` and allow your custom domain for dev assets:

```ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  allowedDevOrigins: [process.env.HOST_NAME ?? "localhost"],
};

export default nextConfig;
```

---

## Phase 6: Start everything

```bash
cd EDU-HUB-2/eduhub-config
make up
make logs
```

The first start is slow (it downloads images, then Maven and pnpm dependencies). Wait until you see Spring's `Started ... in X seconds` and Next's `Ready`. Check with `make ps`; all four services should be `running`.

Test:

- https://eduhub.test shows the Next.js page, with a padlock and no certificate warning
- https://eduhub.test/api/hello shows the JSON
- http://eduhub.test redirects to https ✅

---

## Phase 7: Verify hot reload

**Frontend:** edit `eduhub-webclient/app/page.tsx`, save, and watch the browser update by itself.

**Backend:** change the message in `HelloController`, save, and reload `/api/hello`.

Spring DevTools only restarts when the **compiled classes change**, and nothing compiles for you inside the container. You have two ways to handle that:

**Option A (recommended): let your IDE compile on save.**

- **VS Code:** install "Extension Pack for Java". Auto-build is on by default, so saving writes to `target/classes` and DevTools restarts the app within a few seconds.
- **IntelliJ:** enable *Settings → Build → Compiler → Build project automatically*, and in *Advanced Settings* enable *Allow auto-make to start even if developed application is currently running*.

**Option B: a watcher container that compiles for you** (works in any editor). Add this service to the compose file:

```yaml
  core-watcher:
    image: maven:3.9-eclipse-temurin-21
    working_dir: /app
    command: >
      sh -c "apt-get update -qq && apt-get install -y -qq inotify-tools &&
             while inotifywait -r -e modify,create,delete,move src/main; do mvn -q compile; done"
    volumes:
      - ../eduhub-core:/app
      - maven_cache:/root/.m2
    depends_on:
      - core
```

Then run `docker compose up -d`.

---

## Daily commands

| Task | Command |
|---|---|
| Start | `make up` |
| Stop | `make down` |
| Logs | `make logs` or `docker compose logs -f core` |
| Restart one service | `docker compose restart core` |
| Full reset including DB | `docker compose down -v` (deletes the data!) |
| Add a frontend dependency | `docker compose exec webclient pnpm add <pkg>` |

---

## Troubleshooting

- **Browser says "not secure":** run `make certs` again and restart the browser. Linux needs `libnss3-tools` installed first.
- **Site can't be reached:** check `cat /etc/hosts | grep eduhub`. Also make sure no local service already uses port 80 or 443.
- **404 from Traefik:** the container isn't running or its labels are wrong. Check `make ps` and `docker compose logs traefik`.
- **Traefik log says "client version … is too old":** your Docker is newer than your Traefik. Use the latest `traefik:v3.x` tag.
- **Files in `target/` are owned by root** (because the container runs as root). Fix with `sudo chown -R $USER:$USER eduhub-core/target`.
- **Spring fails to connect to the DB:** the `DB_URL` must use the host `postgres` (the service name), not `localhost`.

---

# Part 2: Adding Adminer the professional way

Why this setup:

- **Don't publish Adminer's port** (`8080:8080`). Put it behind Traefik like everything else, so you get HTTPS with the same certificate setup.
- **Use its own subdomain**, `adminer.eduhub.test`. Adminer doesn't work well under a path like `/adminer`, so a subdomain is the clean choice.
- **Use a compose profile** so it only starts when you need it. A database admin tool shouldn't run all the time.
- **Dev only.** Never ship Adminer to production.

---

## Step 1: Update `.env`

Add one line to `eduhub-config/.env` (and to `.env.example`):

```env
HOST_NAME=eduhub.test
ADMINER_HOST=adminer.eduhub.test
POSTGRES_DB=eduhub
POSTGRES_USER=eduhub
POSTGRES_PASSWORD=change_me_to_something_strong
```

---

## Step 2: Update the Makefile

Two things change. `/etc/hosts` doesn't support wildcards, so every hostname needs its own entry. The certificate must also cover the new name.

Replace your whole `Makefile` with this (indented lines start with a **TAB**):

```makefile
include .env
export

.PHONY: hosts certs up tools-up down logs ps

hosts:
	@for h in $(HOST_NAME) $(ADMINER_HOST); do \
		grep -q " $$h$$" /etc/hosts || sudo bash -c "echo 0.0.0.0 $$h >> /etc/hosts"; \
		echo "hosts entry OK for $$h"; \
	done

certs:
	mkdir -p certs
	mkcert -install
	mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem $(HOST_NAME) $(ADMINER_HOST)

up:
	docker compose up -d

tools-up:
	docker compose --profile tools up -d

down:
	docker compose --profile tools down

logs:
	docker compose logs -f

ps:
	docker compose ps
```

Run:

```bash
cd EDU-HUB-2/eduhub-config
make hosts
make certs
```

`make certs` replaces the old certificate with one valid for both `eduhub.test` and `adminer.eduhub.test`. Check that the hosts file now has both:

```bash
grep eduhub /etc/hosts
```

---

## Step 3: Add the Adminer service

In `docker-compose.yml`, add this under `services:` (for example, after `postgres`):

```yaml
  adminer:
    image: adminer:5
    profiles: ["tools"]
    environment:
      ADMINER_DEFAULT_SERVER: postgres
    depends_on:
      postgres:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.http.routers.adminer.rule=Host(`${ADMINER_HOST}`)
      - traefik.http.routers.adminer.entrypoints=websecure
      - traefik.http.routers.adminer.tls=true
      - traefik.http.services.adminer.loadbalancer.server.port=8080
```

What the parts mean:

- **`profiles: ["tools"]`**: a plain `docker compose up -d` skips this service. You start it on purpose.
- **`ADMINER_DEFAULT_SERVER: postgres`**: pre-fills the server field with your Postgres service name, so you don't type it each time.
- **No `ports:` section**: nothing is exposed on your machine. The only way in is through Traefik over HTTPS.
- **`adminer:5`**: pinned to a major version so it doesn't change under you. If Docker says the tag isn't found, use `adminer:latest`.

---

## Step 4: Start it

Traefik needs to reload the new certificate, so restart it, then start the tools profile:

```bash
make down
make up
make tools-up
make ps
```

You should now see `adminer` as `running`.

---

## Step 5: Log in

Open **https://adminer.eduhub.test** and fill in:

| Field | Value |
|---|---|
| System | **PostgreSQL** (change this from MySQL!) |
| Server | `postgres` (already pre-filled) |
| Username | value of `POSTGRES_USER` in `.env` |
| Password | value of `POSTGRES_PASSWORD` in `.env` |
| Database | value of `POSTGRES_DB` (e.g. `eduhub`) |

Server is `postgres`, not `localhost`. Adminer runs inside the Docker network, where `postgres` is the service name. This is the same reason Spring Boot uses `postgres` in its `DB_URL`.

After you log in, you can browse tables, run SQL, and export data.

---

## Adminer troubleshooting

- **Browser shows a certificate warning for Adminer:** you skipped `make certs` after adding the new host, or didn't restart Traefik. Run `make certs`, then `docker compose restart traefik`, then reload the page.
- **"Site can't be reached":** check `grep adminer /etc/hosts`. If it's missing, run `make hosts`.
- **404 from Traefik:** Adminer isn't running. Remember `make up` does not start it. Use `make tools-up`.
- **Login fails:** check you picked **PostgreSQL** in the System dropdown, and that the password matches your `.env`. Adminer refuses empty passwords by default, which is a good thing.
- **You changed `POSTGRES_PASSWORD` after the first start but login still uses the old one:** Postgres only reads that variable the first time the volume is created. Either change the password inside the DB, or reset with `docker compose down -v` (this deletes your data).

---

## Optional: use a desktop client instead

If you later prefer DBeaver, DataGrip or pgAdmin, add this to the `postgres` service:

```yaml
    ports:
      - "127.0.0.1:5432:5432"
```

The `127.0.0.1:` prefix is the important part. It means only your own computer can connect, not other devices on your network. Without it, Docker publishes the port on all network interfaces.

---

## Extra note: why Adminer and `core` can both use port 8080

The `8080` in `traefik.http.services.adminer.loadbalancer.server.port=8080` is the port **inside the container**, not a port on your computer. Each container has its own private network space, so two containers can both use 8080 without conflict.

- Spring Boot (`core`) listens on 8080 because that is Spring's default.
- Adminer's official image also listens on 8080 because that is how it was built.

Traefik reaches each one by its own container address (`core:8080` and `adminer:8080`), so they are two different places.

A conflict only happens when you publish ports to your host with `ports: "8080:8080"` on two services. We don't do that. Only Traefik publishes ports (80 and 443), and it routes by hostname and path:

- `eduhub.test/api` goes to `core:8080`
- `adminer.eduhub.test` goes to `adminer:8080`

---

## Next step

Add **Flyway** for database migrations, so your schema changes are versioned and you can stop relying on `ddl-auto=update`.
