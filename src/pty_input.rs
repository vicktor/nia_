// SPDX-License-Identifier: MPL-2.0
//! Per-PTY input stays ordered without blocking the UI on a full kernel buffer.

use anyhow::{anyhow, Context, Result};
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    sync::{Arc, Condvar, Mutex},
    thread::{self, JoinHandle},
    time::Duration,
};

// Includes queued and currently-writing chunks, plus their allocation overhead.
// One maximum-sized paste (1 MiB at the bridge) leaves room for later keystrokes.
const INPUT_CAPACITY: usize = 2 * 1024 * 1024;
const CHUNK_OVERHEAD: usize = 64;

#[derive(Default)]
struct Queue {
    chunks: VecDeque<Vec<u8>>,
    bytes: usize,
    error: Option<String>,
    stopping: bool,
    finished: bool,
}

struct Shared {
    queue: Mutex<Queue>,
    wake: Condvar,
    capacity: usize,
    readiness: Option<Readiness>,
}

struct Readiness {
    #[cfg(unix)]
    fd: OwnedFd,
}

pub struct PtyInput {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}

impl PtyInput {
    pub fn for_pty(
        master: &dyn portable_pty::MasterPty,
        writer: Box<dyn Write + Send>,
    ) -> Result<Self> {
        #[cfg(unix)]
        let readiness = {
            let original = master.as_raw_fd().context("PTY has no Unix descriptor")?;
            // Configure and poll an owned duplicate, never a descriptor that a
            // concurrent close could recycle. All master clones share these
            // flags, so the output reader is adapted below as well.
            let duplicate = unsafe { libc::fcntl(original, libc::F_DUPFD_CLOEXEC, 0) };
            if duplicate < 0 {
                return Err(io::Error::last_os_error().into());
            }
            let fd = unsafe { OwnedFd::from_raw_fd(duplicate) };
            let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
            if flags < 0
                || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                    < 0
            {
                return Err(io::Error::last_os_error().into());
            }
            Some(Readiness { fd })
        };
        #[cfg(not(unix))]
        let readiness = {
            let _ = master;
            None
        };
        Self::with_readiness(writer, INPUT_CAPACITY, readiness)
    }

    #[cfg(test)]
    fn new(writer: Box<dyn Write + Send>) -> Result<Self> {
        Self::with_capacity(writer, INPUT_CAPACITY)
    }

    #[cfg(test)]
    fn with_capacity(writer: Box<dyn Write + Send>, capacity: usize) -> Result<Self> {
        Self::with_readiness(writer, capacity, None)
    }

    fn with_readiness(
        writer: Box<dyn Write + Send>,
        capacity: usize,
        readiness: Option<Readiness>,
    ) -> Result<Self> {
        let shared = Arc::new(Shared {
            queue: Mutex::new(Queue::default()),
            wake: Condvar::new(),
            capacity,
            readiness,
        });
        let worker_shared = Arc::clone(&shared);
        let worker = thread::Builder::new()
            .name("nia-pty-input".into())
            .spawn(move || run_writer(worker_shared, writer))
            .context("start PTY input writer")?;
        Ok(Self {
            shared,
            worker: Some(worker),
        })
    }

    pub fn reader(&self, reader: Box<dyn Read + Send>) -> Box<dyn Read + Send> {
        Box::new(PtyReader {
            reader,
            shared: Arc::clone(&self.shared),
        })
    }

    /// Accept the entire chunk or reject it before copying any bytes. This is
    /// an enqueue acknowledgement, not a claim that the shell has consumed it.
    /// No caller waits for capacity or performs a PTY write/flush here.
    pub fn send(&self, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let mut queue = self.shared.queue.lock().unwrap();
        if let Some(error) = &queue.error {
            return Err(anyhow!("Terminal input unavailable: {error}"));
        }
        if queue.stopping || queue.finished {
            return Err(anyhow!("Terminal input is closed"));
        }
        let cost = bytes.len().saturating_add(CHUNK_OVERHEAD);
        if cost > self.shared.capacity.saturating_sub(queue.bytes) {
            return Err(anyhow!(
                "Terminal input queue is full; the shell is not accepting input"
            ));
        }
        queue.bytes += cost;
        queue.chunks.push_back(bytes.to_vec());
        self.shared.wake.notify_one();
        Ok(())
    }

    pub fn error(&self) -> Option<String> {
        self.shared.queue.lock().unwrap().error.clone()
    }

    /// Closing a terminal cancels unsent input; it must not execute later in a
    /// different session. Unix I/O waits check cancellation within 50 ms, and
    /// LiveTerminal also terminates the local child. Drop never joins a live
    /// writer or waits for pending input to be consumed.
    pub fn cancel(&self) {
        let mut queue = self.shared.queue.lock().unwrap();
        queue.stopping = true;
        let queued: usize = queue
            .chunks
            .iter()
            .map(|bytes| bytes.len() + CHUNK_OVERHEAD)
            .sum();
        queue.chunks.clear();
        queue.bytes -= queued;
        self.shared.wake.notify_all();
    }

