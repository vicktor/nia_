// SPDX-License-Identifier: MPL-2.0
#[path = "bin/nia-backup.rs"]
mod backup_engine;
mod backup_config;
mod actions;
mod storage;
mod terminal;
mod pty_input;

use std::{collections::HashMap, time::{Duration, SystemTime, UNIX_EPOCH}, sync::mpsc::{self, Receiver}};
use eframe::egui::{self, Color32, FontId, Pos2, Sense, Vec2};
use storage::{SessionRecord, Store};
use terminal::LiveTerminal;

const INITIAL_ROWS: u16 = 28;
const INITIAL_COLS: u16 = 100;
const REPLAY_CAP: usize = 32 * 1024 * 1024;

struct App {
    store: Store,
    records: Vec<SessionRecord>,
    live: HashMap<String, LiveTerminal>,
    active: Option<String>,
    new_id: String,
    error: String,
    palette: bool,
    pending_action: Option<actions::Action>,
    actions: Vec<actions::Action>,
    selection: Option<((usize,usize),(usize,usize))>,
    opacity: f32,
    preferences_open: bool,
    sidebar_visible: bool,
    cursor_style: u8, // 0 = bloque, 1 = barra, 2 = subrayado
    cursor_blink: bool,
    backup_config: backup_config::BackupConfig,
    backup_result: Option<Receiver<Result<String, String>>>,
    backup_status: String,
    restore_destination: String,
    preferences_section: u8,
}

impl App {
    fn new() -> anyhow::Result<Self> {
        let store = Store::open()?;
        let records = store.list()?;
        let opacity = 1.0; // Use an opaque native window until titlebar-safe transparency is implemented.
        let sidebar_visible = store.preference_bool("sidebar_visible", true)?;
        let cursor_style = store.preference_u8("cursor_style", 1)?.min(2);
        let cursor_blink = store.preference_bool("cursor_blink", true)?;
        let backup_config = backup_config::BackupConfig::load().unwrap_or_default();
        let active = records.iter().find(|s| !s.closed).map(|s| s.id.clone());
        let mut app = Self { store, records, live: HashMap::new(), active, new_id: String::new(),
            error: String::new(), palette: false, pending_action: None, actions: actions::load(), selection: None, opacity, preferences_open: false, sidebar_visible, cursor_style, cursor_blink, backup_config, backup_result: None, backup_status: String::new(), restore_destination: String::new(), preferences_section: 0 };
        if let Some(id) = app.active.clone() { app.open(&id); }
        Ok(app)
    }

    fn start_backup_task(&mut self, cmd: &'static str) {
        if self.backup_result.is_some() { return; }
        if let Err(e) = self.backup_config.save() {
            self.backup_status = format!("Configuración: {e}");
            return;
        }
        let destination = if cmd == "restore" { Some(self.restore_destination.clone()) } else { None };
        if cmd == "restore" && destination.as_deref().unwrap_or("").trim().is_empty() {
            self.backup_status = "Indica un directorio vacío para restaurar".into();
            return;
        }
        let (tx, rx) = mpsc::channel();
        self.backup_result = Some(rx);
        self.backup_status = format!("Ejecutando {cmd}...");
        let config = self.backup_config.clone();
        std::thread::spawn(move || {
            // Explicit preferences take precedence over inherited env from a shell.
            // Only one backup worker runs at a time.
            let configuration = (|| -> anyhow::Result<()> {
                std::env::set_var("RESTIC_REPOSITORY", config.repository()?);
                std::env::set_var("RESTIC_PASSWORD_FILE", config.password_path()?);
                std::env::remove_var("RESTIC_PASSWORD");
                std::env::remove_var("RESTIC_PASSWORD_COMMAND");
                Ok(())
            })();
            let path = destination.as_deref().map(std::path::Path::new);
            let result = configuration.and_then(|_| backup_engine::execute(cmd, path))
                .map(|_| format!("{cmd}: completado. Consulta la terminal para los detalles."))
                .map_err(|e| format!("{cmd}: {e:#}"));
            let _ = tx.send(result);
        });
    }

