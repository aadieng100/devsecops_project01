# DevSecOps – User API (Spring Boot 3 + PostgreSQL)

Projet minimal REST API servant de base à un **pipeline DevSecOps**.

## Structure du projet

```
devsecops_project01/
├── pom.xml
└── src/
    ├── main/
    │   ├── java/com/devsecops/userapi/
    │   │   ├── UserApiApplication.java      ← point d'entrée Spring Boot
    │   │   ├── model/User.java              ← entité JPA
    │   │   ├── repository/UserRepository.java
    │   │   └── controller/UserController.java
    │   └── resources/
    │       ├── application.properties       ← config avec variables d'env
    │       └── schema.sql                   ← DDL optionnel
    └── test/
        └── java/com/devsecops/userapi/
            └── UserApiApplicationTests.java
```

## Endpoints

| Méthode | URL               | Body JSON                                 | Réponse         |
|---------|-------------------|-------------------------------------------|-----------------|
| POST    | `/api/users`      | `{ "name": "Alice", "email": "a@b.com" }` | `201 Created`   |
| DELETE  | `/api/users/{id}` | –                                         | `204 No Content` ou `404` |

## Variables d'environnement requises

| Variable                    | Exemple                                       |
|-----------------------------|-----------------------------------------------|
| `SPRING_DATASOURCE_URL`     | `jdbc:postgresql://localhost:5432/devsecops`  |
| `SPRING_DATASOURCE_USERNAME`| `postgres`                                    |
| `SPRING_DATASOURCE_PASSWORD`| `secret`                                      |

## Lancer localement

```bash
# 1. Démarrer PostgreSQL (ex: Docker)
docker run -d \
  --name pg-devsecops \
  -e POSTGRES_DB=devsecops \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=secret \
  -p 5432:5432 \
  postgres:16-alpine

# 2. Exporter les variables et lancer l'app
export SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/devsecops
export SPRING_DATASOURCE_USERNAME=postgres
export SPRING_DATASOURCE_PASSWORD=secret

./mvnw spring-boot:run
```

## Tester les endpoints

```bash
# Créer un utilisateur
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","email":"alice@example.com"}'

# Supprimer l'utilisateur avec id=1
curl -X DELETE http://localhost:8080/api/users/1
```

## Notes DevSecOps

- **Secrets** : aucun identifiant dans le code, tout passe par des variables d'environnement.
- **DDL** : `ddl-auto=update` en dev ; basculer sur `validate` en production avec Flyway/Liquibase.
- **Tests** : le smoke test utilise H2 in-memory — aucune base réelle nécessaire en CI.
- **Prochaines étapes** : ajouter Spring Security, HTTPS, scanning SAST (Trivy, Snyk, SonarQube).
