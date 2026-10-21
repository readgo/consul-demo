import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import type { FastifyInstance } from 'fastify';

export type RouteModule = (app: FastifyInstance) => Promise<unknown> | unknown;

/** 源码跑 .ts（tsx），编译后跑 .js（dist），两种都要认 */
const EXTENSIONS = ['.js', '.ts'];

/** 只有 routes.ts 和 *.routes.ts 会被当成路由模块，schema / service 等不会被误加载 */
const ROUTE_FILE = /^(routes|.+\.routes)\.(js|ts)$/;

function isRouteFile(name: string): boolean {
  return ROUTE_FILE.test(name);
}

/** 领域目录：跳过 _ 开头（内部工具/草稿）和 . 开头 */
function listDomainDirs(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith('_') && !e.name.startsWith('.'))
    .map((e) => e.name)
    .sort();
}

function listRouteFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && isRouteFile(e.name))
    .map((e) => e.name)
    .sort();
}

/** 按无扩展名的路径找实际存在的文件（dist 下只有 .js，src 下只有 .ts） */
function resolveExisting(dir: string, fileName: string): string | null {
  const base = fileName.replace(/\.(js|ts)$/, '');
  for (const ext of EXTENSIONS) {
    const candidate = path.join(dir, `${base}${ext}`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

async function loadRouteModule(domainDir: string, fileName: string): Promise<RouteModule | null> {
  const filePath = resolveExisting(domainDir, fileName);
  if (!filePath) return null;
  const mod = (await import(pathToFileURL(filePath).href)) as { default?: RouteModule };
  return typeof mod.default === 'function' ? mod.default : null;
}

/**
 * 按「目录即 URL 前缀」自动挂载路由模块。
 *
 *   routes/v1/<domain>/*.routes.ts  ->  <urlPrefix>/<domain>
 *
 * 约定：
 *   - 一个领域目录 = 一个 URL 段；目录下可以有多个 *.routes.ts，负责不同资源
 *   - 模块内不要写领域前缀（会重复），领域根写 '/'，子资源写 '/detail'、'/:id'
 *     例：routes/v1/user/profile.routes.ts 里写 '/profile' -> /v1/user/profile
 *   - 路径写重复了启动即报 FST_ERR_DUPLICATED_ROUTE，不会静默覆盖
 */
export async function autoloadRouteModules(
  app: FastifyInstance,
  rootDir: string,
  urlPrefix: string,
): Promise<number> {
  // 目录不存在通常是构建/打包漏了 dist，直接挂掉比「服务起来了但全 404」好排查得多
  if (!existsSync(rootDir)) {
    throw new Error(`[autoload] 路由根目录不存在：${rootDir}（dist 是否漏打包？）`);
  }

  let modules = 0;

  for (const domain of listDomainDirs(rootDir)) {
    const domainDir = path.join(rootDir, domain);
    const files = listRouteFiles(domainDir);

    if (files.length === 0) {
      app.log.warn(`[autoload] ${domainDir} 下没有 routes.ts / *.routes.ts，已跳过`);
      continue;
    }

    for (const fileName of files) {
      const handler = await loadRouteModule(domainDir, fileName);
      const prefix = `${urlPrefix}/${domain}`;

      if (!handler) {
        app.log.warn(`[autoload] ${path.join(domainDir, fileName)} 没有 default export 的函数，已跳过`);
        continue;
      }

      await app.register(handler, { prefix });
      app.log.debug(`[autoload] ${prefix}  <-  ${path.relative(rootDir, path.join(domainDir, fileName))}`);
      modules += 1;
    }
  }

  app.log.info(`[autoload] ${modules} 个路由模块挂载在 ${urlPrefix} 下`);

  // 0 个模块 = 容器 healthy 但业务全 404 的经典假健康，启动阶段就掐掉
  if (modules === 0) {
    throw new Error(`[autoload] ${rootDir} 下没有加载到任何路由模块，拒绝以空路由启动`);
  }

  return modules;
}
