import type { FastifyInstance } from 'fastify';
import { getTest2Schema, type Test2Query } from './test2.schema.js';

/**
 * 领域：test2
 * routes/v1/test2/ -> /v1/test2，所以这里 '/' 就是 /v1/test2
 */
export default async function test2Routes(app: FastifyInstance): Promise<void> {
  app.get<{ Querystring: Test2Query }>('/', { schema: getTest2Schema }, async (request) =>
    `test2-res:${request.query.name}`,
  );
}
