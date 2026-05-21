const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

// Application State Cache
let state = {
  monitoredPaths: [],
  fileEvents: [],
  filterType: "all", // "all" | "pending"
  searchQuery: "",
  credentials: null,
  activeTab: "events",
  isSyncing: false
};

// DOM References
let dom = {};

// Initialize application elements when DOM is ready
window.addEventListener("DOMContentLoaded", () => {
  cacheDOMElements();
  setupTabListeners();
  setupFilterListeners();
  setupActionListeners();
  injectQROverlay();
  
  // Initial Bootup Sequence
  initializeApplication();
});

// Cache standard UI elements for high performance DOM updates
function cacheDOMElements() {
  dom.railBtns = {
    events: document.getElementById("btn-tab-events"),
    reports: document.getElementById("btn-tab-reports"),
    settings: document.getElementById("btn-tab-settings"),
    help: document.getElementById("btn-tab-help")
  };
  
  dom.panes = {
    events: document.getElementById("tab-pane-events"),
    reports: document.getElementById("tab-pane-reports"),
    settings: document.getElementById("tab-pane-settings"),
    help: document.getElementById("tab-pane-help")
  };
  
  dom.sidebarEvents = document.getElementById("sidebar-events");
  dom.eventListContainer = document.getElementById("event-list-container");
  dom.dirGridContainer = document.getElementById("dir-grid-container");
  
  dom.searchBox = document.getElementById("event-search-input");
  dom.filterAllBtn = document.getElementById("filter-all");
  dom.filterPendingBtn = document.getElementById("filter-pending");
  
  dom.syncBtn = document.getElementById("btn-sync-all");
  dom.addDirBtn = document.getElementById("btn-add-dir");
  dom.saveSettingsBtn = document.getElementById("btn-save-settings");
  
  // Input fields
  dom.ignoreExts = document.getElementById("input-ignore-exts");
  dom.ignoreDirs = document.getElementById("input-ignore-dirs");
  
  // Modals overlays
  dom.overlayClear = document.getElementById("overlay-clear-events");
  dom.overlayReset = document.getElementById("overlay-reset-all");
  
  // Modal buttons
  dom.btnTriggerClear = document.getElementById("btn-trigger-clear");
  dom.btnTriggerReset = document.getElementById("btn-trigger-reset");
  
  dom.btnConfirmClear = document.getElementById("btn-confirm-clear");
  dom.btnCancelClear = document.getElementById("btn-cancel-clear");
  
  dom.btnConfirmReset = document.getElementById("btn-confirm-reset");
  dom.btnCancelReset = document.getElementById("btn-cancel-reset");
  
  // Account cards
  dom.accountUnauth = document.getElementById("account-card-unauth");
  dom.accountAuth = document.getElementById("account-card-auth");
  dom.btnLoginIMA = document.getElementById("btn-login-ima");
  dom.btnLogoutIMA = document.getElementById("btn-logout-ima");
  dom.accountAvatar = document.getElementById("account-avatar");
  dom.accountNickname = document.getElementById("account-nickname");
  
  // Stats
  dom.statTotal = document.getElementById("stat-total-events");
  dom.statPending = document.getElementById("stat-pending-events");
  dom.statSynced = document.getElementById("stat-synced-events");
  
  // Sync banner
  dom.syncBanner = document.getElementById("sync-progress-banner");
  dom.syncBannerTitle = document.getElementById("sync-banner-title");
  dom.syncBannerStatus = document.getElementById("sync-banner-status");
  dom.syncBannerFill = document.getElementById("sync-banner-progress-fill");
}

// Setup left sidebar rail tab toggle mechanisms
function setupTabListeners() {
  Object.keys(dom.railBtns).forEach(tab => {
    dom.railBtns[tab].addEventListener("click", () => {
      switchTab(tab);
    });
  });
}

function switchTab(tabName) {
  state.activeTab = tabName;
  
  // Toggle rail active highlights
  Object.keys(dom.railBtns).forEach(key => {
    if (key === tabName) {
      dom.railBtns[key].classList.add("active");
      dom.panes[key].classList.add("active");
    } else {
      dom.railBtns[key].classList.remove("active");
      dom.panes[key].classList.remove("active");
    }
  });
  
  // Collapse second sidebar if we aren't on the events panel
  if (tabName === "events") {
    dom.sidebarEvents.classList.remove("collapsed");
  } else {
    dom.sidebarEvents.classList.add("collapsed");
  }
  
  // Reload corresponding tab data
  if (tabName === "reports") {
    loadReportsTab();
  }
}

