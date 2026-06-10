-- ============================================================
-- Script d'initialisation minimal – table users
-- À exécuter UNE SEULE FOIS sur la base PostgreSQL cible.
-- Hibernate peut aussi générer cette table automatiquement
-- via spring.jpa.hibernate.ddl-auto=update (voir application.properties).
-- ============================================================

CREATE TABLE IF NOT EXISTS users (
    id    BIGSERIAL    PRIMARY KEY,
    name  VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE
);