    #[cfg(test)]
    fn wait_for(&self, timeout: std::time::Duration, done: impl Fn(&Queue) -> bool) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let mut queue = self.shared.queue.lock().unwrap();
        while !done(&queue) {
            let Some(remaining) = deadline.checked_duration_since(std::time::Instant::now()) else {
                return false;
            };
            queue = self.shared.wake.wait_timeout(queue, remaining).unwrap().0;
        }
        true
    }
}

impl Drop for PtyInput {
    fn drop(&mut self) {
        self.cancel();
        if let Some(worker) = self.worker.take() {
            if worker.is_finished() {
                let _ = worker.join();
            }
            // Never wait on the UI. The Unix worker's nonblocking write/poll
            // loop observes cancellation even if the child ignores shutdown.
        }
    }
}

fn run_writer(shared: Arc<Shared>, mut writer: Box<dyn Write + Send>) {
    loop {
        let bytes = {
            let mut queue = shared.queue.lock().unwrap();
            loop {
                if queue.stopping {
                    queue.finished = true;
                    shared.wake.notify_all();
                    return;
                }
                if let Some(bytes) = queue.chunks.pop_front() {
                    break bytes;
                }
                queue = shared.wake.wait(queue).unwrap();
            }
        };
        let result = write_chunk(&shared, writer.as_mut(), &bytes);
        let mut queue = shared.queue.lock().unwrap();
        queue.bytes -= bytes.len() + CHUNK_OVERHEAD;
        if let Err(error) = result {
            if !queue.stopping {
                queue.error = Some(error.to_string());
            }
            queue.finished = true;
            shared.wake.notify_all();
            return;
        }
        shared.wake.notify_all();
    }
}

fn write_chunk(shared: &Shared, writer: &mut dyn Write, bytes: &[u8]) -> io::Result<()> {
    let mut written = 0;
    while written < bytes.len() {
        if shared.queue.lock().unwrap().stopping {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "terminal input cancelled",
            ));
        }
        // No queue lock is held across a potentially blocking write or flush.
        match writer.write(&bytes[written..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "PTY input write made no progress",
                ))
            }
            Ok(count) => written += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if !wait_for_io(shared, true)? {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "PTY input closed",
                    ));
                }
            }
            Err(error) => return Err(error),
        }
    }
    loop {
        if shared.queue.lock().unwrap().stopping {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "terminal input cancelled",
            ));
        }
        match writer.flush() {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if !wait_for_io(shared, true)? {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "PTY input closed",
                    ));
                }
            }
            result => return result,
        }
    }
}

struct PtyReader {
    reader: Box<dyn Read + Send>,
    shared: Arc<Shared>,
}

impl Read for PtyReader {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.shared.queue.lock().unwrap().stopping {
                return Ok(0);
            }
            match self.reader.read(bytes) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    if !wait_for_io(&self.shared, false)? {
                        return Ok(0);
                    }
                }
                result => return result,
            }
        }
    }
}

