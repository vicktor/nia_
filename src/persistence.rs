// SPDX-License-Identifier: MPL-2.0
//! Ordered, bounded persistence. Disk latency never runs inside the display poll.
//! A failed job retains its exact write/index progress until retry succeeds.

use crate::{
    history::HistoryIndexer,
    storage::{SessionRecord, Store},
};
use anyhow::{anyhow, Context, Result};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs::File,
    io::{self, Write},
    sync::{Arc, Condvar, Mutex},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

pub(crate) const QUEUE_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const JOB_OVERHEAD: usize = 512;
const FLUSH_TIMEOUT: Duration = Duration::from_secs(5);
const RETRY_DELAY: Duration = Duration::from_millis(250);

pub(crate) type CommandEntry = (f64, i64, i64, String, String);

pub(crate) enum PersistenceJob {
    Output(OutputJob),
    Marks {
        session: String,
        entries: Vec<CommandEntry>,
    },
    State(SessionRecord),
    Close(String),
    Indexer {
        session: String,
        indexer: HistoryIndexer,
    },
}

pub(crate) struct OutputJob {
    session: String,
    bytes: Vec<u8>,
    written: usize,
    synced: bool,
    prepared: Option<PreparedIndex>,
}

struct PreparedIndex {
    indexer: HistoryIndexer,
    lines: Vec<String>,
    anchors: Vec<(f64, usize)>,
}

impl PersistenceJob {
    pub(crate) fn output(session: &str, bytes: Vec<u8>) -> Self {
        Self::Output(OutputJob {
            session: session.to_owned(),
            bytes,
            written: 0,
            synced: false,
            prepared: None,
        })
    }

    fn session(&self) -> &str {
        match self {
            Self::Output(job) => &job.session,
            Self::Marks { session, .. } | Self::Indexer { session, .. } => session,
            Self::State(record) => &record.id,
            Self::Close(session) => session,
        }
    }

    fn cost(&self) -> usize {
        JOB_OVERHEAD
            + self.session().len()
            + match self {
                Self::Output(job) => job.bytes.len(),
                Self::Marks { entries, .. } => {
                    entries.iter().map(|e| 64 + e.3.len() + e.4.len()).sum()
                }
                Self::State(record) => {
                    record.cwd.len() + record.venv.as_ref().map_or(0, String::len)
                }
                // The streaming indexer is bounded to a partial 16 KiB line/OSC.
                Self::Indexer { .. } => 17 * 1024,
                Self::Close(_) => 0,
            }
    }
}

struct QueuedJob {
    sequence: u64,
    cost: usize,
    job: PersistenceJob,
}

#[derive(Default)]
struct Queue {
    jobs: VecDeque<QueuedJob>,
    bytes: usize,
    issued: u64,
    completed: u64,
    sessions: HashMap<String, usize>,
    changed_history: HashSet<String>,
    error: Option<String>,
    stopping: bool,
    finished: bool,
}

struct Shared {
    queue: Mutex<Queue>,
    wake: Condvar,
    capacity: usize,
    #[cfg(test)]
    faults: Mutex<TestFaults>,
}

pub(crate) struct Persistence {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}

struct SessionWriter {
    file: Option<File>,
    indexer: HistoryIndexer,
}

impl Persistence {
    pub(crate) fn new(store: &Store) -> Result<Self> {
        Self::with_capacity(store, QUEUE_BYTES)
    }

    fn with_capacity(store: &Store, capacity: usize) -> Result<Self> {
        let store = store.persistence_connection()?;
        let shared = Arc::new(Shared {
            queue: Mutex::new(Queue::default()),
            wake: Condvar::new(),
            capacity,
            #[cfg(test)]
            faults: Mutex::new(TestFaults::default()),
        });
        let thread_shared = Arc::clone(&shared);
        let worker = thread::Builder::new()
            .name("nia-persistence".into())
            .spawn(move || run_worker(thread_shared, store))
            .context("start terminal persistence")?;
        Ok(Self {
            shared,
            worker: Some(worker),
        })
    }

