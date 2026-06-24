FROM nginxinc/nginx-unprivileged:1.28-alpine
RUN apk upgrade --no-cache
COPY html/ /usr/share/nginx/html/
EXPOSE 8080
