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

# --- Stage 2: Hardened Runtime environment using Google Distroless ---
FROM gcr.io/distroless/java17-debian12:nonroot
WORKDIR /app

# Copy the compiled JAR from the builder stage
COPY --from=builder /app/target/*.jar app.jar

EXPOSE 8080

# Run the jar file securely 
# Note: Distroless automatically runs as the low-privilege "nonroot" user via the tag
ENTRYPOINT ["java", "-jar", "app.jar"]