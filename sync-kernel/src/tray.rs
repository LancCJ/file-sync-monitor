use tauri::{
    menu::{Menu, MenuItem},
    tray::{TrayIconBuilder, TrayIconEvent},
    Runtime, Manager, Emitter,
};

pub fn setup_system_tray<R: Runtime>(app: &tauri::AppHandle<R>) -> Result<(), tauri::Error> {
    let show_item = MenuItem::with_id(app, "show", "打开主窗口", true, None::<&str>)?;
    let sync_item = MenuItem::with_id(app, "sync_all", "立即同步所有目录", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "退出应用", true, None::<&str>)?;
    
    let menu = Menu::with_items(app, &[&show_item, &sync_item, &quit_item])?;

    let icon_bytes = include_bytes!("../icons/AppMenuBarIcon.png");
    let tray_icon = tauri::image::Image::from_bytes(icon_bytes).expect("Failed to load AppMenuBarIcon");

    let _tray = TrayIconBuilder::new()
        .tooltip("FileSyncMonitor")
        .icon(tray_icon)
        .icon_as_template(true)
        .menu(&menu)
        .on_menu_event(|app, event| {
            match event.id.as_ref() {
                "show" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
                "sync_all" => {
                    // Emit a global event to the frontend to trigger sync
                    let _ = app.emit("trigger-sync-all", ());
                }
                "quit" => {
                    app.exit(0);
                }
                _ => {}
            }
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { id: _, .. } = event {
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    let visible = window.is_visible().unwrap_or(false);
                    if visible {
                        let _ = window.hide();
                    } else {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
            }
        })
        .build(app)?;

    Ok(())
}
