FROM node:18-alpine   # Node LTS, base ligera y moderna

ARG N8N_VERSION=1.66.1  
ENV N8N_VERSION=${N8N_VERSION}

RUN apk add --no-cache graphicsmagick tzdata python3 make g++ git bash

RUN npm_config_user=root npm install -g n8n@${N8N_VERSION}

WORKDIR /data

EXPOSE 5678

CMD ["n8n"]
