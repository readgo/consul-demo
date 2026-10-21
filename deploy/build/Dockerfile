# 应用镜像的构建文件。
# 调用方：同目录的 build-image.sh（它会先 cd 到项目根，再把本文件传给 docker build）
# 注意：构建上下文是项目根（需要 src / package.json / tsconfig.json），
#       所以 build-image.sh 里用的是 -f deploy/build/Dockerfile + 上下文 "."
# ---------- 构建阶段：装全量依赖并编译 TS ----------
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---------- 运行阶段：只留产物 + 生产依赖 ----------
FROM node:22-alpine AS runner
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3020
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=builder /app/dist ./dist

# 不用 root 跑；node 用户只需读权限
USER node
EXPOSE 3020

# 用 node 内置 fetch 探活，镜像里不用装 curl
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3020)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/index.js"]
