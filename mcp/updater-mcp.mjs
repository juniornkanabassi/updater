#!/usr/bin/env node
// Stdio MCP adapter over the `updater` CLI, after Talk & Read's talkread-mcp.mjs: one tool per CLI
// command, no dependencies (Node 18+). The tool list comes from `updater mcp-manifest`, so the CLI
// stays the single source of truth and every call goes through the app's own scheduler.
// Claude Code: claude mcp add updater -- node "/Applications/JuniorOS Apps/Updater.app/Contents/Resources/mcp/updater-mcp.mjs"
// Codex: [mcp_servers.updater] command = "node", args = ["<same path>"]
// Env: UPDATER_CLI overrides the helper path (tests); UPDATER_HOME is passed through to the CLI.
import { createInterface } from 'node:readline';
import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, readFileSync } from 'node:fs';

const execFile = promisify(execFileCallback);
const here = dirname(fileURLToPath(import.meta.url));            // Contents/Resources/mcp
const bundledCLI = join(here, '..', '..', 'Helpers', 'updater');  // Contents/Helpers/updater
const cli = process.env.UPDATER_CLI || (existsSync(bundledCLI) ? bundledCLI : 'updater');
// One caller id for this adapter's life, so the app can tell two agents apart in job status and replay.
const caller = `mcp-${process.pid}-${randomUUID()}`;

function appVersion() {
  try {
    const plist = readFileSync(join(here, '..', '..', 'Info.plist'), 'utf8');
    return /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(plist)?.[1] ?? '0.0.0';
  } catch { return '0.0.0'; }
}

let tools;
try {
  const { stdout } = await execFile(cli, ['mcp-manifest'], { maxBuffer: 16 * 1024 * 1024 });
  tools = JSON.parse(stdout);
  if (!Array.isArray(tools)) throw new Error('mcp-manifest must return a JSON array');
} catch (error) {
  process.stderr.write(`updater-mcp: cannot load the tool list from ${cli}: ${error.message}\n`);
  process.exit(1);
}
const version = appVersion();

function reply(id, result, error) {
  process.stdout.write(`${JSON.stringify(error ? { jsonrpc: '2.0', id, error } : { jsonrpc: '2.0', id, result })}\n`);
}

async function callTool(id, params) {
  if (!params || typeof params !== 'object' || Array.isArray(params) ||
      (params.arguments != null && (typeof params.arguments !== 'object' || Array.isArray(params.arguments)))) {
    return reply(id, null, { code: -32602, message: 'Invalid tool arguments' });
  }
  const tool = tools.find(item => item.name === params.name);
  if (!tool) return reply(id, null, { code: -32602, message: `Unknown tool: ${params.name}` });
  const known = tool.inputSchema?.properties ?? {};
  const args = [tool.name];
  for (const [key, value] of Object.entries(params.arguments ?? {})) {
    if (!(key in known)) return reply(id, null, { code: -32602, message: `Unknown argument '${key}' for ${tool.name}` });
    if (value === null || value === undefined) continue;
    args.push(`--${key}=${String(value)}`);   // always the = form, so a value starting with -- stays data
  }
  // The JSON-RPC id is the request id: a retried call reusing it acts once (the app replays the reply).
  args.push('--json', '--caller', caller, '--request-id', String(id));
  try {
    const { stdout, stderr } = await execFile(cli, args, { maxBuffer: 16 * 1024 * 1024 });
    reply(id, { content: [{ type: 'text', text: stdout.trim() || stderr.trim() }], isError: false });
  } catch (error) {
    reply(id, { content: [{ type: 'text', text: error.stdout?.trim() || error.stderr?.trim() || error.message }], isError: true });
  }
}

async function handle(message) {
  let request;
  try { request = JSON.parse(message); } catch {
    return reply(null, null, { code: -32700, message: 'Parse error' });
  }
  if (!request || request.jsonrpc !== '2.0' || typeof request.method !== 'string') {
    if (request?.id !== undefined) reply(request.id, null, { code: -32600, message: 'Invalid Request' });
    return;
  }
  if (request.id === undefined) return;   // notification
  const { id, method, params } = request;
  if (method === 'initialize') {
    reply(id, { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'updater', version } });
  } else if (method === 'ping') {
    reply(id, {});
  } else if (method === 'tools/list') {
    reply(id, { tools });
  } else if (method === 'tools/call') {
    await callTool(id, params);
  } else {
    reply(id, null, { code: -32601, message: `Method not found: ${method}` });
  }
}

createInterface({ input: process.stdin, crlfDelay: Infinity }).on('line', line => { void handle(line); });
