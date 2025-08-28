# Dockerfile
FROM n8nio/n8n:latest

ENV TZ=America/Mexico_City \
    N8N_DIAGNOSTICS_ENABLED=false

# Opcional: util
USER root
RUN apt-get update && apt-get install -y curl vim && rm -rf /var/lib/apt/lists/*
USER node

# Healthcheck (n8n expone /healthz)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://localhost:5678/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"
