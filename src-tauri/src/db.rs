use rusqlite::{params, Connection, Result};
use std::path::Path;
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEvent {
    pub id: String,
    pub path: String,
    pub old_path: Option<String>,
    pub event_type: String, // Stored as "type" in SwiftData: created, modified, deleted, renamed
    pub timestamp: f64,
    pub is_synced: bool,
    pub has_notified: bool,
}

pub fn init_db<P: AsRef<Path>>(db_path: P) -> Result<Connection> {
    let conn = Connection::open(db_path)?;
    
    // Create File Events Table
    conn.execute(
        "CREATE TABLE IF NOT EXISTS file_events (
            id TEXT PRIMARY KEY NOT NULL,
            path TEXT NOT NULL,
            old_path TEXT,
            type TEXT NOT NULL,
            timestamp REAL NOT NULL,
            is_synced INTEGER NOT NULL DEFAULT 0,
            has_notified INTEGER NOT NULL DEFAULT 0
        );",
        [],
    )?;

    // Create App Config Table
    conn.execute(
        "CREATE TABLE IF NOT EXISTS app_config (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );",
        [],
    )?;

    Ok(conn)
}

pub fn insert_event(conn: &Connection, event: &FileEvent) -> Result<()> {
    conn.execute(
        "INSERT INTO file_events (id, path, old_path, type, timestamp, is_synced, has_notified)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            event.id,
            event.path,
            event.old_path,
            event.event_type,
            event.timestamp,
            if event.is_synced { 1 } else { 0 },
            if event.has_notified { 1 } else { 0 }
        ],
    )?;
    Ok(())
}

pub fn get_all_events(conn: &Connection) -> Result<Vec<FileEvent>> {
    let mut stmt = conn.prepare(
        "SELECT id, path, old_path, type, timestamp, is_synced, has_notified FROM file_events ORDER BY timestamp DESC"
    )?;
    let event_iter = stmt.query_map([], |row| {
        Ok(FileEvent {
            id: row.get(0)?,
            path: row.get(1)?,
            old_path: row.get(2)?,
            event_type: row.get(3)?,
            timestamp: row.get(4)?,
            is_synced: row.get::<_, i32>(5)? != 0,
            has_notified: row.get::<_, i32>(6)? != 0,
        })
    })?;

    let mut events = Vec::new();
    for event in event_iter {
        events.push(event?);
    }
    Ok(events)
}

pub fn get_pending_events(conn: &Connection) -> Result<Vec<FileEvent>> {
    let mut stmt = conn.prepare(
        "SELECT id, path, old_path, type, timestamp, is_synced, has_notified FROM file_events WHERE is_synced = 0 ORDER BY timestamp DESC"
    )?;
    let event_iter = stmt.query_map([], |row| {
        Ok(FileEvent {
            id: row.get(0)?,
            path: row.get(1)?,
            old_path: row.get(2)?,
            event_type: row.get(3)?,
            timestamp: row.get(4)?,
            is_synced: row.get::<_, i32>(5)? != 0,
            has_notified: row.get::<_, i32>(6)? != 0,
        })
    })?;

    let mut events = Vec::new();
    for event in event_iter {
        events.push(event?);
    }
    Ok(events)
}

pub fn mark_event_synced(conn: &Connection, id: &str) -> Result<()> {
    conn.execute(
        "UPDATE file_events SET is_synced = 1 WHERE id = ?1",
        params![id],
    )?;
    Ok(())
}

pub fn clear_all_events(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM file_events", [])?;
    Ok(())
}

pub fn save_config(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO app_config (key, value) VALUES (?1, ?2)",
        params![key, value],
    )?;
    Ok(())
}

pub fn get_config(conn: &Connection, key: &str) -> Result<Option<String>> {
    let mut stmt = conn.prepare("SELECT value FROM app_config WHERE key = ?1")?;
    let mut rows = stmt.query(params![key])?;
    if let Some(row) = rows.next()? {
        let value: String = row.get(0)?;
        Ok(Some(value))
    } else {
        Ok(None)
    }
}
