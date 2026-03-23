FROM node:22-alpine

WORKDIR /app
COPY app/package.json app/package-lock.json ./
RUN npm ci

COPY app/ .

EXPOSE 3333
CMD ["node", "serve.js"]
