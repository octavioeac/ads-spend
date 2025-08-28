# docker/Dockerfile
FROM node:18-alpine

ARG N8N_VERSION=1.108.2
ENV N8N_VERSION=${N8N_VERSION}

# Runtime + build deps needed to install n8n
RUN apk add --no-cache \
      graphicsmagick \
      tzdata \
      python3 \
      make \
      g++ \
      git

# Install n8n globally
RUN npm_config_user=root npm install -g n8n@${N8N_VERSION}

WORKDIR /data
EXPOSE 5678
CMD ["n8n"]