    fn add(&mut self) {
        let id = self.new_id.trim().to_owned();
        if id.is_empty() || id.len() > 64 || id.contains('/') || id.contains('\\') || id.contains('\n') { self.error = "ID inválido: 1–64 caracteres, sin barras".into(); return; }
        if self.records.iter().any(|s| s.id == id) { self.open(&id); return; }
        let cwd = dirs::home_dir().unwrap_or_default().to_string_lossy().to_string();
        let record = SessionRecord { id: id.clone(), cwd, venv: None, closed: false };
        match self.store.upsert(&record) {
            Ok(()) => { self.records.push(record); self.new_id.clear(); self.open(&id); }
            Err(e) => self.error = e.to_string(),
        }
    }

    fn open(&mut self, id: &str) {
        if let Some(rec) = self.records.iter_mut().find(|s| s.id == id) {
            rec.closed = false;
            if let Err(e) = self.store.upsert(rec) { self.error = e.to_string(); return; }
            if !self.live.contains_key(id) {
                match LiveTerminal::spawn(rec.clone(), INITIAL_ROWS, INITIAL_COLS, 10000, None, None) {
                    Ok(mut term) => {
                        match self.store.replay(id, REPLAY_CAP) {
                            Ok(bytes) => term.parser.process(&bytes),
                            Err(e) => self.error = format!("Historial de {id}: {e}"),
                        }
                        self.live.insert(id.to_owned(), term);
                    },
                    Err(e) => { self.error = e.to_string(); return; }
                }
            }
            self.active = Some(id.to_owned());
            self.selection = None;
        }
    }

    fn close(&mut self, id: &str) {
        self.live.remove(id); // PTY process lifetime is not persisted in this prototype.
        if let Err(e) = self.store.close(id) { self.error = e.to_string(); }
        if let Some(rec) = self.records.iter_mut().find(|s| s.id == id) { rec.closed = true; }
        if self.active.as_deref() == Some(id) {
            self.active = self.records.iter().find(|s| !s.closed).map(|s| s.id.clone());
        }
    }

    fn drain(&mut self) {
        // The Zsh precmd hook publishes an atomic state snapshot after each command.
        // Persist it even when this session is not the visible tab.
        for (id, term) in self.live.iter_mut() {
            if let Ok(Some((cwd, venv))) = term.snapshot_state() {
                if let Some(record) = self.records.iter_mut().find(|r| r.id == *id) {
                    if record.cwd != cwd || record.venv != venv {
                        record.cwd = cwd;
                        record.venv = venv;
                        if let Err(e) = self.store.upsert(record) {
                            self.error = format!("No se pudo guardar el directorio: {e}");
                        }
                    }
                }
            }
        }
        for (id, term) in self.live.iter_mut() {
            let mut chunks = Vec::new();
            while let Ok(bytes) = term.rx.try_recv() { chunks.extend_from_slice(&bytes); if chunks.len() >= 128 * 1024 { break; } }
            if !chunks.is_empty() {
                // Durability first; error is surfaced, never silently ignored.
                match self.store.log_file(id).and_then(|mut f| Store::append_and_sync(&mut f, &chunks)) {
                    Ok(()) => term.parser.process(&chunks),
                    Err(e) => self.error = format!("No se pudo guardar la salida: {e}"),
                }
            }
        }
    }

    fn send_active(&mut self, bytes: &[u8]) {
        if let Some(id) = self.active.as_ref() {
            if let Some(term) = self.live.get_mut(id) {
                if let Err(e) = term.send(bytes) { self.error = e.to_string(); }
            }
        }
    }

    fn activate_slot(&mut self, slot: usize, ctx: &egui::Context) {
        // The order in the session list is the order used by Cmd+1..9.
        if let Some(id) = self.records.get(slot).map(|r| r.id.clone()) {
            self.open(&id);
            ctx.memory_mut(|m| m.request_focus(egui::Id::new("terminal_canvas")));
        }
    }

