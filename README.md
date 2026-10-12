# ReachSky — Infra

Infrastruktura jako kod dla projektu ReachSky.
Ansible + Docker Compose + GitHub Actions + Cloudflare Tunnel.

Wdrożenie przez self-hosted runner na serwerze domowym za NAT.
Żaden port (80/443) nie jest wystawiony na router — ruch wychodzi przez `cloudflared`.

Sekrety zarządzane przez GitHub Secrets (CI) i plik `.deploy-env` (ręczne uruchomienia).
Brak Ansible Vault — uzasadnienie: [docs/adr/0001-github-secrets-zamiast-vault.md](docs/adr/0001-github-secrets-zamiast-vault.md).

```
ReachSky-dev/backend  ──push──►  Docker Hub  ──dispatch──►  ReachSky-dev/infra
ReachSky-dev/frontend ──push──►  Docker Hub  ──dispatch──►  ReachSky-dev/infra
                                                                    │
                                                              self-hosted runner
                                                                    │
                                                              ansible-playbook
                                                                    │
                                                           /opt/reachsky/{env}/
```

---

## Struktura repo

```
infra/
├── ansible.cfg
├── inventory.local.yml          ← bootstrap / runner (ansible_connection: local)
├── inventory.yml                ← zdalne (SSH z laptopa)
├── group_vars/
│   ├── all/vars.yml             ← wspólne: ansible_host, local_network_cidr + pochodne
│   ├── prod/vars.yml            ← konfiguracja prod — sekrety z env
│   └── demo/vars.yml            ← konfiguracja demo — sekrety z env
├── playbooks/
│   ├── site.yml                 ← jednorazowy setup serwera
│   ├── runner.yml               ← instalacja GitHub Actions runnera
│   ├── infra.yml                ← deploy/update stosu infra (postgres, KC, cloudflared)
│   ├── rollback.yml             ← ręczny rollback per serwis
│   └── apps/
│       ├── backend.yml
│       └── frontend.yml
├── roles/
│   ├── infra/                   ← postgres + keycloak + cloudflared
│   └── apps/
│       ├── backend/             ← deploy backendu po digestcie
│       └── frontend/            ← deploy frontendu po digestcie
├── docs/adr/                    ← Architecture Decision Records
├── init/
│   └── 01-keycloak-db.sql
└── keycloak/
    ├── prod/realm.json
    └── demo/realm.json
```

---

## FAZA A — Bootstrap z serwera (jednorazowo)

### A.1 — Utwórz plik /opt/reachsky/.deploy-env na serwerze

Przed pierwszym uruchomieniem Ansible na serwerze:

```bash
sudo mkdir -p /opt/reachsky
sudo tee /opt/reachsky/.deploy-env > /dev/null << 'EOF'
# Zmienne wymagane przez Ansible — nie commituj, nie loguj.
# Odpowiedniki GitHub Secrets dla ręcznych uruchomień.
ANSIBLE_HOST=192.168.0.X          # IP serwera w sieci lokalnej
LOCAL_NETWORK_CIDR=192.168.0.0/24 # CIDR sieci lokalnej (reguła SSH w UFW)
DB_PASSWORD_PROD=                 # silne hasło PostgreSQL dla prod
DB_PASSWORD_DEMO=                 # silne hasło PostgreSQL dla demo (inne niż prod)
KC_ADMIN_PASSWORD_PROD=           # hasło panelu /admin Keycloaka (prod)
KC_ADMIN_PASSWORD_DEMO=           # hasło panelu /admin Keycloaka (demo)
CF_TUNNEL_TOKEN_PROD=             # token tunelu Cloudflare (prod)
CF_TUNNEL_TOKEN_DEMO=             # token tunelu Cloudflare (demo)
EOF
sudo chmod 600 /opt/reachsky/.deploy-env
sudo chown reachsky:reachsky /opt/reachsky/.deploy-env
```

Każdy playbook poprzedź:
```bash
source /opt/reachsky/.deploy-env && ansible-playbook ...
```

Plik jest poza repozytorium i nie ma go w `.gitignore` jako podpowiedź — jest w `/opt/reachsky/`, nie w katalogu repo.

### A.2 — Na serwerze: zainstaluj zależności

```bash
sudo apt update
sudo apt install -y python3 python3-pip ansible git
ansible-galaxy collection install community.general
```

### A.3 — Sklonuj repo

```bash
git clone https://github.com/ReachSky-dev/infra.git /opt/reachsky-infra
```

### A.4 — Uruchom site.yml lokalnie

```bash
cd /opt/reachsky-infra

source /opt/reachsky/.deploy-env

# Dry run:
ansible-playbook -i inventory.local.yml playbooks/site.yml --check --diff

# Konfiguracja serwera (oba środowiska):
ansible-playbook -i inventory.local.yml playbooks/site.yml

# Lub jedno środowisko:
ansible-playbook -i inventory.local.yml playbooks/site.yml -l prod
```

### A.5 — Uruchom infra.yml (pierwsze uruchomienie stack)

```bash
source /opt/reachsky/.deploy-env

ansible-playbook -i inventory.local.yml playbooks/infra.yml -l demo
ansible-playbook -i inventory.local.yml playbooks/infra.yml -l prod
```

### A.6 — Pierwsze wdrożenie serwisów (przed CI/CD)

