import type { FastifySchema } from 'fastify';

export type Test2Query = {
  /** 要回显的名字，必填，不允许空串 */
  name: string;
};

export const getTest2Schema = {
  querystring: {
    type: 'object',
    required: ['name'],
    additionalProperties: false,
    properties: {
      name: { type: 'string', minLength: 1, maxLength: 64, description: '要回显的名字' },
    },
  },
  // 纯文本响应：text/plain
  response: {
    200: { type: 'string' },
  },
} satisfies FastifySchema;
