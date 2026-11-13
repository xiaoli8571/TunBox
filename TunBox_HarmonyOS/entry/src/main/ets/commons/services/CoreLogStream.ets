/**
 * 内核实时日志流（GET /logs WebSocket）
 *
 * 背景：内核 stdout/stderr 已 dup3 重定向到 core.log 文件，但那是"事后排障"；
 * 主流客户端（Clash Verge / FlClash / Mihomo Party）都通过 controller 的
 * /logs WebSocket 实时流式查看内核日志。本服务补齐同一能力：
 *  - 连接 ws://127.0.0.1:{port}/logs?level={min}（mihomo 按级别过滤下发）
 *  - 认证走 Authorization: Bearer（与 REST 同一 secret）
 *  - 环形缓冲最近 500 条，UI 侧再做客户端级别过滤与搜索
 *
 * 生命周期：UI 打开面板时 connect，关闭时 close；内核不可达时 onError 收敛，
 * 不自动重连风暴（重连由用户重新打开面板触发）。
 */
import { webSocket } from '@kit.NetworkKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'CoreLogStream';
const RING_CAPACITY = 500;

/** 单条内核日志（mihomo hub: {"type":"warning","payload":"..."}） */
export class CoreLogLine {
  /** 内核侧级别：debug/info/warning/error */
  level: string = '';
  /** 日志正文（内核已脱敏日志，payload 原样） */
  text: string = '';
  /** 本机接收时间戳（排序/去重键用） */
  receivedAt: number = 0;
}

export type CoreLogListener = (lines: CoreLogLine[]) => void;

export class CoreLogStream {
  private static shared: CoreLogStream | null = null;

  static instance(): CoreLogStream {
    if (CoreLogStream.shared === null) {
      CoreLogStream.shared = new CoreLogStream();
    }
    return CoreLogStream.shared;
  }

  private ws: webSocket.WebSocket | null = null;
  private ring: CoreLogLine[] = [];
  private listeners: CoreLogListener[] = [];
  private state: 'idle' | 'connecting' | 'open' | 'closed' = 'idle';
  /** 当前连接的 level 查询参数（reconnect 复用） */
  private level: string = 'info';

  /** 连接状态快照（UI 显示连接中/已连接/未连接） */
  phase(): string {
    return this.state;
  }

  /** 最近日志副本（新到旧），UI 直接渲染 */
  snapshot(): CoreLogLine[] {
    return this.ring.slice().reverse();
  }

  /** 清空缓冲（切换内核会话/重新连接时） */
  clear(): void {
    this.ring = [];
    this.emit();
  }

  addListener(listener: CoreLogListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: CoreLogListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private emit(): void {
    // 拷贝一份当前缓冲，避免监听方直接持有内部数组
    const snap = this.snapshot();
    for (const l of this.listeners) {
      l(snap);
    }
  }

  /**
   * 连接 /logs 流。已在旧连接上重复调用时先断开再连（切换级别/端口重连语义）。
   * secret 为空时仍允许连接（内核 external-controller 未设 secret 的场景）。
   */
  connect(port: number, secret: string, level: string): void {
    this.close();
    const normalizedLevel = level === 'debug' || level === 'warning' || level === 'error'
      ? level : 'info';
    this.level = normalizedLevel;
    this.state = 'connecting';
    this.emit();
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    ws.on('open', (): void => {
      if (this.ws === ws) {
        this.state = 'open';
        this.emit();
        AppLogger.info(TAG, `log stream open (level=${this.level})`);
      }
    });
    ws.on('message', (err: Error | undefined, value: string | ArrayBuffer): void => {
      if (this.ws !== ws || err !== undefined) {
        return;
      }
      if (typeof value !== 'string' || value.length === 0) {
        return;
      }
      this.append(value);
    });
    ws.on('close', (): void => {
      if (this.ws === ws) {
        this.state = 'closed';
        this.emit();
      }
    });
    ws.on('error', (err: Error | undefined): void => {
      if (this.ws === ws) {
        this.state = 'closed';
        this.emit();
        AppLogger.warn(TAG, `log stream error: ${err !== undefined ? err.message : 'unknown'}`);
      }
    });
    const url = `ws://127.0.0.1:${port}/logs?level=${this.level}`;
    const headers: Record<string, string> = {};
    if (secret.length > 0) {
      headers['Authorization'] = `Bearer ${secret}`;
    }
    // SDK 的 Promise 重载只支持 (url, header)；本机 loopback 连接无需自定义超时。
    ws.connect(url, headers as Object).catch((e: Object): void => {
      if (this.ws === ws) {
        this.state = 'closed';
        this.emit();
        AppLogger.warn(TAG, `log stream connect failed: ${String(e)}`);
      }
    });
  }

  /** 解析并缓存一条内核日志 JSON；格式异常静默忽略（绝不中断流） */
  private append(raw: string): void {
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      const line = new CoreLogLine();
      const typeRaw = obj['type'];
      const payloadRaw = obj['payload'];
      line.level = typeof typeRaw === 'string' ? typeRaw : 'info';
      line.text = typeof payloadRaw === 'string' ? payloadRaw : '';
      if (line.text.length === 0) {
        return;
      }
      line.receivedAt = Date.now();
      this.ring.push(line);
      if (this.ring.length > RING_CAPACITY) {
        this.ring.splice(0, this.ring.length - RING_CAPACITY);
      }
      this.emit();
    } catch (e) {
      // 非 JSON 帧（极少）：忽略
    }
  }

  /** 断开连接并释放回调（不清理缓冲，便于关闭面板后重开仍在） */
  close(): void {
    const ws = this.ws;
    this.ws = null;
    this.state = 'idle';
    if (ws !== null) {
      try {
        ws.off('open');
        ws.off('message');
        ws.off('close');
        ws.off('error');
        ws.close();
      } catch (e) {
        // 已断开的 socket close 抛错属正常
      }
    }
  }
}
