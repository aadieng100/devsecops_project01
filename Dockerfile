# --- Stage 1: Build the application ---
FROM eclipse-temurin:17-jdk-alpine AS builder
WORKDIR /app

# Copy Maven wrapper and pom.xml to cache dependencies
COPY .mvn/ .mvn
COPY mvnw pom.xml ./
RUN ./mvnw dependency:go-offline

# Copy source code and build the application packaging
COPY src ./src
RUN ./mvnw clean package -DskipTests

# --- Stage 2: Runtime environment ---
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app

# SECURITY: Create a non-root group and user
RUN addgroup -S devsecopsgroup && adduser -S devsecopsuser -G devsecopsgroup

# Copy the compiled JAR from the builder stage
COPY --from=builder /app/target/*.jar app.jar

# SECURITY: Change ownership of the application files to the non-root user
RUN chown -R devsecopsuser:devsecopsgroup /app

# SECURITY: Switch to the non-root user
USER devsecopsuser

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]