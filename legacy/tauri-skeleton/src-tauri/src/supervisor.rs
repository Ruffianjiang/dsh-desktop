use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Name / path of the DeepSeek Harness binary.
///
/// Override with the `DSH_BIN` env var, e.g. to point at a locally built
/// submodule binary: `DSH_BIN=./dsh/dist/dsh`.
fn dsh_bin() -> String {
    std::env::var("DSH_BIN").unwrap_or_else(|_| "dsh".to_string())
}

/// Owns the spawned `dsh web` child process and its bound port.
pub struct Supervisor {
    child: Option<Child>,
    pub port: u16,
}

impl Supervisor {
    /// Spawn `dsh web` on `port`. Falls back to `--port` only when the port
    /// differs from the DSH default (3080), so the common path uses the
    /// well-known `dsh web` invocation.
    pub fn start(port: u16) -> std::io::Result<Self> {
        let mut args = vec!["web".to_string()];
        if port != 3080 {
            args.push("--port".to_string());
            args.push(port.to_string());
        }

        let child = Command::new(dsh_bin())
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        Ok(Self {
            child: Some(child),
            port,
        })
    }

    /// True if the dev server is accepting TCP connections on 127.0.0.1:`port`.
    pub fn is_ready(&self) -> bool {
        let addr = format!("127.0.0.1:{}", self.port);
        TcpStream::connect_timeout(&addr.parse().unwrap(), Duration::from_millis(400)).is_ok()
    }

    /// Block until the server is ready or the timeout elapses.
    pub fn wait_for_ready(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if self.is_ready() {
                return true;
            }
            thread::sleep(Duration::from_millis(300));
        }
        false
    }

    /// Kill the child process. Safe to call multiple times.
    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        self.stop();
    }
}