    /// UI callers never wait for capacity. Stop reading the bounded PTY queue
    /// when this returns false, allowing kernel/reader backpressure to apply.
    pub(crate) fn can_accept(&self, bytes: usize) -> bool {
        let queue = self.shared.queue.lock().unwrap();
        !queue.stopping
            && !queue.finished
            && bytes <= self.shared.capacity.saturating_sub(queue.bytes)
    }

    pub(crate) fn try_enqueue(&self, job: PersistenceJob) -> Result<u64, PersistenceJob> {
        let cost = job.cost();
        let mut queue = self.shared.queue.lock().unwrap();
        if queue.stopping
            || queue.finished
            || cost > self.shared.capacity.saturating_sub(queue.bytes)
        {
            return Err(job);
        }
        queue.issued += 1;
        let sequence = queue.issued;
        *queue.sessions.entry(job.session().to_owned()).or_default() += 1;
        queue.bytes += cost;
        queue.jobs.push_back(QueuedJob {
            sequence,
            cost,
            job,
        });
        self.shared.wake.notify_one();
        Ok(sequence)
    }

    pub(crate) fn session_pending(&self, session: &str) -> bool {
        self.shared
            .queue
            .lock()
            .unwrap()
            .sessions
            .contains_key(session)
    }

    pub(crate) fn feedback(&self) -> (Option<String>, HashSet<String>) {
        let mut queue = self.shared.queue.lock().unwrap();
        (
            queue.error.clone(),
            std::mem::take(&mut queue.changed_history),
        )
    }

    /// Only explicit history/navigation/shutdown actions use a barrier.
    /// An I/O error or an unresponsive disk cannot wait forever on the UI.
    pub(crate) fn flush(&self) -> Result<()> {
        self.flush_with_timeout(FLUSH_TIMEOUT)
    }

    pub(crate) fn flush_with_timeout(&self, timeout: Duration) -> Result<()> {
        let deadline = Instant::now() + timeout;
        let mut queue = self.shared.queue.lock().unwrap();
        let target = queue.issued;
        while queue.completed < target {
            if let Some(error) = &queue.error {
                return Err(anyhow!(error.clone()));
            }
            if queue.finished {
                return Err(anyhow!(
                    "Terminal persistence stopped before completing its queue"
                ));
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(anyhow!(
                    "Timed out waiting for terminal history to reach disk"
                ));
            };
            queue = self.shared.wake.wait_timeout(queue, remaining).unwrap().0;
        }
        Ok(())
    }

    pub(crate) fn set_indexer(&self, session: &str, indexer: HistoryIndexer) -> Result<()> {
        self.flush()?;
        self.try_enqueue(PersistenceJob::Indexer {
            session: session.to_owned(),
            indexer,
        })
        .map_err(|_| anyhow!("Terminal persistence is unavailable"))?;
        self.flush()
    }

    #[cfg(test)]
    pub(crate) fn block_for_tests(&self, blocked: bool) {
        self.shared.faults.lock().unwrap().blocked = blocked;
    }
}

impl Drop for Persistence {
    fn drop(&mut self) {
        if let Err(error) = self.flush() {
            eprintln!("Nia could not finish saving terminal history: {error}");
        }
        let deadline = Instant::now() + Duration::from_millis(500);
        let mut queue = self.shared.queue.lock().unwrap();
        queue.stopping = true;
        self.shared.wake.notify_all();
        while !queue.finished {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            queue = self.shared.wake.wait_timeout(queue, remaining).unwrap().0;
        }
        let finished = queue.finished;
        drop(queue);
        if let Some(worker) = self.worker.take() {
            if finished {
                let _ = worker.join();
            }
            // A stuck OS write cannot be cancelled safely. Detach rather than
            // blocking app shutdown; the worker still owns every queued byte.
        }
    }
}

