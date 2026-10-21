import Fastify, { type FastifyInstance } from 'fastify';
import { config } from './config.js';
import routes from './routes/index.js';
import { registerErrorHandler } from './plugins/error-handler.js';

export type BuildOptions = {
  logger?: boolean | object;
};

/**
 * 组装应用（不监听端口）：便于 inject 做单测，也便于以后在别处复用。
 */
export function buildServer(opts: BuildOptions = {}): FastifyInstance {
  const app = Fastify({
    logger: opts.logger ?? { level: config.logLevel },
    // /v1/test 与 /v1/test/ 都认，避免目录式挂载带来的尾斜杠坑
    ignoreTrailingSlash: true,
    keepAliveTimeout: 5_000,
  });

  registerErrorHandler(app);
  app.register(routes);

  return app;
}