    fn global_shortcuts(&mut self, ctx: &egui::Context) {
        // Run before widgets claim keyboard focus; shortcuts also work with the sidebar open.
        let events = ctx.input(|i| i.events.clone());
        for event in events {
            if let egui::Event::Key { key, pressed: true, modifiers, .. } = event {
                if !modifiers.command || modifiers.shift || modifiers.alt { continue; }
                match key {
                    egui::Key::K => self.palette = !self.palette,
                    egui::Key::Comma => { self.preferences_open = !self.preferences_open; },
                    egui::Key::B => {
                        self.sidebar_visible = !self.sidebar_visible;
                        if let Err(e) = self.store.set_preference("sidebar_visible", self.sidebar_visible.to_string()) { self.error = e.to_string(); }
                        ctx.memory_mut(|m| m.request_focus(egui::Id::new("terminal_canvas")));
                    },
                    egui::Key::Num1 => self.activate_slot(0, ctx),
                    egui::Key::Num2 => self.activate_slot(1, ctx),
                    egui::Key::Num3 => self.activate_slot(2, ctx),
                    egui::Key::Num4 => self.activate_slot(3, ctx),
                    egui::Key::Num5 => self.activate_slot(4, ctx),
                    egui::Key::Num6 => self.activate_slot(5, ctx),
                    egui::Key::Num7 => self.activate_slot(6, ctx),
                    egui::Key::Num8 => self.activate_slot(7, ctx),
                    egui::Key::Num9 => self.activate_slot(8, ctx),
                    _ => {},
                }
            }
        }
    }

    fn keyboard(&mut self, ctx: &egui::Context) {
        let events = ctx.input(|i| i.events.clone());
        for event in events {
            match event {
                _ if self.palette || self.pending_action.is_some() || self.preferences_open => {},
                egui::Event::Text(t) => self.send_active(t.as_bytes()),
                egui::Event::Paste(t) => self.send_active(t.as_bytes()),
                egui::Event::Key { key, pressed: true, modifiers, .. } => {
                    if modifiers.command { continue; }
                    let bytes: Option<&[u8]> = match key {
                        egui::Key::Enter => Some(b"\r"),
                        egui::Key::Backspace => Some(b"\x7f"),
                        egui::Key::Tab => Some(b"\t"),
                        egui::Key::Escape => Some(b"\x1b"),
                        egui::Key::ArrowUp => Some(b"\x1b[A"),
                        egui::Key::ArrowDown => Some(b"\x1b[B"),
                        egui::Key::ArrowRight => Some(b"\x1b[C"),
                        egui::Key::ArrowLeft => Some(b"\x1b[D"),
                        egui::Key::Home => Some(b"\x1b[H"),
                        egui::Key::End => Some(b"\x1b[F"),
                        egui::Key::Delete => Some(b"\x1b[3~"),
                        _ => None,
                    };
                    if let Some(bytes) = bytes { self.send_active(bytes); }
                    else if modifiers.ctrl {
                        // Control characters used by common shells (Ctrl-C, Ctrl-D, Ctrl-Z).
                        let ctrl = match key { egui::Key::C => Some(3), egui::Key::D => Some(4), egui::Key::Z => Some(26), egui::Key::L => Some(12), egui::Key::A => Some(1), egui::Key::E => Some(5), _ => None };
                        if let Some(c) = ctrl { self.send_active(&[c]); }
                    }
                }
                _ => {}
            }
        }
    }