```bash
source /opt/reachsky/.deploy-env

# Znajdź digest:
docker pull rafals57/reachsky-backend:latest
docker inspect --format='{{index .RepoDigests 0}}' rafals57/reachsky-backend:latest

ansible-playbook -i inventory.local.yml playbooks/apps/backend.yml -l demo \
  -e "backend_digest=sha256:..." -e "backend_commit=abc123"

ansible-playbook -i inventory.local.yml playbooks/apps/frontend.yml -l demo \
  -e "frontend_digest=sha256:..." -e "frontend_commit=abc123"
```

---

## FAZA B — Self-hosted runner (jednorazowo)

### B.1 — Token rejestracyjny

GitHub → repo `infra` → **Settings → Actions → Runners → New self-hosted runner**
→ Linux → skopiuj wartość po `--token`. Token jest jednorazowy, wygasa po 1h.

### B.2 — Zainstaluj runner

```bash
source /opt/reachsky/.deploy-env

cd /opt/reachsky-infra
ansible-playbook -i inventory.local.yml playbooks/runner.yml \
  -e "runner_token=<TOKEN-Z-GITHUB>"
```

### B.3 — Weryfikacja

```bash
systemctl status "actions.runner.*"
# GitHub → repo → Settings → Actions → Runners → Status: Idle
```

---

## FAZA C — GitHub: sekrety, środowiska, token dispatch (jednorazowo)

### C.1 — Sekrety w repo `infra`

Ustawiasz w: repo `infra` → Settings → Secrets and variables → Actions → Secrets.

| Sekret | Wartość | Skąd wziąć |
|--------|---------|------------|
| `ANSIBLE_HOST` | `192.168.0.X` | IP serwera w sieci lokalnej |
| `LOCAL_NETWORK_CIDR` | `192.168.0.0/24` | CIDR sieci lokalnej |
| `DB_PASSWORD_PROD` | silne hasło | wygeneruj: `openssl rand -base64 32` |
| `DB_PASSWORD_DEMO` | silne hasło | wygeneruj: `openssl rand -base64 32` (inne niż prod) |
| `KC_ADMIN_PASSWORD_PROD` | silne hasło | wygeneruj: `openssl rand -base64 32` |
| `KC_ADMIN_PASSWORD_DEMO` | silne hasło | wygeneruj: `openssl rand -base64 32` |
| `CF_TUNNEL_TOKEN_PROD` | token tunelu | Zero Trust → Tunnels → reachsky-prod → token |
| `CF_TUNNEL_TOKEN_DEMO` | token tunelu | Zero Trust → Tunnels → reachsky-demo → token |

### C.2 — Zmienna w repo `infra`

| Zmienna | Wartość |
|---------|---------|
| `DOCKERHUB_USERNAME` | `rafals57` |

### C.3 — Środowiska w repo `infra`

Settings → Environments:
- **`demo`** — bez reviewers (wdraża automatycznie)
- **`production`** — Required reviewers: Ty

### C.4 — Token dispatch (PAT) w repo `backend` i `frontend`

1. GitHub → Settings (user) → Developer settings → Personal access tokens → **Fine-grained**
2. Resource owner: `ReachSky-dev`, Repository: `infra`
3. Uprawnienia: **Contents: Read and write**
4. Token → sekret `INFRA_DISPATCH_TOKEN` w repo `backend` i `frontend`

### C.5 — Sekrety w repo `backend` i `frontend`

| Nazwa | Typ | Wartość |
|-------|-----|---------|
| `DOCKERHUB_TOKEN` | Secret | Access Token z Docker Hub |
| `INFRA_DISPATCH_TOKEN` | Secret | PAT z kroku C.4 |
| `DOCKERHUB_USERNAME` | Variable | `rafals57` |

---

## Jak dodać nowy serwis

1. Utwórz rolę:
   ```bash
   mkdir -p roles/apps/mojserwis/{tasks,handlers,templates}
   ```
2. Skopiuj `roles/apps/backend/` jako punkt startowy, zmień nazwę serwisu i obraz.
3. `playbooks/apps/mojserwis.yml` — jeden play, jeden `role: apps/mojserwis`.
4. `group_vars/all/vars.yml` — dodaj `mojserwis_dir`, `mojserwis_project`.
5. `group_vars/prod/vars.yml` i `demo/vars.yml` — dodaj `mem_mojserwis`; jeśli serwis ma własne sekrety, dodaj lookup(`env`, `MOJSERWIS_SECRET_PROD/DEMO`).
6. `.github/workflows/deploy.yml` — dodaj `deploy-mojserwis` do `types:` i dwa joby (demo + prod).
7. GitHub → repo infra → Settings → Secrets — dodaj nowe sekrety.
8. W repo serwisu: po pushu obrazu wywołaj `repository_dispatch` z `event-type: deploy-mojserwis`.

---

## Jak dodać nowe środowisko

1. `inventory.yml` i `inventory.local.yml` — dodaj host `reachsky-staging`.
2. `group_vars/staging/vars.yml` — wzorzec z `group_vars/demo/vars.yml`, zmień `env_name`, URLs, limity RAM, zmień sufiks sekretów na `_STAGING`.
3. `/opt/reachsky/.deploy-env` — dodaj zmienne z sufiksem `_STAGING`.
4. GitHub → repo infra → Settings → Secrets — dodaj sekrety `_STAGING`.
5. Bootstrap: `source /opt/reachsky/.deploy-env && ansible-playbook ... playbooks/site.yml -l staging`.
6. GitHub Settings → Environments → utwórz `staging`.
7. `.github/workflows/deploy.yml` — dodaj joby `deploy-*-staging`.
8. `.github/workflows/rollback.yml` — dodaj `staging` do listy `options`.
