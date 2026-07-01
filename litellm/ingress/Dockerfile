ARG ALPINE_IMAGE="alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache python3 \
 && addgroup -g 10001 ingressproxy \
 && adduser -D -H -u 10001 -G ingressproxy ingressproxy

COPY sanitize_proxy.py /app/sanitize_proxy.py

USER 10001
EXPOSE 4000
ENTRYPOINT ["python3", "/app/sanitize_proxy.py"]
