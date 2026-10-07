FROM node:24-alpine

RUN addgroup -S proxy && adduser -S -G proxy proxy

WORKDIR /app
COPY proxy.mjs /app/proxy.mjs
RUN chown -R proxy:proxy /app

USER proxy

ENV LISTEN_HOST=0.0.0.0
ENV LISTEN_PORT=4000
ENV UPSTREAM_ORIGIN=http://copilot-api:4141

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:4000/').then(()=>process.exit(0)).catch(()=>process.exit(1))"

CMD ["node", "/app/proxy.mjs"]