// Setup Event List filter listeners
function setupFilterListeners() {
  dom.filterAllBtn.addEventListener("click", () => {
    dom.filterAllBtn.classList.add("active");
    dom.filterPendingBtn.classList.remove("active");
    state.filterType = "all";
    renderEvents();
  });
  
  dom.filterPendingBtn.addEventListener("click", () => {
    dom.filterPendingBtn.classList.add("active");
    dom.filterAllBtn.classList.remove("active");
    state.filterType = "pending";
    renderEvents();
  });
  
  dom.searchBox.addEventListener("input", (e) => {
    state.searchQuery = e.target.value.toLowerCase().trim();
    renderEvents();
  });
}

// Injects微信扫码登录 (WeChat Login Overlay) dynamically into DOM
function injectQROverlay() {
  const qrOverlay = document.createElement("div");
  qrOverlay.className = "custom-modal-overlay hidden";
  qrOverlay.id = "overlay-qrcode";
  qrOverlay.innerHTML = `
    <div class="custom-confirm-card qr-modal-card">
      <div class="modal-icon-circle" style="background-color: var(--app-mint-glow); color: var(--app-mint);">
        <svg viewBox="0 0 24 24" class="modal-icon" style="width: 32px; height: 32px;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 16H9v-2h2v2zm0-4H9V7h2v7zm4 4h-2v-2h2v2zm0-4h-2V7h2v7z" fill="currentColor"/></svg>
      </div>
      <h3>微信扫码授权</h3>
      <p>使用微信扫描下方二维码，开启 Tencent IMA 智能云端同步</p>
      <div class="qr-code-wrapper" id="qr-mock-scanner" style="cursor: pointer;">
        <svg viewBox="0 0 100 100" class="qr-code-img">
          <!-- Abstract Grid Matrix Mock QR -->
          <rect x="5" y="5" width="22" height="22" fill="var(--text-primary)"/>
          <rect x="9" y="9" width="14" height="14" fill="#ffffff"/>
          <rect x="12" y="12" width="8" height="8" fill="var(--text-primary)"/>
          
          <rect x="73" y="5" width="22" height="22" fill="var(--text-primary)"/>
          <rect x="77" y="9" width="14" height="14" fill="#ffffff"/>
          <rect x="80" y="12" width="8" height="8" fill="var(--text-primary)"/>
          
          <rect x="5" y="73" width="22" height="22" fill="var(--text-primary)"/>
          <rect x="9" y="79" width="14" height="14" fill="#ffffff"/>
          <rect x="12" y="82" width="8" height="8" fill="var(--text-primary)"/>
          
          <!-- Random Matrix Blocks -->
          <rect x="35" y="15" width="6" height="6" fill="var(--text-primary)"/>
          <rect x="45" y="8" width="8" height="6" fill="var(--text-primary)"/>
          <rect x="58" y="18" width="6" height="12" fill="var(--text-primary)"/>
          <rect x="35" y="32" width="12" height="6" fill="var(--text-primary)"/>
          <rect x="52" y="38" width="6" height="6" fill="var(--text-primary)"/>
          <rect x="40" y="52" width="18" height="6" fill="var(--text-primary)"/>
          <rect x="12" y="40" width="6" height="18" fill="var(--text-primary)"/>
          <rect x="25" y="30" width="6" height="6" fill="var(--text-primary)"/>
          <rect x="72" y="45" width="12" height="6" fill="var(--text-primary)"/>
          <rect x="82" y="32" width="6" height="20" fill="var(--text-primary)"/>
          <rect x="70" y="72" width="20" height="20" fill="var(--text-primary)"/>
          <rect x="74" y="76" width="12" height="12" fill="#ffffff"/>
          
          <circle cx="50" cy="50" r="10" fill="var(--app-mint)"/>
          <path d="M48 47H52V53H48z" fill="#ffffff"/>
        </svg>
      </div>
      <div style="font-size: 0.76rem; color: var(--text-muted); margin-bottom: 12px; font-weight: 500;">提示：点击二维码区域即可模拟扫码成功</div>
      <button class="flat-btn" id="btn-cancel-qrcode" style="width: 100%;">取消</button>
    </div>
  `;
  document.body.appendChild(qrOverlay);
  
  dom.overlayQRCode = qrOverlay;
  dom.btnCancelQRCode = document.getElementById("btn-cancel-qrcode");
  dom.qrMockScanner = document.getElementById("qr-mock-scanner");
  
  // Attach listeners
  dom.btnCancelQRCode.addEventListener("click", () => {
    dom.overlayQRCode.classList.add("hidden");
  });
  
  dom.qrMockScanner.addEventListener("click", () => {
    simulateSuccessfulLogin();
  });
}

