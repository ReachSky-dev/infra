-- Tworzy bazę keycloak przy pierwszym uruchomieniu kontenera postgres.
-- Skrypt wykonuje się raz — przy pustym wolumenie postgres_data.
-- Właścicielem jest POSTGRES_USER (reachsky), który jest superuserem.
CREATE DATABASE keycloak;
