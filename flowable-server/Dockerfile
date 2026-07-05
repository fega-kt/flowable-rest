# =============================================================
# Stage 1 — Build
# Maven build ra fat JAR (spring-boot-maven-plugin repackage)
# =============================================================
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /app

# Copy pom.xml trước để tận dụng Docker layer cache khi chỉ sửa code (không sửa deps)
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copy source rồi build, bỏ qua test trong Docker build
COPY src ./src
RUN mvn package -DskipTests -B

# =============================================================
# Stage 2 — Runtime
# Chỉ cần JRE, image nhỏ hơn JDK
# =============================================================
FROM eclipse-temurin:17-jre-jammy

WORKDIR /app

# Tạo user không phải root để chạy app (security best practice)
RUN groupadd -r flowable && useradd -r -g flowable flowable
USER flowable

COPY --from=build /app/target/flowable-server-*.jar app.jar

# Port mà Spring Boot listen (khớp với server.port trong application.yml)
EXPOSE 8080

# JVM tuning cơ bản cho container
ENTRYPOINT ["java", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=75.0", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