fn run_worker(shared: Arc<Shared>, mut store: Store) {
    let mut sessions: HashMap<String, SessionWriter> = HashMap::new();
    'worker: loop {
        let mut queued = {
            let mut queue = shared.queue.lock().unwrap();
            loop {
                if let Some(job) = queue.jobs.pop_front() {
                    break job;
                }
                if queue.stopping {
                    break 'worker;
                }
                queue = shared.wake.wait(queue).unwrap();
            }
        };
        loop {
            match persist_job(&shared, &mut store, &mut sessions, &mut queued.job) {
                Ok(()) => {
                    let mut queue = shared.queue.lock().unwrap();
                    queue.bytes -= queued.cost;
                    queue.completed = queued.sequence;
                    let session = queued.job.session();
                    if let Some(count) = queue.sessions.get_mut(session) {
                        *count -= 1;
                        if *count == 0 {
                            queue.sessions.remove(session);
                        }
                    }
                    if matches!(queued.job, PersistenceJob::Output(_)) {
                        queue.changed_history.insert(session.to_owned());
                    }
                    queue.error = None;
                    shared.wake.notify_all();
                    break;
                }
                Err(error) => {
                    let retry_at = Instant::now() + RETRY_DELAY;
                    let mut queue = shared.queue.lock().unwrap();
                    queue.error = Some(format!("Terminal history: {error:#}"));
                    shared.wake.notify_all();
                    while !queue.stopping {
                        let Some(remaining) = retry_at.checked_duration_since(Instant::now())
                        else {
                            break;
                        };
                        queue = shared.wake.wait_timeout(queue, remaining).unwrap().0;
                    }
                    if queue.stopping {
                        break 'worker;
                    }
                    // Retry this same job with its recorded byte/index progress.
                }
            }
        }
    }
    let mut queue = shared.queue.lock().unwrap();
    queue.finished = true;
    shared.wake.notify_all();
}

fn persist_job(
    shared: &Shared,
    store: &mut Store,
    sessions: &mut HashMap<String, SessionWriter>,
    job: &mut PersistenceJob,
) -> Result<()> {
    #[cfg(not(test))]
    let _ = shared;
    match job {
        PersistenceJob::Output(job) => {
            let session = sessions
                .entry(job.session.clone())
                .or_insert_with(|| SessionWriter {
                    file: None,
                    indexer: HistoryIndexer::default(),
                });
            if session.file.is_none() {
                session.file = Some(store.log_file(&job.session)?);
            }
            let file = session.file.as_mut().unwrap();
            #[cfg(test)]
            test_before_write(shared, file, job)?;
            while job.written < job.bytes.len() {
                match file.write(&job.bytes[job.written..]) {
                    Ok(0) => {
                        return Err(io::Error::new(
                            io::ErrorKind::WriteZero,
                            "terminal log write made no progress",
                        )
                        .into())
                    }
                    Ok(count) => job.written += count,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error.into()),
                }
            }
            if !job.synced {
                file.sync_data()?;
                job.synced = true;
            }
            if job.prepared.is_none() {
                let mut indexer = session.indexer.clone();
                let lines = indexer.ingest(&job.bytes);
                let anchors = indexer.take_anchors();
                job.prepared = Some(PreparedIndex {
                    indexer,
                    lines,
                    anchors,
                });
            }
            #[cfg(test)]
            {
                let mut faults = shared.faults.lock().unwrap();
                if faults.fail_index_once {
                    faults.fail_index_once = false;
                    return Err(anyhow!("injected index failure"));
                }
            }
            let prepared = job.prepared.as_ref().unwrap();
            store.append_history_lines(&job.session, &prepared.lines, &prepared.anchors)?;
            session.indexer = job.prepared.take().unwrap().indexer;
        }
        PersistenceJob::Marks { session, entries } => {
            store.append_command_marks(session, entries)?
        }
        PersistenceJob::State(record) => store.update_shell_state(record)?,
        PersistenceJob::Close(session) => {
            store.close(session)?;
            sessions.remove(session);
        }
        PersistenceJob::Indexer { session, indexer } => {
            sessions
                .entry(session.clone())
                .or_insert_with(|| SessionWriter {
                    file: None,
                    indexer: HistoryIndexer::default(),
                })
                .indexer = std::mem::take(indexer);
        }
    }
    Ok(())
}

