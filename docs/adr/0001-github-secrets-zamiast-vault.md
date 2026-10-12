# ADR 0001 — GitHub Secrets zamiast Ansible Vault

**Data:** 2026-10-12
**Status:** Zaakceptowany

---

## Kontekst

Projekt wdraża dwa środowiska (prod, demo) na jednym serwerze domowym.
Sekrety wymagane przez Ansible to:

- `ANSIBLE_HOST` — IP serwera (współdzielony)
- `LOCAL_NETWORK_CIDR` — CIDR sieci lokalnej (współdzielony)
- `DB_PASSWORD_{PROD,DEMO}` — hasła PostgreSQL
- `KC_ADMIN_PASSWORD_{PROD,DEMO}` — hasła panelu Keycloak
- `CF_TUNNEL_TOKEN_{PROD,DEMO}` — tokeny tunelu Cloudflare

Łącznie: 8 wartości tajnych. Wszystkie wdrożenia odbywają się przez self-hosted runner
z GitHub Actions. Ręczne uruchomienia Ansible ze stacji roboczej są rzadkie (tylko bootstrap).

---

## Rozważane opcje

### Opcja A — Ansible Vault (odrzucona)

Sekrety szyfrowane per środowisko (`group_vars/{env}/vault.yml`), odszyfrowane przez
hasło przechowywane w `~/.vault_pass_reachsky` na serwerze i w `VAULT_PASSWORD` w GitHub Secrets.

**Zalety:**
- Zaszyfrowane sekrety są commitowane razem z kodem — historia w git
- Można uruchomić playbook bez dostępu do GitHub, jeśli hasło jest na dysku
- Wersjonowanie zmian sekretów (kiedy co zostało zmienione)

**Wady:**
- Dwa poziomy haseł: hasło chroni hasła
- Kopiowanie zaszyfrowanych plików między maszynami i repo jest procedurą z punktami awarii
- Każda rotacja sekretu wymaga: deszyfrowania, edycji, ponownego szyfrowania, commita, pusha
- Przy jednym serwerze i dwóch środowiskach narzut proceduralny nie ma pokrycia w korzyściach

### Opcja B — GitHub Secrets + lookup('env', ...) (wybrana)

Sekrety przechowywane w GitHub Secrets (CI) i w `/opt/reachsky/.deploy-env` (ręczne uruchomienia).
Ansible odczytuje je przez `lookup('env', 'NAZWA')` z błędem przy braku.

**Zalety:**
- Jeden mechanizm zamiast dwóch (vault + CI)
- Rotacja: zmiana wartości w GitHub UI, bez commita
- GitHub Secrets szyfruje wartości i maskuje je w logach
- Brak pliku `vault_password_file` — mniejsza powierzchnia ataku na serwerze

**Wady:**
- Brak historii zmian sekretów (GitHub nie wersjonuje sekretów)
- Brak możliwości uruchomienia playbooka bez ustawienia zmiennych środowiskowych
  (plik `.deploy-env` zastępuje tę możliwość dla ręcznych uruchomień, ale wymaga
  wcześniejszego ustawienia go na serwerze)
- Sekrety nie są archiwizowane razem z kodem — utrata dostępu do GitHub = utrata sekretów

### Opcja C — Zewnętrzny menedżer sekretów (HashiCorp Vault, AWS Secrets Manager)

**Wady w tym kontekście:**
- Nowa zależność zewnętrzna przy projekcie single-server
- Konfiguracja i utrzymanie kolejnego systemu
- Nieuzasadniony narzut przy 8 sekretach

---

## Decyzja

**Opcja B — GitHub Secrets + lookup('env', ...)**

Przy jednym serwerze, dwóch środowiskach i wszystkich deployach przez CI narzut Vaulta
nie jest uzasadniony. GitHub Secrets zapewnia wystarczające bezpieczeństwo: wartości
zaszyfrowane w spoczynku, maskowane w logach, dostępne tylko dla wybranych środowisk.

---

## Konsekwencje

### Co zyskujemy
- Prostszy onboarding: nowy secret = jedno pole w GitHub UI, bez szyfrowania pliku
- Rotacja bez commita: zmiana wartości w GitHub, re-run workflow
- Mniej plików do zarządzania w repo

### Co tracimy
- **Brak historii sekretów:** nie można odpowiedzieć na pytanie "kiedy zmieniliśmy hasło do bazy w prod"
- **Brak uruchomienia bez zmiennych środowiskowych:** jeśli `.deploy-env` nie istnieje na serwerze,
  playbook failuje z błędem `mandatory`. Przy Vaulcie wystarczyło hasło.
- **Brak archiwalności:** zaszyfrowany vault.yml w git można odtworzyć po roku. GitHub Secret —
  nie (GitHub nie ujawnia wartości po ustawieniu, nie można ich wyeksportować)

### Co musiałoby się zmienić (warunek powrotu do Vaulta)

Powrót do Ansible Vault byłby uzasadniony, gdy spełniony zostanie któryś z warunków:

1. **Drugi serwer** — sekrety różniące się per host (nie per środowisko), które muszą być
   dołączone do kodu hostów w `host_vars/`. GitHub Secrets nie ma granularności per host.
2. **Sekrety per commit** — konieczność wycofania konkretnej wersji konfiguracji razem
   z kodem aplikacji (rollback sekretu razem z rollbackiem obrazu).
3. **Środowiska offline** — wdrożenie bez dostępu do GitHub (air-gapped, on-premise bez internetu).
4. **Audyt zmian sekretów** — wymóg regulacyjny poświadczenia kiedy i przez kogo zmieniono sekret.
