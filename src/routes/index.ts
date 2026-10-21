import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FastifyInstance } from 'fastify';
import { autoloadRouteModules } from '../lib/autoload.js';
import { config } from '../config.js';

const here = path.dirname(fileURLToPath(import.meta.url));

/**
 * 路由总入口：只做两件事 —— 自动加载 v1 领域模块、挂运维探针。
 * 业务接口不要写在这里，写到 routes/v1/<domain>/ 下。
 */
export default async function routes(app: FastifyInstance): Promise<void> {
  const modules = await autoloadRouteModules(app, path.join(here, 'v1'), '/v1');

  // 机制探针：下一步 Consul 的 HTTP Check 打这个。
  // modules 一并吐出来 —— 容器 healthy 但 modules 为 0 就是路由没挂上，别被假健康骗了
  // pid 用来让发布脚本确认「起来的是新进程」，而不是旧进程还占着端口
  app.get('/healthz', async () => ({
    status: 'ok',
    service: config.serviceName,
    modules,
    pid: process.pid,
    uptime: Math.round(process.uptime()),
  }));
}
