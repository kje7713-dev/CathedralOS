# =============================================================================
# EPUBCheck Validator — Cloud Run container image
#
# Multi-stage build:
#   1. Builder: maven:3.9-eclipse-temurin-17 — compile + shade our Java service
#   2. Runtime: eclipse-temurin:17-jre-alpine — runs app + vendored EPUBCheck 5.3.0
# =============================================================================

# ----- Builder -----
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /build

# Cache dependencies first
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -q package -DskipTests

# ----- Runtime -----
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app

ARG EPUBCHECK_VERSION=5.3.0

# Install EPUBCheck 5.3.0 from W3C official GitHub release
RUN apk add --no-cache curl unzip bash \
    && curl -sL "https://github.com/w3c/epubcheck/releases/download/v${EPUBCHECK_VERSION}/epubcheck-${EPUBCHECK_VERSION}.zip" -o /tmp/epubcheck.zip \
    && unzip -q /tmp/epubcheck.zip -d /opt/epubcheck \
    && rm /tmp/epubcheck.zip \
    && ln -s "/opt/epubcheck/epubcheck-${EPUBCHECK_VERSION}/epubcheck.jar" /app/epubcheck.jar \
    && apk del curl unzip

# Copy our service JAR
COPY --from=builder /build/target/epubcheck-validator.jar /app/app.jar

# Non-root user for runtime security
RUN addgroup -S appuser && adduser -S appuser -G appuser && chown -R appuser:appuser /app
USER appuser

ENV PORT=8080 \
    EPUBCHECK_JAR=/app/epubcheck.jar \
    EPUBCHECK_TIMEOUT_SECONDS=60 \
    MAX_EPUB_SIZE_MB=100

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -q -O- http://localhost:8080/health || exit 1

ENTRYPOINT ["java", "-XX:+UseContainerSupport", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
