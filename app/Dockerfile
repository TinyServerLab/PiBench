# PiBench dashboard — multi-arch (runs on Raspberry Pi 5 / arm64)
FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY server.js ./
COPY public ./public
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD wget -qO- "http://127.0.0.1:3000${BASE_PATH:-/pibench}/healthz" >/dev/null || exit 1
CMD ["node", "server.js"]
