FROM nginxinc/nginx-unprivileged:1.28-alpine
USER root
RUN apk upgrade --no-cache
USER nginx
COPY html/ /usr/share/nginx/html/
EXPOSE 8080
