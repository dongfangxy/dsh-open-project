/**
 * dsh-open-project, 宿主半边：把"资源管理器右键某个文件夹"变成 DSH 侧边栏里的一个项目。
 *
 * 浏览器端不参与这件事：右键菜单由 Windows 注册表发起，调用同目录下的 CLI，
 * CLI 再回调本插件注册的一条精确路由 `POST /.dsh-open-project`。
 *
 * 为什么必须有这条路由：工作区登记（ctx.workspaceRegistry）只存在于宿主进程内，
 * 外部脚本无法直接调用，插件是唯一能在宿主里执行这件事的载体。
 *
 * 安全边界：路由只绑回环地址（`host: 127.0.0.1`），并要求一个自定义请求头、
 * 拒绝跨源 Origin。其他网页要么发不出带自定义头的请求（会触发预检），
 * 要么被 Origin 检查挡下，因此无法借你的浏览器往 DSH 里塞目录。
 *
 * @module dsh-open-project
 */

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Cordis 插件名。 */
export const name = "dsh-open-project";

/** 依赖服务：路由注册表 + 工作区登记表。缺一个本插件就保持 pending，不会半挂载。 */
export const inject = ["webServer", "workspaceRegistry"];

/** 本插件占用的精确路由。 */
const ENDPOINT = "/.dsh-open-project";

/** 设置页读取/切换右键菜单项用的路由。 */
const MENU_ENDPOINT = "/.dsh-open-project/menu";

/** CLI 必须携带的请求头：跨源简单请求带不上它，预检又被 Origin 检查拒绝。 */
const TOKEN_HEADER = "x-dsh-open-project";

/** 单次请求体上限，异常大的 body 直接拒绝。 */
const MAX_BODY_BYTES = 64 * 1024;

/** 注册表开关脚本（单一实现来源，右键菜单的增删都走它）。 */
const MENU_SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "..", "cli", "context-menu.ps1");

/**
 * 应答一段 JSON。
 * @param res - HTTP 响应。
 * @param status - HTTP 状态码。
 * @param payload - 要序列化的对象。
 */
function json(res, status, payload) {
	res.writeHead(status, {
		"content-type": "application/json; charset=utf-8",
		"cache-control": "no-store"
	});
	res.end(JSON.stringify(payload));
}

/**
 * 读取请求体并解析成 JSON 对象。
 * @param req - HTTP 请求。
 * @returns 解析后的对象；空体返回空对象。
 * @throws 体过大（413）或不是合法 JSON（400）时抛出带 `status` 的错误。
 */
async function readJsonBody(req) {
	const chunks = [];
	let size = 0;
	for await (const chunk of req) {
		size += chunk.length;
		if (size > MAX_BODY_BYTES) throw Object.assign(new Error("request body too large"), { status: 413 });
		chunks.push(chunk);
	}
	if (size === 0) return {};
	const text = Buffer.concat(chunks).toString("utf8").trim();
	if (text === "") return {};
	let parsed;
	try {
		parsed = JSON.parse(text);
	} catch {
		throw Object.assign(new Error("request body is not valid JSON"), { status: 400 });
	}
	return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? parsed : {};
}

/**
 * 处理一次登记请求。
 *
 * `registry.create` 本身幂等：目录已有项目时返回原记录且不改标题，
 * 路径不存在或不是目录时抛错，所以这里不做重复的前置校验。
 *
 * @param ctx - 宿主插件上下文。
 * @param req - HTTP 请求。
 * @param res - HTTP 响应。
 */
async function handle(ctx, req, res) {
	if (req.method !== "POST") {
		res.writeHead(405, { allow: "POST" });
		res.end();
		return;
	}
	if (req.headers[TOKEN_HEADER] === undefined) {
		json(res, 403, { ok: false, error: `missing ${TOKEN_HEADER} header` });
		return;
	}
	const origin = req.headers.origin;
	if (typeof origin === "string" && origin !== "" && !/^https?:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?$/u.test(origin)) {
		json(res, 403, { ok: false, error: "cross-origin request refused" });
		return;
	}
	try {
		const body = await readJsonBody(req);
		const directory = typeof body.path === "string" ? body.path.trim() : "";
		if (directory === "") {
			json(res, 400, { ok: false, error: "path is required" });
			return;
		}
		const before = ctx.workspaceRegistry.list().some((item) => item.path.toLowerCase() === directory.toLowerCase());
		const project = await ctx.workspaceRegistry.create(directory);
		ctx.logger?.info(`dsh-open-project: ${before ? "already present" : "registered"} ${project.path}`);
		json(res, 200, {
			ok: true,
			created: !before,
			id: project.id,
			path: project.path,
			title: project.title
		});
	} catch (error) {
		const status = Number.isInteger(error?.status) ? error.status : 400;
		ctx.logger?.warn(`dsh-open-project: ${String(error?.message ?? error)}`);
		json(res, status, { ok: false, error: String(error?.message ?? error) });
	}
}