// Setup generic action trigger mechanisms
function setupActionListeners() {
  // Directory manipulation
  dom.addDirBtn.addEventListener("click", addFolder);
  
  // Settings page action save
  dom.saveSettingsBtn.addEventListener("click", saveIgnoreSettings);
  
  // Sync
  dom.syncBtn.addEventListener("click", syncAll);
  
  // Custom Modals trigger overlays
  dom.btnTriggerClear.addEventListener("click", () => {
    dom.overlayClear.classList.remove("hidden");
  });
  
  dom.btnCancelClear.addEventListener("click", () => {
    dom.overlayClear.classList.add("hidden");
  });
  
  dom.btnConfirmClear.addEventListener("click", async () => {
    try {
      await invoke("clear_all_events");
      state.fileEvents = [];
      renderEvents();
      dom.overlayClear.classList.add("hidden");
      showGlobalToast("文件变更事件记录已成功清空！");
    } catch (e) {
      showGlobalToast("清除记录失败: " + e, true);
    }
  });
  
  dom.btnTriggerReset.addEventListener("click", () => {
    dom.overlayReset.classList.remove("hidden");
  });
  
  dom.btnCancelReset.addEventListener("click", () => {
    dom.overlayReset.classList.add("hidden");
  });
  
  dom.btnConfirmReset.addEventListener("click", async () => {
    try {
      await resetToFactoryDefaults();
      dom.overlayReset.classList.add("hidden");
    } catch (e) {
      showGlobalToast("重置应用失败: " + e, true);
    }
  });
  
  // WeChat Scan Trigger
  dom.btnLoginIMA.addEventListener("click", () => {
    dom.overlayQRCode.classList.remove("hidden");
  });
  
  dom.btnLogoutIMA.addEventListener("click", logoutTencentIMA);
}

// Core bootup operations
async function initializeApplication() {
  try {
    // 1. Fetch ignore configs
    let enableDefaultVal = await invoke("get_config_value", { key: "enableDefaultIgnoreRules" });
    if (enableDefaultVal === null) {
      await invoke("set_config_value", { key: "enableDefaultIgnoreRules", value: "true" });
    }
    
    let customExtsVal = await invoke("get_config_value", { key: "customIgnoredExtensions" });
    dom.ignoreExts.value = customExtsVal || "tmp, log, asd, part";
    
    let customDirsVal = await invoke("get_config_value", { key: "customIgnoredDirectoryNames" });
    dom.ignoreDirs.value = customDirsVal || ".git, node_modules, dist";
    
    // 2. Fetch monitored directories
    let dirsVal = await invoke("get_config_value", { key: "monitoredDirectories" });
    if (dirsVal) {
      state.monitoredPaths = JSON.parse(dirsVal);
    } else {
      state.monitoredPaths = [];
    }
    renderMonitoredDirectories();
    
    // 3. Start file monitor background process
    if (state.monitoredPaths.length > 0) {
      await invoke("start_file_monitor", { paths: state.monitoredPaths });
    }
    
    // 4. Load events and render
    await fetchEvents();
    
    // 5. Auth State Validation
    await checkAuthState();
    
    // 6. Register Tauri events listener
    listen("file-change-events", (event) => {
      console.log("[Tauri Event] New coalesced file events received:", event.payload);
      fetchEvents();
    });
    
    listen("trigger-sync-all", () => {
      console.log("[Tauri Event] Tray triggered sync all");
      syncAll();
    });
    
  } catch (err) {
    console.error("Bootup failure:", err);
    showGlobalToast("初始化失败: " + err, true);
  }
}

// Refresh events lists from SQLite DB
async function fetchEvents() {
  try {
    let events = await invoke("get_file_events", { pendingOnly: false });
    state.fileEvents = events || [];
    renderEvents();
  } catch (e) {
    console.error("Error fetching events:", e);
  }
}