    fn paint_terminal(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.active.clone() else { ui.label("Crea o abre una sesión."); return; };
        let font = FontId::monospace(14.0);
        let cw = 8.6_f32;
        let ch = 18.0_f32;
        let available = ui.available_size_before_wrap();
        let cols = (available.x.max(cw) / cw).floor().clamp(1.0, u16::MAX as f32) as u16;
        let rows = (available.y.max(ch) / ch).floor().clamp(1.0, u16::MAX as f32) as u16;
        let Some(term) = self.live.get_mut(&id) else { ui.label("Sesión archivada: ábrela desde la barra lateral."); return; };
        if { let (actual_rows, actual_cols) = term.parser.screen().size(); (actual_rows.get(), actual_cols.get()) } != (rows, cols) {
            if let Err(e) = term.resize(rows, cols) { self.error = format!("PTY resize: {e}"); }
        }
        let screen = term.parser.screen();
        let (rect, _) = ui.allocate_exact_size(available, Sense::hover());
        let response = ui.interact(rect, egui::Id::new("terminal_canvas"), Sense::click_and_drag());
        // At 100%, no part of the terminal or its titlebar leaks the desktop.
        ui.painter().rect_filled(rect, 0.0,
            Color32::from_rgba_unmultiplied(16, 21, 29, (self.opacity * 255.0) as u8));
        if response.clicked() || response.drag_started() { response.request_focus(); }
        // The focused canvas owns Tab/arrow/Escape: they must reach Zsh,
        // not jump to the session-name text editor in the side panel.
        if ui.memory(|m| m.has_focus(response.id)) {
            ui.memory_mut(|m| m.set_focus_lock_filter(response.id, egui::EventFilter {
                tab: true, horizontal_arrows: true, vertical_arrows: true, escape: true,
            }));
        }
        let cell_at = |p: Pos2| -> (usize, usize) {
            let col = ((p.x - rect.left()) / cw).floor().max(0.0).min(cols as f32 - 1.0) as usize;
            let row = ((p.y - rect.top()) / ch).floor().max(0.0).min(rows as f32 - 1.0) as usize;
            (row,col)
        };
        if response.drag_started() { if let Some(pos) = response.interact_pointer_pos() { let at = cell_at(pos); self.selection = Some((at,at)); } }
        if response.dragged() { if let (Some(pos), Some((start,_))) = (response.interact_pointer_pos(),self.selection) { self.selection = Some((start,cell_at(pos))); } }
        if response.drag_stopped() {
            if let Some((start,end)) = self.selection {
                let (a,b) = if start <= end { (start,end) } else { (end,start) };
                let mut selected = String::new();
                for row in a.0..=b.0 {
                    let first = if row == a.0 { a.1 } else { 0 };
                    let last = if row == b.0 { b.1 } else { cols as usize - 1 };
                    for col in first..=last {
                        if let Some(cell) = screen.cell(row as u16,col as u16) {
                            selected.push_str(if cell.contents().is_empty() { " " } else { cell.contents() });
                        }
                    }
                    if row != b.0 { selected.push('\n'); }
                }
                if !selected.trim().is_empty() { ui.ctx().copy_text(selected); }
            }
        }
        let selected_range = self.selection.map(|(a,b)| if a <= b {(a,b)} else {(b,a)});
        for row in 0..rows {
            for col in 0..cols {
                let Some(cell) = screen.cell(row,col) else { continue; };
                let pos = Pos2::new(rect.left()+col as f32*cw, rect.top()+row as f32*ch);
                let selected = selected_range.is_some_and(|(a,b)| (row as usize,col as usize)>=a && (row as usize,col as usize)<=b);
                let bg = if selected { Some(Color32::from_rgb(58,82,113)) } else { background(cell.bgcolor()) };
                if let Some(bg) = bg { ui.painter().rect_filled(egui::Rect::from_min_size(pos,Vec2::new(cw,ch)),0.0,bg); }
                if !cell.contents().is_empty() {
                    ui.painter().text(pos,egui::Align2::LEFT_TOP,cell.contents(),font.clone(),foreground(cell.fgcolor()));
                }
            }
        }
        // VT100 decides cursor coordinates/visibility; renderer supplies its shape and blink.
        // Respect DECTCEM (programs such as vim may hide the cursor themselves).
        if !screen.hide_cursor() {
            let visible = !self.cursor_blink || (SystemTime::now()
                .duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() / 550) % 2 == 0;
            if visible {
                let (cursor_row, cursor_col) = screen.cursor_position();
                if cursor_row < rows && cursor_col < cols {
                    let x = rect.left() + cursor_col as f32 * cw;
                    let y = rect.top() + cursor_row as f32 * ch;
                    let cursor_color = Color32::from_rgb(237, 198, 128);
                    let cursor_rect = match self.cursor_style {
                        0 => egui::Rect::from_min_size(Pos2::new(x,y),Vec2::new(cw,ch)),
                        2 => egui::Rect::from_min_size(Pos2::new(x,y+ch-2.5),Vec2::new(cw,2.5)),
                        _ => egui::Rect::from_min_size(Pos2::new(x,y),Vec2::new(2.2,ch)),
                    };
                    if self.cursor_style == 0 {
                        ui.painter().rect_filled(cursor_rect,1.0,cursor_color.gamma_multiply(0.48));
                        ui.painter().rect_stroke(cursor_rect,1.0,egui::Stroke::new(1.0,cursor_color),egui::StrokeKind::Inside);
                    } else {
                        ui.painter().rect_filled(cursor_rect,1.0,cursor_color);
                    }
                }
            }
        }
    }
}

