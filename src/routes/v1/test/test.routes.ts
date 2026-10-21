import type { FastifyInstance } from 'fastify';
import { getTestSchema, type TestQuery } from './test.schema.js';

/**
 * 领域：test
 * 挂载前缀由目录推导 —— routes/v1/test/ -> /v1/test
 * 所以这里 '/' 就是 /v1/test，'/xxx' 就是 /v1/test/xxx
 */
export default async function testRoutes(app: FastifyInstance): Promise<void> {
  app.get<{ Querystring: TestQuery }>('/', { schema: getTestSchema }, async (request) =>
    `hello:${request.query.name}`,
  );
}
