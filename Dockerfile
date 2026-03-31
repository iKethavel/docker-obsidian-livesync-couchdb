FROM docker.io/couchdb:3.5.0

# Add metadata labels for Docker Hub integration
LABEL org.opencontainers.image.title="CouchDB for Obsidian LiveSync"
LABEL org.opencontainers.image.description="A Docker container that configures CouchDB specifically for use with Obsidian LiveSync, automating the setup process by parsing the bash script provided by obsidian-livesync's maintainer"
LABEL org.opencontainers.image.url="https://hub.docker.com/r/rostyslavmelnychuk/docker-obsidian-livesync-couchdb"
LABEL org.opencontainers.image.source="https://github.com/iKethavel/docker-obsidian-livesync-couchdb"
LABEL org.opencontainers.image.documentation="https://github.com/iKethavel/docker-obsidian-livesync-couchdb#readme"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="iKethavel"
LABEL org.opencontainers.image.vendor="iKethavel"

# Install basic dependencies
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    unzip \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x (required by Vite)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs

# Install Deno
RUN curl -fsSL https://deno.land/install.sh | sh

# Add Deno to the PATH
ENV PATH="/root/.deno/bin:$PATH"

# Verify Deno installation
RUN deno --version

# Set a working directory
WORKDIR /scripts

# Copy the TypeScript script into the container
COPY couchdb-setup.ts .

# Download the couchdb-init.sh script
RUN curl -fsSL https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/main/utils/couchdb/couchdb-init.sh -o couchdb-init.sh
RUN curl -fsSL https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/main/utils/flyio/generate_setupuri.ts -o generate_setupuri.ts

# Update the couchDB config from the couchdb-init script provided by the plugin maintainer
RUN deno -A /scripts/couchdb-setup.ts

# Install the LiveSync Headless CLI
WORKDIR /opt/obsidian-livesync
RUN git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/vrtmrz/obsidian-livesync.git . && \
    sed -i 's|prefix: this.context.vaultPath + nodePath.sep,|prefix: nodePath.join(this.context.vaultPath, ".livesync", "db") + nodePath.sep,|' src/apps/cli/services/NodeServiceHub.ts && \
    npm install && \
    cd src/apps/cli && \
    npm run build

# Copy the custom entrypoint wrapper
COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh

ENV SERVER_DOMAIN=localhost
ENV COUCHDB_USER=default
ENV COUCHDB_DATABASE=default

ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
