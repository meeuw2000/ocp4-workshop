server.port=5080
management.server.port=5081
management.endpoints.web.exposure.include=*

spring.profiles.active=default

spring.datasource.url=jdbc:h2:mem:mail
spring.datasource.username=admin
spring.datasource.password=localhost
spring.datasource.driver-class-name=org.h2.Driver

spring.jpa.hibernate.ddl-auto=validate
spring.mvc.hiddenmethod.filter.enabled=true
spring.h2.console.enabled=true

fakesmtp.port=${SMTP_PORT}
fakesmtp.persistence.maxNumberEmails=10
fakesmtp.authentication.username=${SMTP_USER}
fakesmtp.authentication.password=${SMTP_PASS}