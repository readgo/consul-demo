import { STATUS_CODES } from 'node:http';
import type { FastifyError, FastifyInstance } from 'fastify';

/**
 * 统一错误响应形状（与 Fastify 默认字段保持一致，避免调用方两套解析）：
 *   { statusCode, code, error, message }
 *
 * 5xx 一律不把内部 message 抛给调用方（避免泄漏 SQL / 堆栈），只记日志。
 */
export function registerErrorHandler(app: FastifyInstance): void {
  app.setNotFoundHandler((request, reply) => {
    reply.status(404).send({
      statusCode: 404,
      code: 'route_not_found',
      error: STATUS_CODES[404],
      message: `Route ${request.method}:${request.url} not found`,
    });
  });

  app.setErrorHandler((error: FastifyError, request, reply) => {
    const statusCode = error.statusCode ?? 500;

    if (statusCode >= 500) {
      request.log.error({ err: error }, 'unhandled error');
      reply.status(statusCode).send({
        statusCode,
        code: 'internal_error',
        error: STATUS_CODES[statusCode] ?? 'Internal Server Error',
        message: 'Internal Server Error',
      });
      return;
    }

    // 4xx：校验错误、404、409 等，原样告诉调用方哪里错了
    reply.status(statusCode).send({
      statusCode,
      code: error.code ?? 'bad_request',
      error: STATUS_CODES[statusCode] ?? 'Bad Request',
      message: error.message,
    });
  });
}