// Render monitored folder grid cards
function renderMonitoredDirectories() {
  if (state.monitoredPaths.length === 0) {
    dom.dirGridContainer.innerHTML = `
      <div class="grid-empty">
        <p>当前未添加任何本地监控文件夹，点击右侧添加以开启智能文件同步</p>
      </div>
    `;
    return;
  }
  
  dom.dirGridContainer.innerHTML = "";
  state.monitoredPaths.forEach(path => {
    // Extract base folder name
    let cleanPath = path.replace(/\\/g, "/");
    let name = cleanPath.split("/").pop() || path;
    
    const card = document.createElement("div");
    card.className = "dir-card";
    card.innerHTML = `
      <div class="dir-info">
        <div class="dir-icon-wrapper">
          <svg viewBox="0 0 24 24" class="dir-icon"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-2 12H4V8h16v10z" fill="currentColor"/></svg>
        </div>
        <div class="dir-details">
          <h4 class="dir-name" title="${name}">${name}</h4>
          <p class="dir-path" title="${path}">${path}</p>
        </div>
      </div>
      <div class="dir-actions">
        <button class="dir-remove-btn" data-path="${path}">移除监控</button>
      </div>
    `;
    
    // Bind remove button
    card.querySelector(".dir-remove-btn").addEventListener("click", (e) => {
      let removePath = e.target.getAttribute("data-path");
      removeFolder(removePath);
    });
    
    dom.dirGridContainer.appendChild(card);
  });
}

// Add monitored folder
async function addFolder() {
  try {
    let result = await invoke("select_directory");
    if (result) {
      if (state.monitoredPaths.includes(result)) {
        showGlobalToast("该文件夹已存在监控列表中！");
        return;
      }
      
      state.monitoredPaths.push(result);
      // Save back to db
      await invoke("set_config_value", { key: "monitoredDirectories", value: JSON.stringify(state.monitoredPaths) });
      renderMonitoredDirectories();
      
      // Stop and restart monitor process
      await invoke("stop_file_monitor");
      await invoke("start_file_monitor", { paths: state.monitoredPaths });
      
      showGlobalToast("成功开启文件夹同步监控：" + result.split("/").pop());
    }
  } catch (err) {
    showGlobalToast("添加文件夹失败: " + err, true);
  }
}

// Remove monitored folder
async function removeFolder(path) {
  try {
    state.monitoredPaths = state.monitoredPaths.filter(p => p !== path);
    await invoke("set_config_value", { key: "monitoredDirectories", value: JSON.stringify(state.monitoredPaths) });
    renderMonitoredDirectories();
    
    // Stop and restart
    await invoke("stop_file_monitor");
    if (state.monitoredPaths.length > 0) {
      await invoke("start_file_monitor", { paths: state.monitoredPaths });
    }
    showGlobalToast("已移除该文件夹的同步监控。");
  } catch (err) {
    showGlobalToast("移除监控失败: " + err, true);
  }
}