fn palette_color(i: u8) -> Color32 {
    const COLORS: [(u8,u8,u8);16] = [(30,32,40),(224,99,110),(128,206,145),(236,190,110),(119,160,236),(205,145,220),(112,210,213),(220,226,233),(106,116,132),(253,132,139),(159,228,169),(255,215,142),(154,185,255),(230,174,239),(147,233,235),(249,251,255)];
    if i < 16 { let (r,g,b) = COLORS[i as usize]; return Color32::from_rgb(r,g,b); }
    if i >= 232 { let g = 8 + (i-232)*10; return Color32::from_gray(g); }
    let n = i-16;
    let part = |x:u8| if x==0 {0} else {55+x*40};
    Color32::from_rgb(part(n/36),part((n/6)%6),part(n%6))
}
fn foreground(color: vt100::Color) -> Color32 { match color { vt100::Color::Default => Color32::from_rgb(215,226,236),vt100::Color::Idx(i)=>palette_color(i),vt100::Color::Rgb(r,g,b)=>Color32::from_rgb(r,g,b) } }
fn background(color: vt100::Color) -> Option<Color32> { match color { vt100::Color::Default => None,vt100::Color::Idx(i)=>Some(palette_color(i)),vt100::Color::Rgb(r,g,b)=>Some(Color32::from_rgb(r,g,b)) } }

