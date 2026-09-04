//! Reference scaffold for screen / audio recording of Harness sessions.
//!
//! Community Tauri shells integrate:
//!   - `scap`  — high-performance screen capture
//!   - `cpal`  — cross-platform audio capture
//!   - `ffmpeg`— muxing / encoding the captured streams
//!
//! This module is intentionally a no-op stub so the project compiles without
//! those heavy native dependencies. Replace `start` / `stop` with real capture
//! logic when you need session recording. Exposed to the frontend via the
//! `toggle_record` command in `lib.rs`.

#[allow(dead_code)]
pub struct Recorder {
    active: bool,
}

#[allow(dead_code)]
impl Recorder {
    pub fn new() -> Self {
        Self { active: false }
    }

    /// Begin a recording session (stub).
    pub fn start(&mut self, _output_path: &str) {
        // TODO: init scap + cpal, spawn ffmpeg process writing to `_output_path`.
        self.active = true;
    }

    /// Stop and finalize the recording (stub).
    pub fn stop(&mut self) {
        // TODO: tear down capture devices, signal ffmpeg to finish.
        self.active = false;
    }

    pub fn is_active(&self) -> bool {
        self.active
    }
}
