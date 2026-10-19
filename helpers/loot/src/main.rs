// skyrimmt-loot — LOOT sorting for SkyrimMT as a separate GPL-3 program (libloot is GPL-3; SkyrimMT talks to it over
// JSON on stdout, PLAN §8.6 / ADR-002 option A). It never writes plugins.txt: SkyrimMT applies the order itself so the
// player's active/inactive choices are kept.
//
//   skyrimmt-loot sort --game <game folder> --local <folder with plugins.txt> --masterlist <masterlist.yaml>
//                      [--prelude <prelude.yaml>] [--userlist <userlist.yaml>]
//   → {"sorted": [...], "plugins": {"Name.esp": [{"type": "warn", "text": "..."}]}, "general": [...], "seconds": n}
use libloot::metadata::MessageType;
use libloot::{EvalMode, Game, GameType, MergeMode};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

fn arg(args: &[String], name: &str) -> Option<PathBuf> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(PathBuf::from)
}

fn fail(msg: String) -> ! {
    println!("{}", json!({ "error": msg }));
    std::process::exit(1)
}

fn kind(t: MessageType) -> &'static str {
    match t {
        MessageType::Say => "say",
        MessageType::Warn => "warn",
        MessageType::Error => "error",
        #[allow(unreachable_patterns)]
        _ => "say",
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) != Some("sort") {
        fail("usage: skyrimmt-loot sort --game <dir> --local <dir> --masterlist <file> [--prelude <file>] [--userlist <file>]".into());
    }
    let t0 = Instant::now();
    let game_dir = arg(&args, "--game").unwrap_or_else(|| fail("--game missing".into()));
    let local_dir = arg(&args, "--local").unwrap_or_else(|| fail("--local missing".into()));
    let masterlist = arg(&args, "--masterlist").unwrap_or_else(|| fail("--masterlist missing".into()));

    let mut game = Game::with_local_path(GameType::SkyrimSE, &game_dir, &local_dir)
        .unwrap_or_else(|e| fail(format!("game: {e}")));
    {
        let db = game.database();
        let mut db = db.write().unwrap_or_else(|_| fail("database lock".into()));
        let r = match arg(&args, "--prelude") {
            Some(p) if p.exists() => db.load_masterlist_with_prelude(&masterlist, &p),
            _ => db.load_masterlist(&masterlist),
        };
        r.unwrap_or_else(|e| fail(format!("masterlist: {e}")));
        if let Some(u) = arg(&args, "--userlist") {
            if u.exists() {
                db.load_userlist(&u).unwrap_or_else(|e| fail(format!("userlist: {e}")));
            }
        }
    }
    game.load_current_load_order_state().unwrap_or_else(|e| fail(format!("load order: {e}")));
    let names: Vec<String> = game.load_order().iter().map(|s| s.to_string()).collect();
    let data = game_dir.join("Data");
    let paths: Vec<PathBuf> = names.iter().map(|n| data.join(n)).filter(|p| p.exists()).collect();
    let refs: Vec<&Path> = paths.iter().map(PathBuf::as_path).collect();
    game.load_plugins(&refs).unwrap_or_else(|e| fail(format!("plugins: {e}")));
    let name_refs: Vec<&str> = names.iter().map(String::as_str).collect();
    let sorted = game.sort_plugins(&name_refs).unwrap_or_else(|e| fail(format!("sort: {e}")));

    // messages: per plugin (masterlist + userlist, conditions evaluated) and general
    let db = game.database();
    let db = db.read().unwrap_or_else(|_| fail("database lock".into()));
    let mut plugins = Map::new();
    let mut dirty = Map::new();   // plugin → cleaning data for THIS file (evaluation keeps only matching CRCs)
    let mut seen: HashMap<String, ()> = HashMap::new();
    for n in &sorted {
        if seen.insert(n.to_lowercase(), ()).is_some() { continue; }
        if let Ok(Some(meta)) = db.plugin_metadata(n, MergeMode::WithUserMetadata, EvalMode::Evaluate) {
            let mut msgs: Vec<Value> = meta.messages().iter()
                .filter_map(|m| m.content().first().map(|c| json!({ "type": kind(m.message_type()), "text": c.text() })))
                .collect();
            if let Some(d) = meta.dirty_info().first() {
                dirty.insert(n.clone(), json!({ "crc": format!("{:08X}", d.crc()), "itm": d.itm_count(), "udr": d.deleted_reference_count(),
                                                "nav": d.deleted_navmesh_count(), "utility": d.cleaning_utility() }));
            }
            if !meta.dirty_info().is_empty() {
                msgs.push(json!({ "type": "warn", "text": "Dirty plugin: LOOT recommends cleaning it with SSEEdit (Quick Auto Clean)." }));
            }
            if !msgs.is_empty() { plugins.insert(n.clone(), Value::Array(msgs)); }
        }
    }
    let general: Vec<Value> = db.general_messages(MergeMode::WithUserMetadata, EvalMode::Evaluate)
        .map(|v| v.iter().filter_map(|m| m.content().first().map(|c| json!({ "type": kind(m.message_type()), "text": c.text() }))).collect())
        .unwrap_or_default();
    println!("{}", json!({ "sorted": sorted, "plugins": plugins, "dirty": dirty, "general": general, "seconds": t0.elapsed().as_secs_f64() }));
}