impl eframe::App for App {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        [16.0 / 255.0, 21.0 / 255.0, 29.0 / 255.0, 1.0]
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.drain();
        if let Some(rx) = &self.backup_result {
            if let Ok(result) = rx.try_recv() {
                self.backup_status = match result { Ok(v) | Err(v) => v };
                self.backup_result = None;
            }
        }
        self.global_shortcuts(ctx);
        // A compact toolbar remains available when the sidebar is collapsed.
        egui::TopBottomPanel::top("toolbar")
            .frame(egui::Frame::new().fill(Color32::from_rgb(25, 31, 41))
                .inner_margin(egui::Margin::symmetric(12, 7)))
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    let toggle = if self.sidebar_visible { "◧  Ocultar panel" } else { "◨  Sesiones" };
                    if ui.button(toggle).on_hover_text("⌘B").clicked() {
                        self.sidebar_visible = !self.sidebar_visible;
                        if let Err(e) = self.store.set_preference("sidebar_visible", self.sidebar_visible.to_string()) { self.error = e.to_string(); }
                    }
                    ui.separator();
                    if let Some(active) = &self.active {
                        ui.strong(active);
                    } else {
                        ui.label("Sin sesión activa");
                    }
                    ui.separator();
                    ui.small("⌘1–9  sesiones  ·  ⌘K  acciones");
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.button("⚙ Preferencias").on_hover_text("⌘,").clicked() { self.preferences_open = true; }
                        if ui.button("⚡ Acciones").clicked() { self.palette = true; }
                    });
                });
            });
        if self.sidebar_visible {
            egui::SidePanel::left("sessions").resizable(true).default_width(235.0)
                .min_width(175.0).show(ctx, |ui| {
                ui.add_space(8.0);
                ui.heading("Sesiones");
                ui.label(egui::RichText::new("ESPACIOS DE TRABAJO").small().color(Color32::from_gray(145)));
                ui.add_space(6.0);
                ui.horizontal(|ui| {
                    let input = ui.add_sized([ui.available_width() - 39.0, 26.0], egui::TextEdit::singleline(&mut self.new_id).hint_text("Nueva sesión…"));
                    if ui.add_sized([29.0,26.0], egui::Button::new("+")).on_hover_text("Crear sesión").clicked() { self.add(); }
                    if input.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) && !self.new_id.is_empty() { self.add(); }
                });
                ui.add_space(8.0);
                egui::ScrollArea::vertical().max_height(ui.available_height().max(150.0) * 0.58).show(ui,|ui| {
                    let records = self.records.clone();
                    for (index,r) in records.into_iter().enumerate() {
                        let selected = self.active.as_deref()==Some(r.id.as_str());
                        ui.horizontal(|ui| {
                            let title = if index < 9 { format!("{}  {}", index+1, r.id) } else { format!("·  {}",r.id) };
                            let label = if r.closed { format!("○ {title}") } else { format!("● {title}") };
                            let btn = egui::Button::new(egui::RichText::new(label).color(
                                if r.closed { Color32::from_gray(155) } else { Color32::from_rgb(220,231,243) }))
                                .selected(selected).min_size(Vec2::new((ui.available_width()-33.0).max(90.0),28.0));
                            if ui.add(btn).on_hover_text(format!("⌘{} · {}",index+1,r.cwd)).clicked() {
                                self.open(&r.id);
                                ctx.memory_mut(|m| m.request_focus(egui::Id::new("terminal_canvas")));
                            }
                            if !r.closed && ui.small_button("×").on_hover_text("Archivar sesión (conservar historial)").clicked() { self.close(&r.id); }
                        });
                    }
                });
                if !self.error.is_empty() {
                    ui.separator();
                    ui.colored_label(Color32::LIGHT_RED,&self.error);
                    if ui.button("Descartar aviso").clicked() { self.error.clear(); }
                }
            });
        }
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(Color32::from_rgb(16, 21, 29))
                .inner_margin(egui::Margin::symmetric(10,6)))
            .show(ctx, |ui| { self.paint_terminal(ui); });
        if self.preferences_open {
            let mut open = self.preferences_open;
            egui::Window::new("Preferencias")
                .id(egui::Id::new("nia_preferences"))
                .open(&mut open)
                .collapsible(false)
                .resizable(false)
                .default_width(380.0)
                .show(ctx, |ui| {
                    ui.horizontal(|ui| {
                        ui.selectable_value(&mut self.preferences_section, 0, "Apariencia");
                        ui.selectable_value(&mut self.preferences_section, 1, "Backup");
                    });
                    ui.separator();
                    if self.preferences_section == 1 {
                        ui.heading("Backup externo · SFTP");
                        ui.small("Nia utiliza restic y SSH. La clave de cifrado no se guarda en Preferencias.");
                        ui.add_space(8.0);
                        ui.label("Servidor SSH (nombre o IP)");
                        ui.text_edit_singleline(&mut self.backup_config.server);
                        ui.label("Usuario SSH");
                        ui.text_edit_singleline(&mut self.backup_config.user);
                        ui.label("Directorio remoto absoluto");
                        ui.text_edit_singleline(&mut self.backup_config.remote_path);
                        ui.label("Archivo local con la contraseña de restic (ruta absoluta)");
                        ui.text_edit_singleline(&mut self.backup_config.password_file);
                        ui.small("Usa permisos 0600, y guarda la contraseña también fuera de tus Macs.");
                        if ui.button("Guardar configuración").clicked() {
                            self.backup_status = match self.backup_config.save() {
                                Ok(()) => "Configuración guardada".into(),
                                Err(e) => e.to_string(),
                            };
                        }
                        let busy = self.backup_result.is_some();
                        ui.add_enabled_ui(!busy, |ui| {
                            ui.horizontal_wrapped(|ui| {
                                if ui.button("Inicializar repositorio nuevo").clicked() { self.start_backup_task("init"); }
                                if ui.button("Crear copia").clicked() { self.start_backup_task("backup"); }
                                if ui.button("Ver snapshots").clicked() { self.start_backup_task("snapshots"); }
                                if ui.button("Verificar integridad").clicked() { self.start_backup_task("check"); }
                            });
                            ui.separator();
                            ui.label("Restaurar en directorio vacío (no sobrescribe datos de Nia)");
                            ui.text_edit_singleline(&mut self.restore_destination);
                            if ui.button("Restaurar copia").clicked() { self.start_backup_task("restore"); }
                        });
                        if !self.backup_status.is_empty() { ui.label(&self.backup_status); }
                        ui.small("La conexión SSH requiere acceso con llave o agente SSH ya configurado.");
                        return;
                    }
                    ui.heading("Apariencia");
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        ui.label("Opacidad de la ventana");
                        ui.add_space(8.0);
                        ui.label(format!("{} %", (self.opacity * 100.0).round() as u32));
                    });
                    ui.label(egui::RichText::new("Temporalmente desactivada: la barra de título macOS debe permanecer opaca.").small().color(Color32::from_gray(150)));
                    ui.add_enabled(false, egui::Slider::new(&mut self.opacity, 1.0..=1.0).show_value(false));
                    ui.add_space(12.0);
                    ui.separator();
                    ui.add_space(6.0);
                    ui.label("Estilo del cursor");
                    let old_cursor_style = self.cursor_style;
                    egui::ComboBox::from_id_salt("cursor_style")
                        .selected_text(match self.cursor_style {
                            0 => "Bloque", 2 => "Subrayado", _ => "Barra",
                        })
                        .show_ui(ui, |ui| {
                            ui.selectable_value(&mut self.cursor_style, 0, "Bloque");
                            ui.selectable_value(&mut self.cursor_style, 1, "Barra");
                            ui.selectable_value(&mut self.cursor_style, 2, "Subrayado");
                        });
                    if self.cursor_style != old_cursor_style {
                        if let Err(e) = self.store.set_preference("cursor_style", self.cursor_style.to_string()) {
                            self.error = e.to_string();
                        }
                    }
                    if ui.checkbox(&mut self.cursor_blink, "Cursor parpadeante").changed() {
                        if let Err(e) = self.store.set_preference("cursor_blink", self.cursor_blink.to_string()) {
                            self.error = e.to_string();
                        }
                    }
                    ui.add_space(8.0);
                    ui.small("⌘, para abrir o cerrar estas preferencias.");
                });
            self.preferences_open = open;
        }
        if self.palette {
            egui::Window::new("Quick Actions").collapsible(false).show(ctx,|ui| {
                if ui.button("Cerrar").clicked() { self.palette = false; }
                for a in &self.actions {
                    if ui.button(&a.name).clicked() { self.pending_action = Some(a.clone()); self.palette = false; }
                }
                if self.actions.is_empty() { ui.label("Configura actions.toml para añadir acciones."); }
            });
        }
        if let Some(action) = self.pending_action.clone() {
            egui::Window::new("Ejecutar acción").collapsible(false).show(ctx,|ui| {
                ui.label(&action.name); ui.code(&action.command);
                if action.confirm { ui.colored_label(Color32::YELLOW,"Revisa el comando antes de ejecutarlo."); }
                if ui.button("Ejecutar").clicked() {
                    if actions::valid_command(&action.command) {
                        if let Some(id) = &action.session { if self.active.as_deref()!=Some(id) { self.open(id); } }
                        self.send_active(format!("{}\r",action.command).as_bytes());
                    }
                    self.pending_action = None;
                }
                if ui.button("Cancelar").clicked() { self.pending_action=None; }
            });
        }
        // Poll PTYs at 30 Hz in this experimental build. This must become event-driven.
        ctx.request_repaint_after(Duration::from_millis(33)); // PTY polling; cursor blink is derived from wall clock.
        // A focused terminal is intentionally a keyboard target. The previous
        // wants_keyboard_input guard incorrectly swallowed Tab and other keys.
        // Only the terminal canvas (or the empty UI) receives raw PTY input.
        let terminal_focused = ctx.memory(|m| m.focused())
            .is_some_and(|id| id == egui::Id::new("terminal_canvas"));
        if terminal_focused || !ctx.wants_keyboard_input() {
            self.keyboard(ctx);
        }
    }
}

fn main() -> eframe::Result {
    let app = App::new().expect("Cannot open session store");
    let opts = eframe::NativeOptions {
        renderer: eframe::Renderer::Wgpu,
        viewport: egui::ViewportBuilder::default()
            .with_title("Nia Terminal")
            .with_inner_size([1100.0, 680.0])
            .with_transparent(false)
            .with_decorations(true),
        ..Default::default()
    };
    eframe::run_native("Nia Terminal",opts,Box::new(move |_cc| Ok(Box::new(app))))
}
