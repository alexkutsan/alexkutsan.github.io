# Use a minimal Debian base image
FROM debian:bookworm-slim AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates tar \
    && rm -rf /var/lib/apt/lists/*

ENV ZOLA_VERSION=0.20.0
RUN curl -L -o /tmp/zola.tar.gz "https://github.com/getzola/zola/releases/download/v${ZOLA_VERSION}/zola-v${ZOLA_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    && tar -xzf /tmp/zola.tar.gz -C /tmp \
    && mv /tmp/zola /usr/local/bin/zola \
    && chmod +x /usr/local/bin/zola \
    && rm /tmp/zola.tar.gz

WORKDIR /site
COPY . .
RUN zola build --base-url / && ls -l /site && ls -l /site/public


FROM caddy:2-alpine AS final
COPY --from=builder /site/public /usr/share/caddy
EXPOSE 8080
CMD ["caddy", "file-server", "--root", "/usr/share/caddy", "--listen", ":8080"]
