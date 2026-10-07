FROM node:24-alpine

RUN addgroup -S proxy && adduser -S -G proxy proxy

WORKDIR /app
COPY proxy.mjs /app/proxy.mjs
RUN chown -R proxy:proxy /app

USER proxy

ENV LISTEN_HOST=0.0.0.0
ENV LISTEN_PORT=3128
ENV ALLOWED_HOSTS=github.com,api.github.com,api.githubcopilot.com,api.individual.githubcopilot.com,api.business.githubcopilot.com,api.enterprise.githubcopilot.com

EXPOSE 3128

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "require('node:net').connect(3128, '127.0.0.1').on('connect', function(){this.end(); process.exit(0)}).on('error', function(){process.exit(1)})"

CMD ["node", "/app/proxy.mjs"]