#[cfg(test)]
#[derive(Default)]
struct TestFaults {
    blocked: bool,
    partial_write_once: Option<usize>,
    fail_index_once: bool,
}

#[cfg(test)]
fn test_before_write(shared: &Shared, file: &mut File, job: &mut OutputJob) -> Result<()> {
    loop {
        let mut faults = shared.faults.lock().unwrap();
        if !faults.blocked {
            if let Some(count) = faults.partial_write_once.take() {
                let end = (job.written + count).min(job.bytes.len());
                file.write_all(&job.bytes[job.written..end])?;
                job.written = end;
                return Err(anyhow!("injected failure after partial raw write"));
            }
            return Ok(());
        }
        drop(faults);
        if shared.queue.lock().unwrap().stopping {
            return Err(anyhow!("test disk stopped"));
        }
        thread::sleep(Duration::from_millis(2));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn submit(writer: &Persistence, job: PersistenceJob) {
        assert!(
            writer.try_enqueue(job).is_ok(),
            "test queue unexpectedly full"
        );
    }

    fn eventually_flush(writer: &Persistence) {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if writer.flush().is_ok() {
                return;
            }
            assert!(Instant::now() < deadline, "persistence did not recover");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn failed_partial_write_and_index_retry_never_duplicate_bytes_or_lines() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        let writer = Persistence::new(&store).unwrap();
        {
            let mut faults = writer.shared.faults.lock().unwrap();
            faults.partial_write_once = Some(3);
            faults.fail_index_once = true;
        }
        let first = b"one\r\npart\xc3";
        let second = b"\xa9\r\nthree\r\n";
        submit(&writer, PersistenceJob::output("retry", first.to_vec()));
        submit(&writer, PersistenceJob::output("retry", second.to_vec()));
        assert!(
            writer.flush().is_err(),
            "barrier must report the write failure"
        );
        assert!(std::fs::read(store.log_path("retry"))
            .unwrap()
            .starts_with(&first[..3]));
        eventually_flush(&writer);
        assert_eq!(
            std::fs::read(store.log_path("retry")).unwrap(),
            [first.as_slice(), second.as_slice()].concat()
        );
        assert_eq!(
            store.history_page_from("retry", 0, 10).unwrap(),
            ["one", "parté", "three"]
        );
    }

    #[test]
    fn full_queue_counts_inflight_bytes_and_retains_rejected_output_for_retry() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        let first = PersistenceJob::output("bounded", b"first\r\n".to_vec());
        let writer = Persistence::with_capacity(&store, first.cost()).unwrap();
        writer.block_for_tests(true);
        submit(&writer, first);
        assert!(!writer.can_accept(1));
        let second =
            match writer.try_enqueue(PersistenceJob::output("bounded", b"next\r\n".to_vec())) {
                Err(job) => job,
                Ok(_) => panic!("queue exceeded its byte limit"),
            };
        writer.block_for_tests(false);
        writer.flush().unwrap();
        submit(&writer, second);
        writer.flush().unwrap();
        assert_eq!(
            std::fs::read(store.log_path("bounded")).unwrap(),
            b"first\r\nnext\r\n"
        );
    }

    #[test]
    fn real_sqlite_transaction_failure_retries_without_partial_or_duplicate_index() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        let writer = Persistence::new(&store).unwrap();
        let control = rusqlite::Connection::open(temp.path().join("sessions.sqlite3")).unwrap();
        control
            .execute_batch(
                "CREATE TRIGGER reject_history BEFORE INSERT ON history_lines
            WHEN NEW.text='reject' BEGIN SELECT RAISE(ABORT, 'injected database failure'); END;",
            )
            .unwrap();
        let bytes = b"first\r\nreject\r\nlast\r\n";
        submit(&writer, PersistenceJob::output("sqlite", bytes.to_vec()));
        assert!(writer.flush().is_err());
        assert!(
            store.history_page_from("sqlite", 0, 10).unwrap().is_empty(),
            "whole index transaction must roll back"
        );
        assert_eq!(std::fs::read(store.log_path("sqlite")).unwrap(), bytes);
        control
            .execute_batch("DROP TRIGGER reject_history")
            .unwrap();
        eventually_flush(&writer);
        assert_eq!(
            store.history_page_from("sqlite", 0, 10).unwrap(),
            ["first", "reject", "last"]
        );
        assert_eq!(std::fs::read(store.log_path("sqlite")).unwrap(), bytes);
    }

    #[test]
    fn repair_barrier_preserves_partial_utf8_and_command_anchor_continuity() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        let writer = Persistence::new(&store).unwrap();
        submit(
            &writer,
            PersistenceJob::Marks {
                session: "repair".into(),
                entries: vec![(1000.5, 1, 0, "/tmp".into(), "command".into())],
            },
        );
        let first = b"$ command\r\n\x1b]133;C;1000.5\x07caf\xc3";
        submit(&writer, PersistenceJob::output("repair", first.to_vec()));
        writer.flush().unwrap();
        let repaired = store.ensure_history_index("repair").unwrap().unwrap();
        writer.set_indexer("repair", repaired).unwrap();
        submit(
            &writer,
            PersistenceJob::output("repair", b"\xa9\r\n".to_vec()),
        );
        writer.flush().unwrap();
        assert_eq!(
            store.history_page_from("repair", 0, 10).unwrap(),
            ["$ command", "café"]
        );
        let marks = store.recent_command_marks("repair", 10).unwrap();
        assert_eq!(marks.len(), 1);
        assert!(marks[0].has_anchor);
        assert_eq!(
            store.command_start_line("repair", marks[0].id).unwrap(),
            Some(0)
        );
        assert_eq!(
            std::fs::read(store.log_path("repair")).unwrap(),
            [first.as_slice(), b"\xa9\r\n"].concat()
        );
    }

    #[test]
    fn normal_worker_drop_and_close_drain_all_preceding_output() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        store
            .upsert(&SessionRecord {
                id: "closing".into(),
                cwd: "/tmp".into(),
                venv: None,
                closed: false,
            })
            .unwrap();
        {
            let writer = Persistence::new(&store).unwrap();
            submit(
                &writer,
                PersistenceJob::output("closing", b"one\r\n".to_vec()),
            );
            submit(
                &writer,
                PersistenceJob::output("closing", b"two\r\n".to_vec()),
            );
            submit(&writer, PersistenceJob::Close("closing".into()));
            // Drop, rather than a manually inserted test flush, drains the queue.
        }
        assert_eq!(
            std::fs::read(store.log_path("closing")).unwrap(),
            b"one\r\ntwo\r\n"
        );
        assert_eq!(
            store.history_page_from("closing", 0, 10).unwrap(),
            ["one", "two"]
        );
        assert!(store.list().unwrap()[0].closed);
    }

    #[test]
    fn blocked_disk_barrier_times_out_without_discarding_its_job() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::for_tests(temp.path().to_path_buf()).unwrap();
        let writer = Persistence::new(&store).unwrap();
        writer.block_for_tests(true);
        submit(
            &writer,
            PersistenceJob::output("slow", b"retained\r\n".to_vec()),
        );
        let error = writer
            .flush_with_timeout(Duration::from_millis(20))
            .unwrap_err();
        assert!(error.to_string().contains("Timed out"));
        assert!(writer.session_pending("slow"));
        writer.block_for_tests(false);
        writer.flush().unwrap();
        assert_eq!(
            std::fs::read(store.log_path("slow")).unwrap(),
            b"retained\r\n"
        );
    }
}
