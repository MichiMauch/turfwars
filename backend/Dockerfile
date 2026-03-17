FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
EXPOSE 3005
CMD ["npx", "tsx", "src/index.ts"]
