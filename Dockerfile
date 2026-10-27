FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY shared ./shared
COPY services ./services
COPY scripts ./scripts
COPY db ./db
USER node
# Which service runs is chosen per container in docker-compose.yml
CMD ["node", "services/gateway/index.js"]
