import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

interface DshStatus {
  running: boolean;
  ready: boolean;
  port: number;
  url: string | null;
}

export default function App() {
  const [status, setStatus] = useState<DshStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [recording, setRecording] = useState(false);
  const [autoStarted, setAutoStarted] = useState(false);
  const pollRef = useRef<number | null>(null);

  const refresh = async () => {
    try {
      const s = await invoke<DshStatus>("dsh_status");
      setStatus(s);
    } catch (e) {
      setError(String(e));
    }
  };

  const start = async () => {
    setError(null);
    try {
      const s = await invoke<DshStatus>("start_dsh");
      setStatus(s);
      if (!s.running) {
        setError(
          "dsh 启动失败：请确认 dsh 已安装并在 PATH 中，或已构建 submodule（见 README）。"
        );
      }
    } catch (e) {
      setError(String(e));
    }
  };

  const stop = async () => {
    try {
      await invoke("stop_dsh");
    } catch (e) {
      setError(String(e));
    }
    await refresh();
  };

  const toggleRecord = async () => {
    try {
      const active = await invoke<boolean>("toggle_record", {
        path: `session-${Date.now()}.mp4`,
      });
      setRecording(active);
    } catch (e) {
      setError(String(e));
    }
  };

  useEffect(() => {
    if (!autoStarted) {
      setAutoStarted(true);
      start();
    }
    pollRef.current = window.setInterval(refresh, 1000);
    return () => {
      if (pollRef.current) window.clearInterval(pollRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoStarted]);

  const ready = status?.running && status?.ready;
  const url =
    status?.url ??
    (status?.running ? `http://127.0.0.1:${status?.port}` : null);

  return (
    <div className="app">
      <header className="topbar">
        <span className="title">DeepSeek Harness · Desktop</span>
        <span className={`badge ${ready ? "ok" : "pending"}`}>
          {!status
            ? "初始化…"
            : ready
            ? "已就绪"
            : status.running
            ? "启动中…"
            : "未运行"}
        </span>
        <div className="actions">
          {!status?.running && (
            <button onClick={start}>启动</button>
          )}
          {status?.running && (
            <button className="secondary" onClick={stop}>
              停止
            </button>
          )}
          <button
            className="secondary"
            onClick={toggleRecord}
            disabled={!ready}
          >
            {recording ? "停止录制" : "开始录制"}
          </button>
        </div>
      </header>

      {error && <div className="error">{error}</div>}

      <main className="content">
        {ready && url ? (
          <iframe className="dsh-frame" src={url} title="DeepSeek Harness" />
        ) : (
          <div className="placeholder">
            <p>正在启动 DeepSeek Harness Web UI…</p>
            <p className="hint">
              若长时间无响应，请确认 <code>dsh</code> 命令可用（<code>npm i -g @deepseek-ai/dsh</code>），
              或检查 submodule 是否已构建（<code>git submodule update --init</code> + <code>pnpm build</code>）。
            </p>
          </div>
        )}
      </main>
    </div>
  );
}