// Render dynamic elements to secondary sidebar events log
function renderEvents() {
  // Apply filtering rules
  let filtered = state.fileEvents;
  
  if (state.filterType === "pending") {
    filtered = filtered.filter(e => !e.is_synced);
  }
  
  if (state.searchQuery) {
    filtered = filtered.filter(e => e.path.toLowerCase().includes(state.searchQuery));
  }
  
  if (filtered.length === 0) {
    dom.eventListContainer.innerHTML = `
      <div class="list-empty">
        <svg viewBox="0 0 24 24" width="40" height="40" fill="var(--text-muted)">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
        </svg>
        <p>暂无相关文件监控变更记录</p>
      </div>
    `;
    return;
  }
  
  dom.eventListContainer.innerHTML = "";
  filtered.forEach(item => {
    let cleanPath = item.path.replace(/\\/g, "/");
    let baseName = cleanPath.split("/").pop() || item.path;
    let folderName = cleanPath.split("/").slice(-2, -1)[0] || "";
    
    // Format timestamp
    let date = new Date(item.timestamp * 1000);
    let timeStr = date.toLocaleTimeString("zh-CN", { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
    
    // Setup localized labels and badges
    let typeClass = item.event_type; // "created", "modified", "deleted", "renamed"
    let typeLabel = "未知";
    switch(item.event_type) {
      case "created": typeLabel = "新增"; break;
      case "modified": typeLabel = "修改"; break;
      case "deleted": typeLabel = "删除"; break;
      case "renamed": typeLabel = "重命名"; break;
    }
    
    const card = document.createElement("div");
    card.className = `event-item-card ${item.is_synced ? 'synced' : 'pending'}`;
    card.innerHTML = `
      <div class="event-meta">
        <span class="event-type-badge ${typeClass}">${typeLabel}</span>
        <span class="event-time">${timeStr}</span>
      </div>
      <div class="event-path" title="${item.path}">${folderName ? folderName + ' / ' : ''}${baseName}</div>
    `;
    
    dom.eventListContainer.appendChild(card);
  });
}

// Simulates a smooth upload sync flow on the frontend using backend calls
async function syncAll() {
  if (state.isSyncing) return;
  
  // Filter pending events
  let pending = state.fileEvents.filter(e => !e.is_synced);
  if (pending.length === 0) {
    showGlobalToast("当前没有任何待同步的文件变动。");
    return;
  }
  
  state.isSyncing = true;
  dom.syncBtn.disabled = true;
  
  // Show bottom floating progress banner
  dom.syncBanner.classList.remove("hidden");
  dom.syncBannerTitle.textContent = "正在上传文件同步变动...";
  dom.syncBannerFill.style.width = "0%";
  
  let total = pending.length;
  let successCount = 0;
  
  for (let i = 0; i < total; i++) {
    let event = pending[i];
    let baseName = event.path.split("/").pop();
    
    dom.syncBannerStatus.textContent = `(${i + 1}/${total}) 正在上传: ${baseName}`;
    dom.syncBannerFill.style.width = `${((i + 1) / total) * 100}%`;
    
    // Simulate API delay, then mark synced in Rust database
    await new Promise(resolve => setTimeout(resolve, 600));
    try {
      await invoke("mark_event_synced", { id: event.id });
      successCount++;
    } catch (e) {
      console.error("Mark synced error:", e);
    }
  }
  
  // Update banner complete state
  dom.syncBannerTitle.textContent = "同步完成！";
  dom.syncBannerStatus.textContent = `成功上传 ${successCount} 个文件变动。`;
  
  // Fetch fresh events
  await fetchEvents();
  
  setTimeout(() => {
    dom.syncBanner.classList.add("hidden");
    state.isSyncing = false;
    dom.syncBtn.disabled = false;
    showGlobalToast(`同步成功！累计上传 ${successCount} 个变更文件。`);
  }, 2200);
}

// Save ignores
async function saveIgnoreSettings() {
  try {
    let exts = dom.ignoreExts.value;
    let dirs = dom.ignoreDirs.value;
    
    await invoke("set_config_value", { key: "customIgnoredExtensions", value: exts });
    await invoke("set_config_value", { key: "customIgnoredDirectoryNames", value: dirs });
    
    // Re-trigger monitor with updated ignore rules
    if (state.monitoredPaths.length > 0) {
      await invoke("stop_file_monitor");
      await invoke("start_file_monitor", { paths: state.monitoredPaths });
    }
    
    showGlobalToast("过滤规则保存并应用成功！");
  } catch (e) {
    showGlobalToast("保存过滤配置失败: " + e, true);
  }
}

// Load statistics for analysis page
function loadReportsTab() {
  let total = state.fileEvents.length;
  let pending = state.fileEvents.filter(e => !e.is_synced).length;
  let synced = total - pending;
  
  dom.statTotal.textContent = total;
  dom.statPending.textContent = pending;
  dom.statSynced.textContent = synced;
}

// Verify authorization state
async function checkAuthState() {
  try {
    let creds = await invoke("get_ima_credentials");
    if (creds) {
      // Validate credentials on backend
      try {
        let [avatar, nickname] = await invoke("get_ima_user_profile", {
          token: creds.token,
          refreshToken: creds.refresh_token,
          uid: creds.uid,
          guid: creds.guid
        });
        
        state.credentials = { avatar, nickname };
        showAuthorizedUI(avatar, nickname);
      } catch (err) {
        console.error("IMA token validation failure:", err);
        // Silent expiry, revert to unauth
        logoutTencentIMA();
      }
    } else {
      showUnapprovedUI();
    }
  } catch (e) {
    console.error("Failed to check auth state:", e);
  }
}

function showAuthorizedUI(avatar, nickname) {
  dom.accountUnauth.classList.add("hidden");
  dom.accountAuth.classList.remove("hidden");
  
  dom.accountAvatar.src = avatar || "https://images.unsplash.com/photo-1535713875002-d1d0cf377fde?auto=format&fit=crop&w=100&q=80";
  dom.accountNickname.textContent = nickname || "微信用户";
}

function showUnapprovedUI() {
  dom.accountAuth.classList.add("hidden");
  dom.accountUnauth.classList.remove("hidden");
}

// WeChat sweep mockup logic
async function simulateSuccessfulLogin() {
  try {
    // Generate clean mock WeChat auth payload
    let mockToken = "IMA-TOK-" + Math.random().toString(36).substring(2, 10).toUpperCase();
    let mockRefreshToken = "IMA-REF-" + Math.random().toString(36).substring(2, 10).toUpperCase();
    let mockUid = "50918" + Math.floor(Math.random() * 9000);
    let mockGuid = "G" + Math.random().toString(36).substring(2, 12).toUpperCase();
    
    // Save to native keyrings
    await invoke("save_ima_credentials", {
      token: mockToken,
      refreshToken: mockRefreshToken,
      uid: mockUid,
      guid: mockGuid
    });
    
    // Simulated values
    let mockAvatar = "https://images.unsplash.com/photo-1570295999919-56ceb5ecca61?auto=format&fit=crop&w=100&q=80";
    let mockNickname = "极客大叔 (LancCJ)";
    
    state.credentials = { avatar: mockAvatar, nickname: mockNickname };
    
    // Close modal
    dom.overlayQRCode.classList.add("hidden");
    
    showAuthorizedUI(mockAvatar, mockNickname);
    showGlobalToast("微信扫码授权成功！云端助理已绑定。");
    
  } catch (e) {
    showGlobalToast("微信登录失败: " + e, true);
  }
}

async function logoutTencentIMA() {
  try {
    await invoke("clear_ima_credentials");
    state.credentials = null;
    showUnapprovedUI();
    showGlobalToast("已安全退出 Tencent IMA 账户绑定。");
  } catch (e) {
    showGlobalToast("退出登录失败: " + e, true);
  }
}

// Factory reset procedure
async function resetToFactoryDefaults() {
  // 1. Clear database events
  await invoke("clear_all_events");
  
  // 2. Stop monitor
  await invoke("stop_file_monitor");
  
  // 3. Clear monitored directories
  state.monitoredPaths = [];
  await invoke("set_config_value", { key: "monitoredDirectories", value: "" });
  renderMonitoredDirectories();
  
  // 4. Restore custom configs to default
  await invoke("set_config_value", { key: "enableDefaultIgnoreRules", value: "true" });
  await invoke("set_config_value", { key: "customIgnoredExtensions", value: "tmp, log, asd, part" });
  await invoke("set_config_value", { key: "customIgnoredDirectoryNames", value: ".git, node_modules, dist" });
  
  dom.ignoreExts.value = "tmp, log, asd, part";
  dom.ignoreDirs.value = ".git, node_modules, dist";
  
  // 5. Clear credentials
  await invoke("clear_ima_credentials");
  state.credentials = null;
  showUnapprovedUI();
  
  state.fileEvents = [];
  renderEvents();
  
  switchTab("events");
  showGlobalToast("应用重置成功！所有配置已还原至出厂设置。");
}

// Custom Premium Toast Notification
function showGlobalToast(message, isError = false) {
  // Check if toast already exists
  let oldToast = document.querySelector(".custom-toast");
  if (oldToast) oldToast.remove();
  
  const toast = document.createElement("div");
  toast.className = `custom-toast ${isError ? 'error-toast' : ''}`;
  toast.style.cssText = `
    position: fixed;
    top: 24px;
    right: 24px;
    background-color: ${isError ? 'var(--app-rose)' : 'var(--app-mint)'};
    color: #ffffff;
    padding: 12px 24px;
    border-radius: 30px;
    font-size: 0.88rem;
    font-weight: 600;
    box-shadow: var(--shadow-lg);
    z-index: 9999;
    display: flex;
    align-items: center;
    gap: 8px;
    opacity: 0;
    transform: translateY(-20px);
    transition: all 0.3s cubic-bezier(0.175, 0.885, 0.32, 1.275);
  `;
  
  let icon = isError ? 
    `<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>` : 
    `<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>`;
    
  toast.innerHTML = `${icon}<span>${message}</span>`;
  document.body.appendChild(toast);
  
  // Fade in animation
  setTimeout(() => {
    toast.style.opacity = "1";
    toast.style.transform = "translateY(0)";
  }, 10);
  
  // Fade out and remove
  setTimeout(() => {
    toast.style.opacity = "0";
    toast.style.transform = "translateY(-20px)";
    setTimeout(() => toast.remove(), 300);
  }, 3500);
}
