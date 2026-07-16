# ---- Multi-stage build ----
# Stage 1 installs everything (including dev deps) so we can run tests.
# Stage 2 ships only production deps. Smaller image = smaller attack surface
# and faster pod starts, which matters on a 2-node cluster.

FROM node:20-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM node:20-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Prune to production dependencies only
RUN npm ci --omit=dev

FROM node:20-alpine AS runtime

# Security: never run as root. Node images ship a 'node' user (uid 1000).
# dumb-init gives us correct PID 1 signal handling so SIGTERM actually
# reaches the app and graceful shutdown works.
RUN apk add --no-cache dumb-init && \
    mkdir -p /app && chown -R node:node /app

WORKDIR /app
ENV NODE_ENV=production

COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node src ./src
COPY --chown=node:node package.json ./

USER node
EXPOSE 8080

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/server.js"]
