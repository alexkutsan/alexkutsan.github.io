# Use a minimal Debian base image
FROM debian:bookworm-slim AS builder

# Install dependencies: curl for downloading Zola, and unzip
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates tar \
    && rm -rf /var/lib/apt/lists/*

# Set Zola version
ENV ZOLA_VERSION=0.18.0

# Download and install Zola
RUN curl -L -o /tmp/zola.tar.gz "https://github.com/getzola/zola/releases/download/v${ZOLA_VERSION}/zola-v${ZOLA_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    && tar -xzf /tmp/zola.tar.gz -C /usr/local/bin \
    && rm /tmp/zola.tar.gz

# Copy the site source
WORKDIR /site
COPY . .

# Build the site
RUN zola build --base-url /

# --- Final image ---
FROM debian:bookworm-slim AS final

# Install a minimal HTTP server
RUN apt-get update \
    && apt-get install -y --no-install-recommends wget ca-certificates tar \
    && wget -O /tmp/caddy.tar.gz 'https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_amd64.tar.gz' \
    && tar -xzf /tmp/caddy.tar.gz -C /tmp \
    && mv /tmp/caddy /usr/bin/caddy \
    && chmod +x /usr/bin/caddy \
    && rm -rf /tmp/caddy.tar.gz /tmp/LICENSE /tmp/README.md /var/lib/apt/lists/*

# Copy built site from builder
COPY --from=builder /site/public /site/public

# Create a Caddyfile for redirects and static file serving
RUN echo ':8080 {\n\
    root * /site/public\n\
    handle /posts* {\n\
        redir /posts /en/posts 301\n\
        redir /posts/* /en/posts/{path} 301\n\
    }\n\
    file_server\n\
}' > /site/Caddyfile

WORKDIR /site/public

# Use a simple server (Python 3 is not installed by default, so use netcat for ultra-minimal, or you can swap to nginx/caddy if desired)
# For real-world use, swap to nginx or Caddy for production.
CMD ["caddy", "run", "--config", "/site/Caddyfile", "--adapter", "caddyfile"]

EXPOSE 8080

# Healthcheck: ensure the server is serving content
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --spider -q http://localhost:8080 || exit 1
