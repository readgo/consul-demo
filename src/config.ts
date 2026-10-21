/**
 * 集中配置：只在这里读 process.env，其它模块一律 import config。
 * 加配置项时改这一处，避免 process.env 散落在全项目。
 */
const serviceName = process.env.SERVICE_NAME ?? 'consul-demo';
const port = Number(process.env.PORT ?? 3020);

export const config = {
  /** 服务名：Consul 里注册的 Name，也是网关找人的唯一契约 */
  serviceName,
  host: process.env.HOST ?? '0.0.0.0',
  /** 本机 3000/3001 常被其它前端项目占用，默认 3020 */
  port,
  logLevel: process.env.LOG_LEVEL ?? 'info',

  /**
   * Consul 地址。留空 = 不注册（本地开发不装 Consul 也能跑）。
   * 例：http://127.0.0.1:8500
   */
  consulAddr: (process.env.CONSUL_HTTP_ADDR ?? '').replace(/\/+$/, ''),

  /**
   * 注册给别人的地址。nginx / 其它机器要用它访问本实例，不能填 0.0.0.0。
   * 单机部署填 127.0.0.1；跨机部署填本机内网 IP。
   */
  advertiseHost: process.env.ADVERTISE_HOST || '127.0.0.1',

  /**
   * 实例 ID，Consul 的主键。同机多实例必须带端口，否则后注册的会覆盖前一个。
   */
  instanceId: process.env.INSTANCE_ID || `${serviceName}-${port}`,

  /**
   * 收到 SIGTERM 后，先从 Consul 摘除自己，再等这么久才真正关服务。
   * 这段是留给网关刷新 upstream 的，不设就可能丢请求。
   */
  drainMs: Number(process.env.SHUTDOWN_DRAIN_MS ?? 2500),
} as const;

/** Consul 是否启用：没配地址就整体跳过，不报错 */
export const consulEnabled = config.consulAddr.length > 0;
