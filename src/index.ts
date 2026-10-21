import { buildServer } from './app.js';
import { config, consulEnabled } from './config.js';
import { deregister, register } from './lib/consul.js';

const app = buildServer();

let shuttingDown = false;

/**
 * 优雅下线：先摘流量，再关服务。顺序不能反。
 *   1. 从 Consul 注销 —— 网关不再把新请求排给本实例
 *   2. 等 drainMs  —— 网关刷新 upstream 需要时间（默认 2.5s）
 *   3. 关服务      —— 此时已没有新请求进来
 */
async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info(`${signal} received, 开始下线`);

  try {
    await deregister();
    if (consulEnabled) {
      app.log.info(`已从 Consul 摘除，等待 ${config.drainMs}ms 让网关刷新`);
      await new Promise((resolve) => setTimeout(resolve, config.drainMs));
    }
  } catch (err) {
    app.log.warn({ err }, '注销失败，仍继续关闭');
  }

  try {
    await app.close();
    process.exit(0);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => void shutdown(signal));
}

try {
  await app.listen({ port: config.port, host: config.host });
} catch (err) {
  app.log.error(err);
  process.exit(1);
}

// listen 之后再注册：注册完健康检查立刻就会打过来，此时必须已经能响应
try {
  await register();
  if (consulEnabled) {
    app.log.info(
      { id: config.instanceId, consul: config.consulAddr, advertise: config.advertiseHost },
      '已注册到 Consul',
    );
  }
} catch (err) {
  // 注册失败不退出：Consul 挂着的时候业务必须照常对外服务
  app.log.warn({ err }, '注册到 Consul 失败，服务继续运行');
}