/**
 * 调用 context-menu.ps1，读取或切换右键菜单项。
 *
 * 强制 pwsh 以 UTF-8 输出，并且 status 一律带 `-Json`：跨进程读中文时默认编码会
 * 让文本错位，宿主因此只解析字段、不解析中文。
 *
 * @param action - `status` | `enable` | `disable`。
 * @returns 脚本的标准输出文本。
 * @throws 脚本失败时抛出带 stderr 摘要的错误。
 */
function runMenuScript(action) {
	if (!existsSync(MENU_SCRIPT)) throw new Error(`menu script not found: ${MENU_SCRIPT}`);
	const quoted = MENU_SCRIPT.replace(/'/gu, "''");
	const command = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); " +
		`& '${quoted}' -Action ${action}${action === "status" ? " -Json" : ""}`;
	return new Promise((resolve, reject) => {
		execFile("pwsh.exe", ["-NoProfile", "-NonInteractive", "-Command", command],
			{ windowsHide: true, timeout: 30_000, encoding: "utf8" },
			(error, stdout, stderr) => {
				if (error !== null) {
					reject(new Error(`${action} failed: ${String(stderr || error.message).trim()}`));
					return;
				}
				resolve(String(stdout));
			});
	});
}

/**
 * 处理设置页的菜单项请求：GET 读状态，POST 切换。
 * @param ctx - 宿主插件上下文。
 * @param req - HTTP 请求。
 * @param res - HTTP 响应。
 */
async function handleMenu(ctx, req, res) {
	try {
		// 非 Windows 上这套机制（HKCU + wscript）根本不存在，直接如实回答，
		// 不去跑 pwsh 然后抛 500 —— 客户端据此不渲染那一行。
		if (process.platform !== "win32") {
			json(res, 200, { ok: true, enabled: false, supported: false });
			return;
		}
		if (req.method === "GET") {
			const output = await runMenuScript("status");
			let enabled = false;
			try {
				enabled = JSON.parse(output.trim()).enabled === true;
			} catch {
				throw new Error(`unreadable status output: ${output.trim().slice(0, 200)}`);
			}
			json(res, 200, { ok: true, enabled, supported: true });
			return;
		}
		if (req.method === "POST") {
			const body = await readJsonBody(req);
			if (typeof body.enabled !== "boolean") {
				json(res, 400, { ok: false, error: "enabled must be a boolean" });
				return;
			}
			const output = await runMenuScript(body.enabled ? "enable" : "disable");
			ctx.logger?.info(`dsh-open-project: context menu ${body.enabled ? "enabled" : "disabled"}`);
			json(res, 200, { ok: true, enabled: body.enabled, output: output.trim() });
			return;
		}
		res.writeHead(405, { allow: "GET, POST" });
		res.end();
	} catch (error) {
		ctx.logger?.warn(`dsh-open-project menu: ${String(error?.message ?? error)}`);
		json(res, 500, { ok: false, error: String(error?.message ?? error) });
	}
}

/**
 * 挂载登记路由与设置页路由。
 * @param ctx - 携带路由注册表的宿主插件上下文。
 */
export function apply(ctx) {
	ctx.effect(() => ctx.webServer.register({
		kind: "exact",
		path: ENDPOINT,
		handler: (req, res) => {
			void handle(ctx, req, res);
		}
	}), "dsh-open-project: register-project route");
	ctx.effect(() => ctx.webServer.register({
		kind: "exact",
		path: MENU_ENDPOINT,
		handler: (req, res) => {
			void handleMenu(ctx, req, res);
		}
	}), "dsh-open-project: context-menu route");
}
