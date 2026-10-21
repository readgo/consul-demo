import type { FastifySchema } from 'fastify';

/**
 * 每个接口一个 schema 常量（querystring / params / body / response 放一起），
 * 路由文件只引用不内联 —— 接口多了才好翻，以后接 Swagger 也直接复用。
 *
 * 注意：Fastify v5 的 FastifySchema 子字段是 unknown，satisfies 要加在「整个 schema 对象」上，
 * 不能加在 querystring 这种单个字段上。
 */

export type TestQuery = {
  /** 要问候的名字，必填，不允许空串 */
  name: string;
};

export const getTestSchema = {
  querystring: {
    type: 'object',
    required: ['name'],
    additionalProperties: false,
    properties: {
      name: { type: 'string', minLength: 1, maxLength: 64, description: '要问候的名字' },
    },
  },
  // 纯文本响应：text/plain
  response: {
    200: { type: 'string' },
  },
} satisfies FastifySchema;
