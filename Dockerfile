FROM eclipse-temurin:17-jdk 

RUN groupadd -r petclinic && useradd -r -g petclinic petclinic

WORKDIR /app
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN chmod +x mvnw
RUN ./mvnw dependency:go-offline -q
COPY src/ src/
RUN ./mvnw package -DskipTests -q && \
    cp target/spring-petclinic-*.jar app.jar && \
    rm -rf target ~/.m2/repository
RUN chown -R petclinic:petclinic /app
USER petclinic
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
