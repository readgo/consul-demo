/**
 * Consul 接入层：注册 / 注销，只有两个函数。
 *
 * 设计要点（缺一条就不可用）：
 *   1. 注册失败只告警，不退出 —— Consul 挂了业务必须照常跑
 *   2. ID 带端口 —— 同机多实例靠它区分，否则互相覆盖
 *   3. Address 用 advertiseHost —— 不能是 0.0.0.0，别人拿不到
 *   4. 注销在 SIGTERM 里主动做 —— 不等健康检查，毫秒级摘流量
 */
import { config, consulEnabled } from '../config.js';

const TIMEOUT_MS = 2000;

async function call(path: string, init?: RequestInit): Promise<void> {
  const res = await fetch(`${config.consulAddr}${path}`, {
    ...init,
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`consul ${path} -> HTTP ${res.status} ${await res.text()}`);
  }
}

/** 把自己注册进 Consul；未配置地址时直接返回 */
export async function register(): Promise<void> {
  if (!consulEnabled) return;

  await call('/v1/agent/service/register', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      ID: config.instanceId,
      Name: config.serviceName,
      Address: config.advertiseHost,
      Port: config.port,
      Tags: ['web', 'fastify'],
      Check: {
        CheckID: `http-${config.port}`,
        Name: 'GET /healthz',
        HTTP: `http://${config.advertiseHost}:${config.port}/healthz`,
        Interval: '2s',
        Timeout: '1s',
        // 实例彻底消失超过 1 分钟就从目录里删掉，避免僵尸条目
        DeregisterCriticalServiceAfter: '1m',
      },
    }),
  });
}

/** 从 Consul 摘除自己 */
export async function deregister(): Promise<void> {
  if (!consulEnabled) return;
  await call(`/v1/agent/service/deregister/${encodeURIComponent(config.instanceId)}`, {
    method: 'PUT',
  });
}
