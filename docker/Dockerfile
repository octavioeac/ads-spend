FROM n8nio/n8n:latest-debian

ENV TZ=America/Mexico_City \
    N8N_DIAGNOSTICS_ENABLED=false

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl vim-tiny \
 && rm -rf /var/lib/apt/lists/*
USER node