// A poll timeout bounds shutdown without busy-spinning on EAGAIN. Readiness is
// advisory: the next read/write still handles EAGAIN and EINTR normally.
fn wait_for_io(shared: &Shared, writing: bool) -> io::Result<bool> {
    if shared.queue.lock().unwrap().stopping {
        return Ok(false);
    }
    #[cfg(unix)]
    if let Some(readiness) = &shared.readiness {
        let wanted = if writing { libc::POLLOUT } else { libc::POLLIN };
        let mut descriptor = libc::pollfd {
            fd: readiness.fd.as_raw_fd(),
            events: wanted,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut descriptor, 1, 50) };
        if result < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::Interrupted {
                Ok(true)
            } else {
                Err(error)
            };
        }
        if descriptor.revents & libc::POLLNVAL != 0 {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "PTY descriptor is closed",
            ));
        }
        if descriptor.revents & (libc::POLLHUP | libc::POLLERR) != 0
            && (writing || descriptor.revents & libc::POLLIN == 0)
        {
            return Ok(false);
        }
        return Ok(!shared.queue.lock().unwrap().stopping);
    }
    let _ = writing;
    let queue = shared.queue.lock().unwrap();
    let queue = shared
        .wake
        .wait_timeout(queue, Duration::from_millis(50))
        .unwrap()
        .0;
    Ok(!queue.stopping)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Read,
        sync::mpsc,
        time::{Duration, Instant},
    };

    #[derive(Default)]
    struct WriterState {
        bytes: Vec<u8>,
        blocked: bool,
        entered: bool,
        interrupt_once: bool,
        would_block_once: bool,
        fail: bool,
    }
    type WriterControl = Arc<(Mutex<WriterState>, Condvar)>;
    struct ControlledWriter(WriterControl);
    impl Write for ControlledWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let (lock, wake) = &*self.0;
            let mut state = lock.lock().unwrap();
            state.entered = true;
            wake.notify_all();
            while state.blocked {
                state = wake.wait(state).unwrap();
            }
            if state.interrupt_once {
                state.interrupt_once = false;
                return Err(io::ErrorKind::Interrupted.into());
            }
            if state.would_block_once {
                state.would_block_once = false;
                return Err(io::ErrorKind::WouldBlock.into());
            }
            if state.fail {
                return Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "test PTY disconnected",
                ));
            }
            let count = bytes.len().min(2);
            state.bytes.extend_from_slice(&bytes[..count]);
            Ok(count)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    fn controlled(blocked: bool) -> (Box<dyn Write + Send>, WriterControl) {
        let control = Arc::new((
            Mutex::new(WriterState {
                blocked,
                ..Default::default()
            }),
            Condvar::new(),
        ));
        (Box::new(ControlledWriter(Arc::clone(&control))), control)
    }
    fn wait_entered(control: &WriterControl) {
        let (lock, wake) = &**control;
        let result = wake
            .wait_timeout_while(lock.lock().unwrap(), Duration::from_secs(2), |state| {
                !state.entered
            })
            .unwrap();
        assert!(result.0.entered, "writer did not start");
    }
    fn unblock(control: &WriterControl) {
        let (lock, wake) = &**control;
        lock.lock().unwrap().blocked = false;
        wake.notify_all();
    }

    #[test]
    fn ordinary_keys_unicode_and_partial_writes_keep_exact_order() {
        let (writer, control) = controlled(false);
        control.0.lock().unwrap().interrupt_once = true;
        control.0.lock().unwrap().would_block_once = true;
        let input = PtyInput::new(writer).unwrap();
        for bytes in [b"a".as_slice(), "é".as_bytes(), b"\x1b[D", b"\r"] {
            input.send(bytes).unwrap();
        }
        assert!(input.wait_for(Duration::from_secs(2), |queue| queue.bytes == 0));
        assert_eq!(control.0.lock().unwrap().bytes, "aé\x1b[D\r".as_bytes());
        assert!(input.error().is_none());
    }

    #[test]
    fn output_reader_retries_interrupts_and_would_block_without_losing_bytes() {
        struct TransientReader {
            attempts: usize,
            data: io::Cursor<Vec<u8>>,
        }
        impl Read for TransientReader {
            fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
                self.attempts += 1;
                match self.attempts {
                    1 => Err(io::ErrorKind::Interrupted.into()),
                    2 => Err(io::ErrorKind::WouldBlock.into()),
                    _ => self.data.read(bytes),
                }
            }
        }
        let (writer, _) = controlled(false);
        let input = PtyInput::new(writer).unwrap();
        let mut reader = input.reader(Box::new(TransientReader {
            attempts: 0,
            data: io::Cursor::new("écho\r\n".as_bytes().to_vec()),
        }));
        let mut received = Vec::new();
        reader.read_to_end(&mut received).unwrap();
        assert_eq!(received, "écho\r\n".as_bytes());
        input.cancel();
        assert_eq!(reader.read(&mut [0; 10]).unwrap(), 0);
    }

    #[test]
    fn in_flight_bytes_count_toward_bound_and_full_rejects_whole_chunk() {
        let (writer, control) = controlled(true);
        let input = PtyInput::with_capacity(writer, CHUNK_OVERHEAD + 4).unwrap();
        input.send(b"abcd").unwrap();
        wait_entered(&control);
        let started = Instant::now();
        assert!(input
            .send(b"REJECTED")
            .unwrap_err()
            .to_string()
            .contains("queue is full"));
        assert!(started.elapsed() < Duration::from_millis(200));
        unblock(&control);
        assert!(input.wait_for(Duration::from_secs(2), |queue| queue.bytes == 0));
        input.send(b"z").unwrap();
        assert!(input.wait_for(Duration::from_secs(2), |queue| queue.bytes == 0));
        assert_eq!(control.0.lock().unwrap().bytes, b"abcdz");
    }

    #[test]
    fn asynchronous_disconnect_is_sticky_and_reported_on_following_send() {
        let (writer, control) = controlled(false);
        control.0.lock().unwrap().fail = true;
        let input = PtyInput::new(writer).unwrap();
        input.send(b"accepted before disconnect").unwrap();
        assert!(input.wait_for(Duration::from_secs(2), |queue| queue.finished));
        assert!(input.error().unwrap().contains("disconnected"));
        assert!(input
            .send(b"later")
            .unwrap_err()
            .to_string()
            .contains("disconnected"));
    }

    #[test]
    fn cancel_does_not_wait_for_blocked_writer_or_execute_queued_input() {
        let (writer, control) = controlled(true);
        let input = PtyInput::new(writer).unwrap();
        input.send(b"first").unwrap();
        wait_entered(&control);
        input.send(b"must not execute after close").unwrap();
        let started = Instant::now();
        input.cancel();
        assert!(started.elapsed() < Duration::from_millis(200));
        assert!(input
            .send(b"later")
            .unwrap_err()
            .to_string()
            .contains("closed"));
        unblock(&control);
        assert!(input.wait_for(Duration::from_secs(2), |queue| queue.finished));
        assert_eq!(control.0.lock().unwrap().bytes, b"fi");
    }

    #[cfg(unix)]
    #[test]
    fn large_paste_returns_while_bounded_output_queue_is_full() {
        use portable_pty::{native_pty_system, CommandBuilder, PtySize};
        use std::sync::atomic::{AtomicUsize, Ordering};
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "stty raw -echo; printf READY; head -c 1048576 /dev/zero; head -c 1048576 >/dev/null; printf NIA_DONE"]);
        let mut child = pair.slave.spawn_command(command).unwrap();
        let input = Arc::new(
            PtyInput::for_pty(pair.master.as_ref(), pair.master.take_writer().unwrap()).unwrap(),
        );
        let mut reader = input.reader(pair.master.try_clone_reader().unwrap());
        drop(pair.slave);
        let (tx, rx) = mpsc::sync_channel(64);
        let received = Arc::new(AtomicUsize::new(0));
        let received_by_reader = Arc::clone(&received);
        let reader_thread = thread::spawn(move || {
            let mut buf = [0; 8192];
            while let Ok(count) = reader.read(&mut buf) {
                if count == 0 || tx.send(buf[..count].to_vec()).is_err() {
                    break;
                }
                received_by_reader.fetch_add(1, Ordering::SeqCst);
            }
        });
        let first = rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(
            first.starts_with(b"READY"),
            "raw-mode fixture did not start"
        );
        let deadline = Instant::now() + Duration::from_secs(3);
        while received.load(Ordering::SeqCst) < 65 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(1));
        }
        let output_was_full = received.load(Ordering::SeqCst) >= 65;
        let (accepted, acceptance) = mpsc::channel();
        let producer_input = Arc::clone(&input);
        let producer = thread::spawn(move || {
            accepted
                .send(
                    producer_input
                        .send(&vec![b'i'; 1024 * 1024])
                        .map_err(|e| e.to_string()),
                )
                .unwrap();
        });
        // With synchronous input this times out: the child cannot read until
        // its output finishes, and output cannot finish while polling waits.
        let returned_without_poll = acceptance.recv_timeout(Duration::from_millis(300));
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut output = first;
        while Instant::now() < deadline && !output.ends_with(b"NIA_DONE") {
            match rx.recv_timeout(Duration::from_millis(20)) {
                Ok(bytes) => output.extend_from_slice(&bytes),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => break,
            }
        }
        let delivered = input.wait_for(Duration::from_secs(1), |queue| queue.bytes == 0);
        let _ = child.kill();
        let _ = child.wait();
        drop(rx);
        let _ = producer.join();
        let _ = reader_thread.join();
        assert!(
            output_was_full,
            "fixture must fill the bounded reader before input"
        );
        assert_eq!(
            returned_without_poll.unwrap(),
            Ok(()),
            "input enqueue must not wait for output polling"
        );
        assert!(
            delivered && output.ends_with(b"NIA_DONE"),
            "continued polling must complete both streams"
        );
    }

    #[cfg(unix)]
    #[test]
    fn cancelling_releases_input_worker_before_child_termination() {
        use portable_pty::{native_pty_system, CommandBuilder, PtySize};
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "stty raw -echo; printf READY; exec sleep 30"]);
        let mut child = pair.slave.spawn_command(command).unwrap();
        let input =
            PtyInput::for_pty(pair.master.as_ref(), pair.master.take_writer().unwrap()).unwrap();
        let mut reader = input.reader(pair.master.try_clone_reader().unwrap());
        drop(pair.slave);
        let mut ready = [0; 5];
        reader.read_exact(&mut ready).unwrap();
        assert_eq!(&ready, b"READY");
        input.send(&vec![b'x'; 1024 * 1024]).unwrap();
        assert!(!input.wait_for(Duration::from_millis(50), |queue| queue.bytes == 0));
        let started = Instant::now();
        input.cancel();
        let stopped = input.wait_for(Duration::from_secs(2), |queue| queue.finished);
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(
            stopped,
            "cancellation must release the writer even while the child remains alive"
        );
        assert!(started.elapsed() < Duration::from_secs(3));
    }
}
