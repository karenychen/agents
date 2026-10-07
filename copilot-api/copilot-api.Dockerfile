FROM node:24-alpine

ARG COPILOT_API_VERSION=1.14.9

RUN npm install -g "@jeffreycao/copilot-api@${COPILOT_API_VERSION}" \
  && npm cache clean --force \
  && mkdir -p /data \
  && chown -R node:node /data

USER node
WORKDIR /home/node

ENV COPILOT_API_HOME=/data
ENV HOME=/tmp
ENV NODE_ENV=production
ENV NODE_OPTIONS=--use-env-proxy
ENV NODE_USE_SYSTEM_CA=1

EXPOSE 4141

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:4141/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["copilot-api"]
CMD ["start", "--port", "4141", "--proxy-env"]
