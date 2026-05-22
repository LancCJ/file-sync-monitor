const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

import { I18N_DICT } from './i18n.js';

// --- i18n Core Helper Functions ---
function getCurrentLanguage() {
  let lang = localStorage.getItem("appLanguage") || "system";
  if (lang === "system") {
    const navLang = navigator.language.toLowerCase();
    if (navLang.startsWith("zh")) {
      return "zh-Hans";
    } else {
      return "en";
    }
  }
  return lang;
}

function t(key) {
  if (!key) return "";
  const lang = getCurrentLanguage();
  if (lang !== "en") {
    return key;
  }
  if (I18N_DICT[key]) {
    return I18N_DICT[key];
  }
  // Try prefix matching for dynamic strings
  for (const k in I18N_DICT) {
    if (k.endsWith(": ") && key.startsWith(k)) {
      return I18N_DICT[k] + key.slice(k.length);
    }
    if (k.endsWith("：") && key.startsWith(k)) {
      return I18N_DICT[k] + key.slice(k.length);
    }
  }
  return key;
}

function applyTranslations() {
  const lang = getCurrentLanguage();
  document.documentElement.lang = lang.startsWith("zh") ? "zh" : "en";

  document.querySelectorAll("[data-i18n]").forEach(el => {
    const key = el.getAttribute("data-i18n");
    if (key) {
      el.textContent = t(key);
    }
  });

  document.querySelectorAll("[data-i18n-title]").forEach(el => {
    const key = el.getAttribute("data-i18n-title");
    if (key) {
      el.setAttribute("title", t(key));
    }
  });

  document.querySelectorAll("[data-i18n-placeholder]").forEach(el => {
    const key = el.getAttribute("data-i18n-placeholder");
    if (key) {
      el.setAttribute("placeholder", t(key));
    }
  });

  const btnLang = document.getElementById("btn-rail-lang");
  if (btnLang) {
    const span = btnLang.querySelector("span");
    if (span) {
      span.textContent = lang === "en" ? "EN" : "简";
    }
  }
}

function switchLanguage(newLang) {
  localStorage.setItem("appLanguage", newLang);

  const langSelect = document.getElementById("setting-language");
  if (langSelect) {
    langSelect.value = newLang;
  }

  const btnLang = document.getElementById("btn-rail-lang");
  if (btnLang) {
    const span = btnLang.querySelector("span");
    if (span) {
      span.textContent = newLang === "en" ? "EN" : "简";
    }
  }

  applyTranslations();

  if (typeof renderMonitoredDirectories === "function") renderMonitoredDirectories();
  if (typeof renderEvents === "function") renderEvents();
  if (typeof renderHomeRecentEvents === "function") renderHomeRecentEvents();
  if (typeof renderLargeTables === "function") renderLargeTables();
  if (typeof renderPendingTable === "function") renderPendingTable();
  if (typeof renderPendingTree === "function") renderPendingTree();
  if (typeof updateHomeStats === "function") updateHomeStats();
  if (typeof updatePendingDetailPanel === "function") updatePendingDetailPanel();
  if (typeof loadReportsTab === "function") loadReportsTab();

  const toastMsg = newLang === "en" ? "Interface switched to English" : "界面已切换为中文";
  showGlobalToast(toastMsg);
}

// Application State Cache
let state = {
  monitoredPaths: [],
  fileEvents: [],
  filterType: "all", // "all" | "pending" (Old sidebar state, kept for compatibility)
  searchQuery: "",
  credentials: null,
  activeTab: "events",
  isSyncing: false,
  currentSyncDirection: null,
  autoSync: false,
  expandedPaths: new Set(),
  selectedEventId: null,
  availableKnowledgeBases: [],
  kbLoadError: null,
  
  // Premium SwiftUI Features State
  tourActive: false,
  currentTourStep: 0,
  pendingSearchQuery: "",
  allSearchQuery: "",
  allFilterType: "all", // "all" | "synced" | "pending"
  
  // Pending Tab view and detail panel states
  pendingViewMode: "list", // "list" | "tree"
  pendingFilterType: "all", // "all" | "created" | "modified" | "deleted" | "renamed"
  selectedPendingEventId: null,
  selectedPendingNode: null
};

// Default gender-neutral SVG avatar data URI (Cute Panda Theme)
const defaultAvatar = "data:image/svg+xml,%3Csvg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'%3E%3Ccircle cx='6' cy='6' r='3.5' fill='%23334155'/%3E%3Ccircle cx='18' cy='6' r='3.5' fill='%23334155'/%3E%3Ccircle cx='12' cy='12' r='9' fill='%23f8fafc' stroke='%23334155' stroke-width='1.5'/%3E%3Cellipse cx='8.5' cy='11.5' rx='2' ry='2.8' transform='rotate(-15 8.5 11.5)' fill='%23334155'/%3E%3Cellipse cx='15.5' cy='11.5' rx='2' ry='2.8' transform='rotate(15 15.5 11.5)' fill='%23334155'/%3E%3Ccircle cx='8.5' cy='11' r='0.8' fill='%23ffffff'/%3E%3Ccircle cx='15.5' cy='11' r='0.8' fill='%23ffffff'/%3E%3Cpolygon points='12,14 10.5,12.5 13.5,12.5' fill='%23334155'/%3E%3Cpath d='M10.5,15.5 C11,16.2 13,16.2 13.5,15.5' fill='none' stroke='%23334155' stroke-width='1' stroke-linecap='round'/%3E%3C/svg%3E";

function ensureHttps(url) {
  if (url && typeof url === "string") {
    let cleanUrl = url.trim();
    if (cleanUrl.startsWith("http://")) {
      return cleanUrl.replace(/^http:\/\//i, "https://");
    }
    return cleanUrl;
  }
  return url;
}

function isDefaultAvatar(url) {
  if (!url || typeof url !== "string") return true;
  const lower = url.trim().toLowerCase();
  if (lower === "" || lower === "null" || lower === "undefined") return true;
  if (lower.includes("default_avatar") || 
      lower.includes("avatar_male") || 
      lower.includes("avatar_female") ||
      lower.includes("default") ||
      lower.includes("pcima/images") ||
      lower.includes("res.im.qq.com")) {
    return true;
  }
  return false;
}

// DOM References
let dom = {};

// Onboarding steps config
const tourSteps = [
  {
    targetId: "rail-top-group",
    title: "先认识左侧导航",
    text: "左侧图标栏是主要入口：首页、待同步、全部记录、报告、帮助和设置都在这里切换。",
    direction: "left",
    icon: `<svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: currentColor;"><path d="M4 15h16v-2H4v2zm0 4h16v-2H4v2zm0-8h16V9H4v2zm0-6v2h16V5H4z"/></svg>`
  },
  {
    targetId: "btn-add-dir-home",
    title: "第一步：添加监控目录",
    text: "点击这里，选择你本地的文件夹。捕获到任何修改都会自动生成一条记录。",
    direction: "left",
    icon: `<svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: currentColor;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>`
  },
  {
    targetId: "home-sync-mode-container",
    title: "选择手动或自动同步",
    text: "默认是手动同步。开启自动同步后，文件稳定 30 秒会自动上传到 IMA，适合持续写作或频繁保存的目录。",
    direction: "right",
    icon: `<svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: currentColor;"><path d="M12 6v3l4-4-4-4v3c-4.42 0-8 3.58-8 8 0 1.57.46 3.03 1.24 4.26L6.7 14.8c-.45-.83-.7-1.79-.7-2.8 0-3.31 2.69-6 6-6z"/></svg>`
  },
  {
    targetId: "btn-tab-pending",
    title: "处理待同步与历史记录",
    text: "待同步面板可以让你集中处理待上传变动，全部记录则能查看和检索完整的文件监控变更历史。",
    direction: "left",
    icon: `<svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: currentColor;"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>`
  },
  {
    targetId: "btn-tab-help", // Highlights help button/area in bottom rail
    title: "最后配置云端和偏好",
    text: "底部区域可以进入帮助、设置、切换语言和退出。建议先进行腾讯 IMA 账号扫码登录，并按需配置忽略规则。",
    direction: "left",
    icon: `<svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: currentColor;"><path d="M19.43 12.98c.04-.32.07-.64.07-.98s-.03-.66-.07-.98l2.11-1.65c.19-.15.24-.42.12-.64l-2-3.46c-.12-.22-.39-.3-.61-.22l-2.49 1c-.52-.4-1.08-.73-1.69-.98l-.38-2.65C14.46 2.18 14.25 2 14 2h-4c-.25 0-.46.18-.49.42l-.38 2.65c-.61.25-1.17.59-1.69.98l-2.49-1c-.23-.09-.49 0-.61.22l-2 3.46c-.13.22-.07.49.12.64l2.11 1.65c-.04.32-.07.65-.07.98s.03.66.07.98l-2.11 1.65c-.19.15-.24.42-.12.64l2 3.46c.12.22.39.3.61.22l2.49-1c.52.4 1.08.73 1.69.98l.38 2.65c.03.24.24.42.49.42h4c.25 0 .46-.18.49-.42l.38-2.65c.61-.25 1.17-.59 1.69-.98l2.49 1c.23.09.49 0 .61-.22l2-3.46c.12-.22.07-.49-.12-.64l-2.11-1.65zM12 15.5c-1.93 0-3.5-1.57-3.5-3.5s1.57-3.5 3.5-3.5 3.5 1.57 3.5 3.5-1.57 3.5-3.5 3.5z"/></svg>`
  }
];

// Initialize application elements when DOM is ready
window.addEventListener("DOMContentLoaded", () => {
  cacheDOMElements();
  applyTranslations();
  
  // Restore cached credentials from localStorage immediately on startup to avoid UI flickering/delay
  const cachedAvatar = localStorage.getItem("user_avatar") || "";
  const cachedNickname = localStorage.getItem("user_nickname") || "";
  const hasAvatar = cachedAvatar && cachedAvatar !== "null" && cachedAvatar !== "undefined" && cachedAvatar !== "";
  const hasNickname = cachedNickname && cachedNickname !== "null" && cachedNickname !== "undefined" && cachedNickname !== "";
  if (hasAvatar || hasNickname) {
    const finalAvatar = hasAvatar ? ensureHttps(cachedAvatar) : "";
    const finalNickname = hasNickname ? cachedNickname : "微信用户";
    state.credentials = { avatar: finalAvatar, nickname: finalNickname };
    showAuthorizedUI(finalAvatar, finalNickname);
  }
  
  setupTabListeners();
  setupFilterListeners();
  setupActionListeners();
  
  // Premium SwiftUI Features listeners setup
  setupWelcomeBannerListeners();
  setupHelpSegmentsListeners();
  setupFAQAccordionListeners();
  setupOnboardingTourListeners();
  setupLargeTablesListeners();
  setupReportsListeners();
  
  // Window resize updates Onboarding spotlight target dynamically
  window.addEventListener("resize", () => {
    if (state.tourActive) {
      updateTourPosition();
    }
  });

  // Initial Bootup Sequence
  initializeApplication();

  // Show the main window after a tiny delay to ensure the browser has painted the initial frame
  setTimeout(() => {
    invoke("show_main_window").catch(() => {});
    
    // Postpone the Auth State Validation (which triggers macOS Keychain permission dialog)
    // to run after the main window has been shown and painted.
    // This prevents a blank gray window from being displayed behind the Keychain access modal.
    setTimeout(() => {
      checkAuthState().catch((err) => {
        console.error("Error checking auth state on startup:", err);
      });
    }, 400);
  }, 100);
});

// Cache standard UI elements for high performance DOM updates
function cacheDOMElements() {
  dom.railBtns = {
    events: document.getElementById("btn-tab-events"),
    pending: document.getElementById("btn-tab-pending"),
    all: document.getElementById("btn-tab-all"),
    reports: document.getElementById("btn-tab-reports"),
    settings: document.getElementById("btn-tab-settings"),
    help: document.getElementById("btn-tab-help")
  };
  
  dom.panes = {
    events: document.getElementById("tab-pane-events"),
    pending: document.getElementById("tab-pane-pending"),
    all: document.getElementById("tab-pane-all"),
    reports: document.getElementById("tab-pane-reports"),
    settings: document.getElementById("tab-pane-settings"),
    help: document.getElementById("tab-pane-help")
  };
  
  // Old sidebar references (safeguarded)
  dom.sidebarEvents = document.getElementById("sidebar-events");
  dom.eventListContainer = document.getElementById("event-list-container");
  
  dom.dirGridContainer = document.getElementById("settings-dirs-container");
  
  // Search boxes
  dom.searchBox = document.getElementById("event-search-input");
  dom.pendingSearchBox = document.getElementById("pending-search-input");
  dom.allSearchBox = document.getElementById("all-search-input");
  
  // Filter buttons
  dom.filterAllBtn = document.getElementById("filter-all");
  dom.filterPendingBtn = document.getElementById("filter-pending");
  
  dom.syncBtn = document.getElementById("btn-sync-all");
  dom.addDirBtn = document.getElementById("btn-settings-add-dir");
  dom.addDirHomeBtn = document.getElementById("btn-add-dir-home");
  dom.saveSettingsBtn = document.getElementById("btn-save-settings");
  
  // Input fields
  dom.ignoreExts = document.getElementById("setting-ignore-exts");
  dom.ignoreDirs = document.getElementById("setting-ignore-dirs");
  
  // Modals overlays
  dom.overlayClear = document.getElementById("overlay-clear-events");
  dom.overlayReset = document.getElementById("overlay-reset-all");
  dom.overlayHttpLogs = document.getElementById("overlay-http-logs");
  dom.httpLogsList = document.getElementById("http-logs-list");
  dom.btnShowLogs = document.getElementById("btn-show-logs");
  dom.btnShowLogsDedicated = document.getElementById("btn-show-logs-dedicated");
  dom.btnClearLogs = document.getElementById("btn-clear-logs");
  dom.btnCloseLogs = document.getElementById("btn-close-logs");
  
  // Modal buttons
  dom.btnTriggerClear = document.getElementById("btn-trigger-clear-new");
  dom.btnTriggerReset = document.getElementById("btn-trigger-reset-new");
  
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

  // Home elements
  dom.homeStatPending = document.getElementById("home-stat-pending");
  dom.homeStatTotal = document.getElementById("home-stat-total");
  dom.homeStatMonitored = document.getElementById("home-stat-monitored");
  dom.homeRecentEventsContainer = document.getElementById("home-recent-events-container");
  dom.homeMessageTitle = document.getElementById("home-message-title");
  dom.btnToggleAutoSync = document.getElementById("btn-toggle-autosync");
  dom.btnRailAvatar = document.getElementById("btn-rail-avatar");
  dom.btnRailExit = document.getElementById("btn-rail-exit");
  dom.railPendingBadge = document.getElementById("rail-pending-badge");
  dom.homeStatusQueue = document.getElementById("home-status-queue");
  dom.homeStatusMode = document.getElementById("home-status-mode");
  dom.homeStatusPaths = document.getElementById("home-status-paths");
  
  // Quick navigation buttons
  dom.btnQuickPending = document.getElementById("btn-quick-pending");
  dom.btnQuickAll = document.getElementById("btn-quick-all");
  dom.btnQuickReports = document.getElementById("btn-quick-reports");
  
  // Welcome card banner elements
  dom.introBannerCard = document.getElementById("intro-banner-card");
  dom.btnCloseIntro = document.getElementById("btn-close-intro");
  dom.btnStartTour = document.getElementById("btn-start-tour");
  dom.btnViewDocs = document.getElementById("btn-view-docs");
  dom.btnHideIntroPermanently = document.getElementById("btn-hide-intro-permanently");
  
  // Onboarding overlay elements
  dom.globalTourOverlay = document.getElementById("global-tour-overlay");
  dom.tourSpotlight = document.getElementById("tour-spotlight");
  dom.tourPointer = document.getElementById("tour-pointer");
  dom.tourPointerArrow = document.getElementById("tour-pointer-arrow");
  dom.tourCard = document.getElementById("tour-card");
  dom.tourStepBadge = document.getElementById("tour-step-badge");
  dom.tourCardTitle = document.getElementById("tour-card-title");
  dom.tourCardText = document.getElementById("tour-card-text");
  dom.tourSteppers = document.getElementById("tour-steppers");
  dom.btnTourSkip = document.getElementById("btn-tour-skip");
  dom.btnTourPrev = document.getElementById("btn-tour-prev");
  dom.btnTourNext = document.getElementById("btn-tour-next");
  dom.btnTourNextText = document.getElementById("btn-tour-next-text");
  
  // Table bodies
  dom.pendingEventsTableBody = document.getElementById("pending-events-table-body");
  dom.allEventsTableBody = document.getElementById("all-events-table-body");
  
  // Pending view switch references
  dom.pendingListViewContainer = document.getElementById("pending-list-view-container");
  dom.pendingTreeViewContainer = document.getElementById("pending-tree-view-container");
  dom.pendingDetailPanel = document.getElementById("pending-detail-panel");
  dom.pendingEmptyState = document.getElementById("pending-empty-state");
  dom.pendingEmptyStatusHeading = document.getElementById("pending-empty-status-heading");
  dom.pendingEmptyStatusSubheading = document.getElementById("pending-empty-status-subheading");
}

// Setup left sidebar rail tab toggle mechanisms
function setupTabListeners() {
  Object.keys(dom.railBtns).forEach(tab => {
    if (dom.railBtns[tab]) {
      dom.railBtns[tab].addEventListener("click", () => {
        switchTab(tab);
      });
    }
  });
}

function switchTab(tabName) {
  state.activeTab = tabName;
  
  // Toggle rail active highlights
  Object.keys(dom.railBtns).forEach(key => {
    if (dom.railBtns[key] && dom.panes[key]) {
      if (key === tabName) {
        dom.railBtns[key].classList.add("active");
        dom.panes[key].classList.add("active");
      } else {
        dom.railBtns[key].classList.remove("active");
        dom.panes[key].classList.remove("active");
      }
    }
  });
  
  // Collapse second sidebar if it exists and we aren't on the events panel
  if (dom.sidebarEvents) {
    if (tabName === "events") {
      dom.sidebarEvents.classList.remove("collapsed");
    } else {
      dom.sidebarEvents.classList.add("collapsed");
    }
  }
  
  // Reload corresponding tab data
  if (tabName === "reports") {
    loadReportsTab();
  } else if (tabName === "pending" || tabName === "all") {
    renderLargeTables();
  } else if (tabName === "settings") {
    // Lazy-load settings data on-demand
    invoke("get_ima_credentials").then((creds) => {
      if (creds) {
        loadAvailableKnowledgeBases().catch(console.error);
        fetchAndRenderSpaceQuota(creds).catch(console.error);
      }
    }).catch(console.error);
  }
}

// Setup Event List filter listeners
function setupFilterListeners() {
  if (dom.filterAllBtn) {
    dom.filterAllBtn.addEventListener("click", () => {
      dom.filterAllBtn.classList.add("active");
      if (dom.filterPendingBtn) dom.filterPendingBtn.classList.remove("active");
      state.filterType = "all";
      renderEvents();
    });
  }
  
  if (dom.filterPendingBtn) {
    dom.filterPendingBtn.addEventListener("click", () => {
      dom.filterPendingBtn.classList.add("active");
      if (dom.filterAllBtn) dom.filterAllBtn.classList.remove("active");
      state.filterType = "pending";
      renderEvents();
    });
  }
  
  if (dom.searchBox) {
    dom.searchBox.addEventListener("input", (e) => {
      state.searchQuery = e.target.value.toLowerCase().trim();
      renderEvents();
    });
  }
}

// Setup generic action trigger mechanisms
function setupActionListeners() {
  // Directory manipulation
  if (dom.addDirBtn) dom.addDirBtn.addEventListener("click", addFolder);
  if (dom.addDirHomeBtn) dom.addDirHomeBtn.addEventListener("click", addFolder);
  
  // Settings page action save
  if (dom.saveSettingsBtn) dom.saveSettingsBtn.addEventListener("click", saveIgnoreSettings);
  
  // Sync
  if (dom.syncBtn) dom.syncBtn.addEventListener("click", syncAll);
  
  // Custom Modals trigger overlays
  if (dom.btnTriggerClear) {
    dom.btnTriggerClear.addEventListener("click", () => {
      dom.overlayClear.classList.remove("hidden");
    });
  }
  
  if (dom.btnCancelClear) {
    dom.btnCancelClear.addEventListener("click", () => {
      dom.overlayClear.classList.add("hidden");
    });
  }
  
  if (dom.btnConfirmClear) {
    dom.btnConfirmClear.addEventListener("click", async () => {
      try {
        await invoke("clear_all_events");
        state.fileEvents = [];
        renderEvents();
        renderHomeRecentEvents();
        renderLargeTables();
        updateHomeStats();
        dom.overlayClear.classList.add("hidden");
        showGlobalToast("文件变更事件记录已成功清空！");
      } catch (e) {
        showGlobalToast("清除记录失败: " + e, true);
      }
    });
  }
  
  if (dom.btnTriggerReset) {
    dom.btnTriggerReset.addEventListener("click", () => {
      dom.overlayReset.classList.remove("hidden");
    });
  }
  
  if (dom.btnCancelReset) {
    dom.btnCancelReset.addEventListener("click", () => {
      dom.overlayReset.classList.add("hidden");
    });
  }
  
  if (dom.btnConfirmReset) {
    dom.btnConfirmReset.addEventListener("click", async () => {
      try {
        await resetToFactoryDefaults();
        dom.overlayReset.classList.add("hidden");
      } catch (e) {
        showGlobalToast("重置应用失败: " + e, true);
      }
    });
  }
  
  // WeChat Scan Trigger
  if (dom.btnLoginIMA) {
    dom.btnLoginIMA.addEventListener("click", () => {
      openIMALoginWindow();
    });
  }
  let connectBtn = document.getElementById("btn-connect-cloud");
  if (connectBtn) {
    connectBtn.addEventListener("click", () => {
      openIMALoginWindow();
    });
  }
  
  if (dom.btnLogoutIMA) {
    dom.btnLogoutIMA.addEventListener("click", logoutTencentIMA);
  }

  let refStatusBtn = document.getElementById("btn-refresh-status");
  if (refStatusBtn) {
    refStatusBtn.addEventListener("click", async () => {
      try {
        refStatusBtn.disabled = true;
        const originalText = refStatusBtn.textContent;
        refStatusBtn.textContent = "正在刷新...";
        await checkAuthState();
        await loadAvailableKnowledgeBases();
        showGlobalToast("连接状态与知识库已刷新");
        refStatusBtn.textContent = originalText;
      } catch (e) {
        showGlobalToast("刷新失败: " + (e.message || e), true);
      } finally {
        refStatusBtn.disabled = false;
        let btn = document.getElementById("btn-refresh-status");
        if (btn && btn.textContent === "正在刷新...") {
          btn.textContent = "刷新状态";
        }
      }
    });
  }

  // Auto-sync toggle
  if (dom.btnToggleAutoSync) {
    dom.btnToggleAutoSync.addEventListener("click", async () => {
      state.autoSync = !state.autoSync;
      updateAutoSyncUI();
      try {
        await invoke("set_config_value", { key: "autoSync", value: state.autoSync ? "true" : "false" });
        showGlobalToast(state.autoSync ? "自动同步模式已开启" : "手动同步模式已开启");
      } catch (e) {
        showGlobalToast("保存同步模式失败: " + e, true);
      }
    });
  }

  // Left rail avatar and exit listeners
  if (dom.btnRailAvatar) {
    dom.btnRailAvatar.addEventListener("click", () => {
      if (state.credentials) {
        openAccountSettings();
      } else {
        openIMALoginWindow();
      }
    });
  }

  if (dom.btnRailExit) {
    dom.btnRailExit.addEventListener("click", async () => {
      try {
        await invoke("exit_app");
      } catch (err) {
        console.error("Failed to exit app via command:", err);
        try {
          window.__TAURI__.window.getCurrentWindow().close();
        } catch (e) {
          console.error("Failed to exit via window close:", e);
        }
      }
    });
  }

  // Home Metrics Cards Click Handlers
  const cardPending = document.getElementById("home-card-pending");
  if (cardPending) {
    cardPending.addEventListener("click", () => {
      switchTab("pending");
    });
  }
  const cardTotal = document.getElementById("home-card-total");
  if (cardTotal) {
    cardTotal.addEventListener("click", () => {
      switchTab("all");
    });
  }
  const cardMonitored = document.getElementById("home-card-monitored");
  if (cardMonitored) {
    cardMonitored.addEventListener("click", () => {
      switchTab("settings");
    });
  }

  // Quick navigation buttons
  if (dom.btnQuickPending) {
    dom.btnQuickPending.addEventListener("click", () => {
      switchTab("pending");
    });
  }
  if (dom.btnQuickAll) {
    dom.btnQuickAll.addEventListener("click", () => {
      switchTab("all");
    });
  }
  if (dom.btnQuickReports) {
    dom.btnQuickReports.addEventListener("click", () => {
      switchTab("reports");
    });
  }

  // Language switcher
  const btnLang = document.getElementById("btn-rail-lang");
  if (btnLang) {
    btnLang.addEventListener("click", () => {
      const current = getCurrentLanguage();
      const newLang = current === "en" ? "zh-Hans" : "en";
      switchLanguage(newLang);
    });
  }
}

// Core bootup operations
async function initializeApplication() {
  listen("login_success", (event) => {
    console.log("Login success event received from Tauri.");
    const payload = event?.payload || {};
    applyLoginSuccess(payload);
    refreshAppStatus();
  });

  try {
    // 1. Fetch ignore configs
    let enableDefaultVal = await invoke("get_config_value", { key: "enableDefaultIgnoreRules" });
    if (enableDefaultVal === null) {
      await invoke("set_config_value", { key: "enableDefaultIgnoreRules", value: "true" });
    }
    
    let customExtsVal = await invoke("get_config_value", { key: "customIgnoredExtensions" });
    if (dom.ignoreExts) dom.ignoreExts.value = customExtsVal || "tmp, log, asd, part";
    
    let customDirsVal = await invoke("get_config_value", { key: "customIgnoredDirectoryNames" });
    if (dom.ignoreDirs) dom.ignoreDirs.value = customDirsVal || ".git, node_modules, dist";

    // Load autoSync setting
    let autoSyncVal = await invoke("get_config_value", { key: "autoSync" });
    state.autoSync = autoSyncVal === "true";
    updateAutoSyncUI();
    
    // 2. Fetch monitored directories
    let dirsVal = await invoke("get_config_value", { key: "monitoredDirectories" });
    if (dirsVal) {
      state.monitoredPaths = JSON.parse(dirsVal);
      // Synchronize bindings from SQLite DB to localStorage
      for (const path of state.monitoredPaths) {
        try {
          let binding = await invoke("get_config_value", { key: `kb_binding_${path}` });
          if (binding) {
            localStorage.setItem(`kb_binding_${path}`, binding);
          } else {
            let cached = localStorage.getItem(`kb_binding_${path}`);
            if (cached) {
              await invoke("set_kb_binding", { path, kb_id: cached, kbId: cached }).catch(() => {});
            }
          }
        } catch (e) {
          console.error("Failed to load binding for path " + path, e);
        }
      }
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
    // (Moved to startup post-render sequence to prevent Keychain prompt blocking window paint)
    
    // 6. Register Tauri events listener
    listen("file-change-events", (event) => {
      console.log("[Tauri Event] New coalesced file events received:", event.payload);
      fetchEvents().then(() => {
        if (state.autoSync && !state.isSyncing) {
          syncAll();
        }
      });
    });
    
    listen("trigger-sync-all", () => {
      console.log("[Tauri Event] Tray triggered sync all");
      syncAll();
    });

    listen("sync-progress", (event) => {
      const { step, title, status, progress } = event.payload;
      if (dom.syncBanner) {
        dom.syncBanner.classList.remove("hidden");
      }
      if (dom.syncBannerTitle) dom.syncBannerTitle.textContent = title;
      if (dom.syncBannerStatus) dom.syncBannerStatus.textContent = status;
      if (dom.syncBannerFill) dom.syncBannerFill.style.width = `${progress}%`;
      
      if (step === "complete") {
        fetchEvents();
        setTimeout(() => {
          if (dom.syncBanner) dom.syncBanner.classList.add("hidden");
          state.isSyncing = false;
          
          if (dom.syncBtn) dom.syncBtn.disabled = false;
          const btnPush = document.getElementById("btn-sync-all-pending-push");
          const btnPull = document.getElementById("btn-sync-all-pending-pull");
          const btnMark = document.getElementById("btn-mark-all-synced");
          if (btnPush) btnPush.disabled = false;
          if (btnPull) btnPull.disabled = false;
          if (btnMark) btnMark.disabled = false;
          
          let toastMsg = "同步完成！所有文件已双向同步。";
          if (state.currentSyncDirection === "push") {
            toastMsg = "同步完成！已成功将所有本地修改同步至 IMA。";
          } else if (state.currentSyncDirection === "pull") {
            toastMsg = "同步完成！已成功从云端拉取最新变更。";
          }
          state.currentSyncDirection = null;
          showGlobalToast(toastMsg);
        }, 2200);
      } else if (step === "error") {
        fetchEvents();
        setTimeout(() => {
          if (dom.syncBanner) dom.syncBanner.classList.add("hidden");
          state.isSyncing = false;
          
          if (dom.syncBtn) dom.syncBtn.disabled = false;
          const btnPush = document.getElementById("btn-sync-all-pending-push");
          const btnPull = document.getElementById("btn-sync-all-pending-pull");
          const btnMark = document.getElementById("btn-mark-all-synced");
          if (btnPush) btnPush.disabled = false;
          if (btnPull) btnPull.disabled = false;
          if (btnMark) btnMark.disabled = false;
          
          state.currentSyncDirection = null;
          showGlobalToast("同步失败: " + status, true);
        }, 3000);
      }
    });

    
    // 7. Check if Onboarding Tour has been finished
    let hideTour = localStorage.getItem("tourCompleted") === "true";
    if (!hideTour) {
      setTimeout(() => {
        startOnboardingTour();
      }, 800);
    }
    
    // Check if Intro banner has been closed (or if tour is already completed)
    let hideIntro = localStorage.getItem("hideIntroBanner") === "true" || hideTour;
    if (hideIntro && dom.introBannerCard) {
      dom.introBannerCard.classList.add("hidden");
    }
    
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
    renderHomeRecentEvents();
    renderLargeTables();
    updateHomeStats();
    if (state.activeTab === "reports") {
      loadReportsTab();
    }
  } catch (e) {
    console.error("Error fetching events:", e);
  }
}

async function refreshAppStatus() {
  await Promise.all([
    fetchEvents(),
    checkAuthState()
  ]);
}

function applyLoginSuccess(profile = {}) {
  const rawAvatar = profile.avatar || profile.avatarUrl || "";
  const avatar = ensureHttps(rawAvatar);
  const nickname = profile.nickname || profile.nick || "微信用户";
  state.credentials = { avatar, nickname };
  localStorage.setItem("user_avatar", avatar);
  localStorage.setItem("user_nickname", nickname);
  showAuthorizedUI(avatar, nickname);
  showGlobalToast("微信扫码授权成功，Tencent IMA 已连接。");
  
  // Trigger loading of knowledge bases and space quota immediately upon a successful scan/login
  invoke("get_ima_credentials").then((creds) => {
    if (creds) {
      loadAvailableKnowledgeBases().catch(console.error);
      fetchAndRenderSpaceQuota(creds).catch(console.error);
    }
  }).catch(console.error);
}

// Render monitored folder grid cards
function renderMonitoredDirectories() {
  if (!dom.dirGridContainer) return;

  if (state.monitoredPaths.length === 0) {
    dom.dirGridContainer.innerHTML = `
      <div class="settings-row" id="settings-dirs-empty">
        <div class="settings-row-text">
          <span class="settings-row-title">监控文件夹</span>
          <span class="settings-row-subtitle">尚未添加目录</span>
        </div>
        <button class="pill-btn primary" id="btn-settings-add-dir" style="padding: 6px 14px; min-width: 0; min-height: 0; height: auto;">
          <span>添加</span>
        </button>
      </div>
    `;
    
    // Bind empty state add button
    let emptyAddBtn = document.getElementById("btn-settings-add-dir");
    if (emptyAddBtn) {
      emptyAddBtn.addEventListener("click", () => {
        addFolder();
      });
    }
    
    updateHomeStats();
    return;
  }
  
  dom.dirGridContainer.innerHTML = "";
  state.monitoredPaths.forEach(path => {
    let cleanPath = path.replace(/\\/g, "/");
    let name = cleanPath.split("/").pop() || path;
    
    // Check if we have knowledgebases cached
    let kbOptions = `<option value="default">默认 (新建笔记)</option>`;
    if (state.availableKnowledgeBases && state.availableKnowledgeBases.length > 0) {
        state.availableKnowledgeBases.forEach(kb => {
            let finalKbId = kb.id || kb.knowledgeBaseId || kb.kb_id;
            kbOptions += `<option value="${finalKbId}">${kb.name}</option>`;
        });
    } else {
        if (state.kbLoadError) {
            kbOptions += `<option value="error" disabled selected>❌ 加载失败: ${state.kbLoadError}</option>`;
        } else if (state.credentials) {
            kbOptions += `<option value="loading" disabled selected>🔄 云端知识库加载中...</option>`;
        } else {
            kbOptions += `<option value="unauth" disabled selected>🔑 请先登录腾讯 IMA 账号</option>`;
        }
    }

    let currentKbId = localStorage.getItem(`kb_binding_${path}`) || "default";
    kbOptions = kbOptions.replace(`value="${currentKbId}"`, `value="${currentKbId}" selected`);

    let rowHtml = `
      <div class="monitored-dir-row">
        <div class="settings-row" style="border-bottom: none; min-height: 48px;">
          <div class="settings-row-text">
            <span class="settings-row-title">${name}</span>
            <span class="settings-row-subtitle">${path}</span>
          </div>
          <button class="quiet-btn red dir-remove-btn" data-path="${path}" title="移除目录">
            <svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: currentColor; pointer-events: none;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4 11H8v-2h8v2z"/></svg>
          </button>
        </div>
        <div class="monitored-dir-kb-binder">
          <span style="font-size: 11px; color: var(--text-muted);">同步至知识库</span>
          <div style="display: flex; align-items: center; gap: 4px;">
            <select class="app-dropdown kb-selector" data-path="${path}" style="width: 180px;">
              ${kbOptions}
            </select>
            <button class="quiet-btn kb-refresh-btn" title="刷新云端知识库列表">
              <svg viewBox="0 0 24 24" style="width: 14px; height: 14px; fill: currentColor; pointer-events: none;"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
            </button>
          </div>
        </div>
      </div>
    `;
    
    let wrapper = document.createElement("div");
    wrapper.innerHTML = rowHtml.trim();
    let card = wrapper.firstChild;
    
    card.querySelector(".dir-remove-btn").addEventListener("click", () => {
      removeFolder(path);
    });

    card.querySelector(".kb-selector").addEventListener("change", (e) => {
      let newKbId = e.target.value;
      localStorage.setItem(`kb_binding_${path}`, newKbId);
      // Let backend know
      invoke("set_kb_binding", { path, kb_id: newKbId, kbId: newKbId }).catch(() => {});
    });

    card.querySelector(".kb-refresh-btn").addEventListener("click", async () => {
      try {
        await loadAvailableKnowledgeBases();
        showGlobalToast("知识库列表已刷新");
      } catch(e) {
        showGlobalToast("刷新失败", true);
      }
    });
    
    dom.dirGridContainer.appendChild(card);
  });
  
  // Append "Add more directories" row
  let addMoreHtml = `
    <div class="settings-row">
      <div class="settings-row-text">
        <span class="settings-row-title">添加更多目录</span>
        <span class="settings-row-subtitle">继续监控其他文件夹</span>
      </div>
      <button class="quiet-btn" id="btn-settings-add-more">添加</button>
    </div>
  `;
  let addWrapper = document.createElement("div");
  addWrapper.innerHTML = addMoreHtml.trim();
  dom.dirGridContainer.appendChild(addWrapper.firstChild);
  
  document.getElementById("btn-settings-add-more").addEventListener("click", () => {
    addFolder();
  });
  
  updateHomeStats();
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
      await fetchEvents();
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
    await fetchEvents();
  } catch (err) {
    showGlobalToast("移除监控失败: " + err, true);
  }
}

// Render events as a gorgeous hierarchical tree view
function renderEvents() {
  if (!dom.eventListContainer) return;

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

  // Build the hierarchical tree
  const treeRoots = buildEventTree(filtered, state.monitoredPaths);

  // If we have new roots, default expand the top-level folders
  treeRoots.forEach(root => {
    state.expandedPaths.add(root.path);
  });

  // Render tree recursively into eventListContainer
  dom.eventListContainer.innerHTML = "";
  treeRoots.forEach(node => {
    dom.eventListContainer.appendChild(renderTreeNodeDOM(node, 0));
  });
}

function buildEventTree(events, monitoredPaths) {
  // Global root
  const globalRoot = {
    path: "__root__",
    name: "root",
    isDirectory: true,
    children: [],
    events: [],
    pendingCount: 0,
    totalCount: 0
  };

  // Sort monitored paths descending by length to match longest prefix
  const sortedMonitoredPaths = [...monitoredPaths].sort((a, b) => b.length - a.length);

  for (const event of events) {
    let cleanPath = event.path.replace(/\\/g, "/");
    
    // Find matching monitored path
    let matchedRoot = null;
    for (const p of sortedMonitoredPaths) {
      let cleanP = p.replace(/\\/g, "/");
      if (cleanPath.startsWith(cleanP)) {
        matchedRoot = p;
        break;
      }
    }

    if (matchedRoot) {
      let cleanRoot = matchedRoot.replace(/\\/g, "/");
      let relativePath = cleanPath.slice(cleanRoot.length);
      // Split relative path into segments, ignoring empty ones
      let segments = relativePath.split("/").filter(s => s.length > 0);

      // Get or create root directory node
      let rootDirName = matchedRoot.replace(/\\/g, "/").split("/").pop() || matchedRoot;
      let rootNode = findOrCreateChildNode(globalRoot, matchedRoot, rootDirName, true);

      let currentNode = rootNode;
      let accumulatedPath = matchedRoot.replace(/\\/g, "/");

      for (let i = 0; i < segments.length; i++) {
        const segment = segments[i];
        accumulatedPath += (accumulatedPath.endsWith("/") ? "" : "/") + segment;
        const isLast = (i === segments.length - 1);

        if (isLast) {
          // Leaf node - attach event
          let fileNode = findOrCreateChildNode(currentNode, accumulatedPath, segment, false);
          fileNode.events.push(event);
        } else {
          // Directory node
          currentNode = findOrCreateChildNode(currentNode, accumulatedPath, segment, true);
        }
      }
    } else {
      // Put in "其他" (Other)
      let otherNode = findOrCreateChildNode(globalRoot, "__other__", "其他", true);
      let fileNode = findOrCreateChildNode(otherNode, cleanPath, cleanPath.split("/").pop() || cleanPath, false);
      fileNode.events.push(event);
    }
  }

  // Prune & Sort & Compute counts
  pruneAndComputeTree(globalRoot);
  return globalRoot.children;
}

function findOrCreateChildNode(parent, fullPath, name, isDirectory) {
  let existing = parent.children.find(c => c.path === fullPath);
  if (!existing) {
    existing = {
      path: fullPath,
      name: name,
      isDirectory: isDirectory,
      children: [],
      events: [],
      pendingCount: 0,
      totalCount: 0
    };
    parent.children.push(existing);
  }
  return existing;
}

function pruneAndComputeTree(node) {
  // Recurse into children first
  node.children = node.children.filter(child => pruneAndComputeTree(child));

  // Sort children by name using localeCompare
  node.children.sort((a, b) => a.name.localeCompare(b.name, 'zh-CN'));

  // Calculate counts for this node
  let directPending = node.events.filter(e => !e.is_synced).length;
  let directTotal = node.events.length;

  let childrenPending = node.children.reduce((sum, child) => sum + child.pendingCount, 0);
  let childrenTotal = node.children.reduce((sum, child) => sum + child.totalCount, 0);

  node.pendingCount = directPending + childrenPending;
  node.totalCount = directTotal + childrenTotal;

  // Keep if node has events, or has children with events
  return node.totalCount > 0;
}

function renderTreeNodeDOM(node, depth) {
  const wrapper = document.createElement("div");
  wrapper.className = "tree-node-wrapper";

  const row = document.createElement("div");
  const indent = depth * 16;
  row.style.paddingLeft = `${indent + 10}px`;

  if (node.isDirectory) {
    row.className = "tree-row directory-row";
    
    // Chevron expanded state: Auto-expand when a search query is active
    const isExpanded = state.searchQuery ? true : state.expandedPaths.has(node.path);
    
    const arrow = document.createElement("div");
    arrow.className = `tree-arrow ${isExpanded ? 'expanded' : ''}`;
    arrow.innerHTML = `<svg viewBox="0 0 24 24"><path d="M8.59 16.59L13.17 12 8.59 7.41 10 6l6 6-6 6-6 6-1.41-1.41z" fill="currentColor"/></svg>`;
    
    // Folder Icon
    const folderIcon = document.createElement("div");
    folderIcon.className = "tree-icon directory-icon";
    folderIcon.innerHTML = isExpanded 
      ? `<svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-2 12H4V8h16v10z" fill="currentColor"/></svg>`
      : `<svg viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>`;

    const name = document.createElement("div");
    name.className = "tree-row-details";
    name.innerHTML = `<span class="tree-row-name">${node.name}</span>`;

    const badgeStack = document.createElement("div");
    badgeStack.className = "tree-badges-stack";

    // Pending count
    if (node.pendingCount > 0) {
      const pBadge = document.createElement("span");
      pBadge.className = "tree-badge pending";
      pBadge.innerText = node.pendingCount;
      badgeStack.appendChild(pBadge);
    }

    // Total events count
    const tBadge = document.createElement("span");
    const syncedAll = node.pendingCount === 0;
    tBadge.className = `tree-badge total ${syncedAll ? 'synced-all' : ''}`;
    tBadge.innerText = node.totalCount;
    badgeStack.appendChild(tBadge);

    row.appendChild(arrow);
    row.appendChild(folderIcon);
    row.appendChild(name);
    row.appendChild(badgeStack);

    // Sub-tree container supporting premium CSS Grid Auto-Height Transition
    const childrenContainer = document.createElement("div");
    childrenContainer.className = `tree-children-container ${isExpanded ? '' : 'collapsed'}`;
    
    // We wrap all children in an inner wrapper with min-height: 0 to allow smooth CSS Grid transition
    const childrenInner = document.createElement("div");
    childrenInner.className = "tree-children-inner";
    
    // Add child directories
    node.children.forEach(child => {
      childrenInner.appendChild(renderTreeNodeDOM(child, depth + 1));
    });

    // Add directly attached file events
    node.events.forEach(event => {
      const leafNode = {
        path: event.path,
        name: event.path.split("/").pop() || event.path,
        isDirectory: false,
        events: [event],
        pendingCount: event.is_synced ? 0 : 1,
        totalCount: 1
      };
      childrenInner.appendChild(renderTreeNodeDOM(leafNode, depth + 1));
    });

    childrenContainer.appendChild(childrenInner);

    row.addEventListener("click", (e) => {
      e.stopPropagation();
      const isCollapsed = childrenContainer.classList.contains("collapsed");
      if (isCollapsed) {
        state.expandedPaths.add(node.path);
        arrow.classList.add("expanded");
        childrenContainer.classList.remove("collapsed");
        folderIcon.innerHTML = `<svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-2 12H4V8h16v10z" fill="currentColor"/></svg>`;
      } else {
        state.expandedPaths.delete(node.path);
        arrow.classList.remove("expanded");
        childrenContainer.classList.add("collapsed");
        folderIcon.innerHTML = `<svg viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>`;
      }
    });

    wrapper.appendChild(row);
    wrapper.appendChild(childrenContainer);

  } else {
    // File Event row
    row.className = "tree-row file-row";
    
    const latestEvent = node.events[0];
    const isSelected = state.selectedEventId === latestEvent.id;
    if (isSelected) {
      row.classList.add("selected");
    }

    const evType = latestEvent.event_type;
    let evTypeLabel = t("未知");
    let iconSvg = "";
    switch(evType) {
      case "created":
        evTypeLabel = t("新增");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z" fill="currentColor"/></svg>`;
        break;
      case "modified":
        evTypeLabel = t("修改");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z" fill="currentColor"/></svg>`;
        break;
      case "deleted":
        evTypeLabel = t("删除");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>`;
        break;
      case "renamed":
        evTypeLabel = t("重命名");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M19 8l-4 4h3c0 3.31-2.69 6-6 6-1.01 0-1.97-.25-2.8-.7l-1.46 1.46C8.97 19.54 10.43 20 12 20c4.42 0 8-3.58 8-8h3l-4-4zM6 12c0-3.31 2.69-6 6-6 1.01 0 1.97.25 2.8.7l1.46-1.46C15.03 4.46 13.57 4 12 4c-4.42 0-8 3.58-8 8H1l4 4 4-4H6z" fill="currentColor"/></svg>`;
        break;
    }

    const typeIcon = document.createElement("div");
    typeIcon.className = `tree-icon file-icon ${evType}`;
    typeIcon.innerHTML = iconSvg;

    const date = new Date(latestEvent.timestamp * 1000);
    const timeStr = date.toLocaleTimeString("zh-CN", { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

    const nameDetails = document.createElement("div");
    nameDetails.className = "tree-row-details";
    nameDetails.innerHTML = `
      <span class="tree-row-name">${node.name}</span>
      <span class="tree-row-sub">${timeStr}</span>
    `;

    const statusStack = document.createElement("div");
    statusStack.className = "tree-badges-stack";

    if (!latestEvent.is_synced) {
      const typeText = document.createElement("span");
      typeText.className = `tree-status-text ${evType}`;
      typeText.innerText = evTypeLabel;
      statusStack.appendChild(typeText);

      const dot = document.createElement("span");
      dot.className = "tree-status-dot";
      statusStack.appendChild(dot);
    } else {
      const checkmark = document.createElement("span");
      checkmark.className = "tree-status-checkmark";
      checkmark.innerHTML = `<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z" fill="currentColor"/></svg>`;
      statusStack.appendChild(checkmark);
    }

    row.appendChild(typeIcon);
    row.appendChild(nameDetails);
    row.appendChild(statusStack);

    row.style.paddingLeft = `${indent + 14 + 10}px`;

    row.addEventListener("click", (e) => {
      e.stopPropagation();
      
      document.querySelectorAll(".tree-row.file-row.selected").forEach(r => {
        r.classList.remove("selected");
      });
      row.classList.add("selected");
      state.selectedEventId = latestEvent.id;

      let syncStatusMsg = latestEvent.is_synced ? t("已同步到腾讯 IMA 知识库") : t("未同步，等待处理");
      showGlobalToast(`${evTypeLabel}事件: ${node.name} (${syncStatusMsg})`);
    });

    wrapper.appendChild(row);
  }

  return wrapper;
}

// Performs a bidirectional or directional sync calling the Tauri backend command
async function syncAll(direction = null) {
  if (state.isSyncing) return;
  
  let creds = await invoke("get_ima_credentials");
  if (!creds) {
    showGlobalToast("请先在设置中登录 Tencent IMA 账号", true);
    switchTab("settings");
    return;
  }

  let mappings = {};
  let boundCount = 0;
  state.monitoredPaths.forEach(path => {
    let kbId = localStorage.getItem(`kb_binding_${path}`);
    if (kbId && kbId !== "default") {
      mappings[path] = kbId;
      boundCount++;
    }
  });
  
  if (boundCount === 0) {
    showGlobalToast("请先在设置中为监控的文件夹绑定对应的 IMA 知识库", true);
    switchTab("settings");
    return;
  }
  
  state.isSyncing = true;
  state.currentSyncDirection = direction;
  
  if (dom.syncBtn) dom.syncBtn.disabled = true;
  const btnPush = document.getElementById("btn-sync-all-pending-push");
  const btnPull = document.getElementById("btn-sync-all-pending-pull");
  const btnMark = document.getElementById("btn-mark-all-synced");
  if (btnPush) btnPush.disabled = true;
  if (btnPull) btnPull.disabled = true;
  if (btnMark) btnMark.disabled = true;
  
  // Show bottom floating progress banner
  if (dom.syncBanner) {
    dom.syncBanner.classList.remove("hidden");
    if (direction === "push") {
      dom.syncBannerTitle.textContent = "正在同步至 IMA...";
      dom.syncBannerStatus.textContent = "正在扫描本地待同步的改动记录...";
    } else if (direction === "pull") {
      dom.syncBannerTitle.textContent = "正在从云端拉取更新...";
      dom.syncBannerStatus.textContent = "正在连接并获取云端知识库列表...";
    } else {
      dom.syncBannerTitle.textContent = "开始双向同步...";
      dom.syncBannerStatus.textContent = "正在准备数据...";
    }
    dom.syncBannerFill.style.width = "0%";
  }

  try {
    await invoke("sync_all_directories", { mappings, direction });
  } catch (err) {
    console.error("Sync failed:", err);
    state.isSyncing = false;
    state.currentSyncDirection = null;
    if (dom.syncBtn) dom.syncBtn.disabled = false;
    if (btnPush) btnPush.disabled = false;
    if (btnPull) btnPull.disabled = false;
    if (btnMark) btnMark.disabled = false;
    if (dom.syncBanner) dom.syncBanner.classList.add("hidden");
    showGlobalToast("同步发生错误: " + err, true);
  }
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
  const now = Date.now();
  const range = state.reportsTimeRange || "7days";
  let filtered = state.fileEvents || [];
  
  if (range === "today") {
    const startOfToday = new Date().setHours(0, 0, 0, 0);
    filtered = filtered.filter(e => (e.timestamp * 1000) >= startOfToday);
  } else if (range === "7days") {
    const startOf7DaysAgo = now - 7 * 24 * 60 * 60 * 1000;
    filtered = filtered.filter(e => (e.timestamp * 1000) >= startOf7DaysAgo);
  } else if (range === "30days") {
    const startOf30DaysAgo = now - 30 * 24 * 60 * 60 * 1000;
    filtered = filtered.filter(e => (e.timestamp * 1000) >= startOf30DaysAgo);
  }
  
  // Update Metrics
  const total = filtered.length;
  const pending = filtered.filter(e => !e.is_synced).length;
  const completed = total - pending;
  
  const statTotal = document.getElementById("reports-stat-total");
  const statPending = document.getElementById("reports-stat-pending");
  const statCompleted = document.getElementById("reports-stat-completed");
  
  if (statTotal) statTotal.textContent = total;
  if (statPending) statPending.textContent = pending;
  if (statCompleted) statCompleted.textContent = completed;
  
  // Update Type Distribution counts
  let createdCount = 0, modifiedCount = 0, deletedCount = 0, renamedCount = 0;
  filtered.forEach(e => {
    if (e.event_type === "created") createdCount++;
    else if (e.event_type === "modified") modifiedCount++;
    else if (e.event_type === "deleted") deletedCount++;
    else if (e.event_type === "renamed") renamedCount++;
  });
  
  const typeCreated = document.getElementById("reports-type-created");
  const typeModified = document.getElementById("reports-type-modified");
  const typeDeleted = document.getElementById("reports-type-deleted");
  const typeRenamed = document.getElementById("reports-type-renamed");
  
  if (typeCreated) typeCreated.textContent = createdCount;
  if (typeModified) typeModified.textContent = modifiedCount;
  if (typeDeleted) typeDeleted.textContent = deletedCount;
  if (typeRenamed) typeRenamed.textContent = renamedCount;
  
  // Render list
  const list = document.getElementById("reports-recent-list");
  const emptyState = document.getElementById("reports-empty-state");
  
  if (list) {
    list.innerHTML = "";
    if (total === 0) {
      if (emptyState) {
        emptyState.style.display = "flex";
      }
      list.style.display = "none";
    } else {
      if (emptyState) {
        emptyState.style.display = "none";
      }
      list.style.display = "flex";
      
      // Sort newest first
      const sorted = [...filtered].sort((a, b) => b.timestamp - a.timestamp);
      const subset = sorted.slice(0, 50); // top 50 recent items
      
      subset.forEach(item => {
        let cleanPath = item.path.replace(/\\/g, "/");
        let name = cleanPath.split("/").pop() || item.path;
        let timeStr = formatCompactDate(new Date(item.timestamp * 1000));
        
        let evIcon = "";
        let evClass = "created";
        
        switch(item.event_type) {
          case "created":
            evIcon = `<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z" fill="currentColor"/></svg>`;
            evClass = "created";
            break;
          case "modified":
            evIcon = `<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25z" fill="currentColor"/></svg>`;
            evClass = "modified";
            break;
          case "deleted":
            evIcon = `<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12z" fill="currentColor"/></svg>`;
            evClass = "deleted";
            break;
          case "renamed":
            evIcon = `<svg viewBox="0 0 24 24"><path d="M12.89 3L14.85 4.96L11.11 8.7H17V10.3H11.11L14.85 14.04L12.89 16L5.89 9L12.89 3Z" fill="currentColor"/></svg>`;
            evClass = "renamed";
            break;
          default:
            evIcon = `<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z" fill="currentColor"/></svg>`;
            evClass = "modified";
        }
        
        const row = document.createElement("div");
        row.className = "reports-recent-item";
        row.innerHTML = `
          <div class="item-left-group">
            <span class="type-badge ${evClass}-badge">${evIcon}</span>
            <div class="item-text">
              <span class="item-name">${name}</span>
              <span class="item-path" title="${item.path}">${item.path}</span>
            </div>
          </div>
          <div class="item-right-group">
            <span class="sync-status-pill ${item.is_synced ? 'synced' : 'pending'}">${item.is_synced ? t('已同步') : t('待同步')}</span>
            <span class="item-time">${timeStr}</span>
          </div>
        `;
        list.appendChild(row);
      });
    }
  }
}

// Compact date formatting helper
function formatCompactDate(date) {
  const now = new Date();
  const isToday = date.toDateString() === now.toDateString();
  const hours = String(date.getHours()).padStart(2, '0');
  const minutes = String(date.getMinutes()).padStart(2, '0');
  if (isToday) {
    return `${hours}:${minutes}`;
  } else {
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${month}-${day} ${hours}:${minutes}`;
  }
}

// Export files as CSV or JSON in pure browser format
function triggerExport(format) {
  const now = Date.now();
  const range = state.reportsTimeRange || "7days";
  let filtered = state.fileEvents || [];
  
  if (range === "today") {
    const startOfToday = new Date().setHours(0, 0, 0, 0);
    filtered = filtered.filter(e => (e.timestamp * 1000) >= startOfToday);
  } else if (range === "7days") {
    const startOf7DaysAgo = now - 7 * 24 * 60 * 60 * 1000;
    filtered = filtered.filter(e => (e.timestamp * 1000) >= startOf7DaysAgo);
  } else if (range === "30days") {
    const startOf30DaysAgo = now - 30 * 24 * 60 * 60 * 1000;
    filtered = filtered.filter(e => (e.timestamp * 1000) >= startOf30DaysAgo);
  }
  
  if (filtered.length === 0) {
    showGlobalToast(t("当前范围无事件记录，无法导出！"), true);
    return;
  }
  
  if (format === "csv") {
    let csv = "ID,Path,OldPath,Type,Timestamp,Synced\n";
    filtered.forEach(e => {
      let id = e.id || "";
      let path = e.path ? `"${e.path.replace(/"/g, '""')}"` : "";
      let oldPath = e.old_path ? `"${e.old_path.replace(/"/g, '""')}"` : "";
      let type = e.event_type || "";
      let time = new Date(e.timestamp * 1000).toLocaleString();
      let synced = e.is_synced ? "TRUE" : "FALSE";
      csv += `${id},${path},${oldPath},${type},${time},${synced}\n`;
    });
    
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `FileSyncMonitor_Export_${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    showGlobalToast(t("CSV 报告导出成功！"));
  } else if (format === "json") {
    const jsonStr = JSON.stringify(filtered, null, 2);
    const blob = new Blob([jsonStr], { type: "application/json;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `FileSyncMonitor_Export_${new Date().toISOString().slice(0, 10)}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    showGlobalToast(t("JSON 报告导出成功！"));
  }
}

// Hook up the segmented control filter and action buttons
function setupReportsListeners() {
  state.reportsTimeRange = "7days";
  
  const filterRadios = document.querySelectorAll('input[name="reports-time"]');
  filterRadios.forEach(radio => {
    radio.addEventListener("change", (e) => {
      state.reportsTimeRange = e.target.value;
      loadReportsTab();
    });
  });
  
  const btnCsv = document.getElementById("reports-export-csv");
  const btnJson = document.getElementById("reports-export-json");
  if (btnCsv) {
    btnCsv.addEventListener("click", () => triggerExport("csv"));
  }
  if (btnJson) {
    btnJson.addEventListener("click", () => triggerExport("json"));
  }
}

// Verify authorization state
async function checkAuthState() {
  try {
    let creds = await invoke("get_ima_credentials");
    if (creds) {
      let cachedAvatar = localStorage.getItem("user_avatar") || "";
      let cachedNickname = localStorage.getItem("user_nickname") || "";
      
      // Clean up string-coerced null/undefined values
      if (cachedAvatar === "null" || cachedAvatar === "undefined") cachedAvatar = "";
      if (cachedNickname === "null" || cachedNickname === "undefined") cachedNickname = "";
      
      cachedAvatar = ensureHttps(cachedAvatar);
      
      let fallbackName = cachedNickname || state.credentials?.nickname || (creds.uid ? `IMA 用户 ${creds.uid.slice(-4)}` : "微信用户");
      
      if (!state.credentials) {
        state.credentials = { avatar: cachedAvatar, nickname: fallbackName };
        showAuthorizedUI(cachedAvatar, fallbackName);
      }

      try {
        let [avatar, nickname] = await invoke("get_ima_user_profile", {
          token: creds.token,
          refresh_token: creds.refresh_token,
          refreshToken: creds.refresh_token,
          uid: creds.uid,
          guid: creds.guid
        });
        
        // Clean returned values and merge with cached ones to prevent overwriting with empty/default data
        let cleanAvatar = avatar;
        if (cleanAvatar === "null" || cleanAvatar === "undefined") cleanAvatar = "";
        let cleanNickname = nickname;
        if (cleanNickname === "null" || cleanNickname === "undefined") cleanNickname = "";
        
        // Prefer cached avatar if the backend returns a default/placeholder avatar
        let finalAvatar = cachedAvatar;
        if (cleanAvatar && !isDefaultAvatar(cleanAvatar)) {
          finalAvatar = cleanAvatar;
        } else if (!cachedAvatar || isDefaultAvatar(cachedAvatar)) {
          finalAvatar = cleanAvatar || defaultAvatar;
        }
        
        let finalNickname = cleanNickname || cachedNickname || fallbackName;
        
        finalAvatar = ensureHttps(finalAvatar);
        
        state.credentials = { avatar: finalAvatar, nickname: finalNickname };
        localStorage.setItem("user_avatar", finalAvatar);
        localStorage.setItem("user_nickname", finalNickname);
        showAuthorizedUI(finalAvatar, finalNickname);
      } catch (err) {
        console.error("IMA profile refresh failure:", err);
        showAuthorizedUI(ensureHttps(state.credentials?.avatar || cachedAvatar), fallbackName);
      }

    } else {
      showUnapprovedUI();
    }
  } catch (e) {
    console.error("Failed to check auth state:", e);
  }
}

async function loadAvailableKnowledgeBases() {
  try {
    let creds = await invoke("get_ima_credentials");
    if (creds) {
      state.kbLoadError = null;
      // Triggers temporary loading indicator if needed
      renderMonitoredDirectories();

      let kbs = await invoke("fetch_knowledge_bases");
      state.availableKnowledgeBases = kbs;
      state.kbLoadError = null;
      renderMonitoredDirectories();
    } else {
      state.availableKnowledgeBases = [];
      state.kbLoadError = t("请先在系统设置中登录 IMA 微信账号");
      renderMonitoredDirectories();
    }
  } catch (err) {
    console.error("Failed to load KBs:", err);
    state.availableKnowledgeBases = [];
    state.kbLoadError = String(err);
    renderMonitoredDirectories();
    showGlobalToast(`加载云端知识库失败: ${err}`, true);
  }
}

function openIMALoginWindow() {
  invoke("open_login_window").catch(e => alert("Login Window Error: " + e));
}

function openAccountSettings() {
  switchTab("settings");
  const accountRow = document.getElementById("setting-account-auth") || document.getElementById("setting-account-unauth");
  if (accountRow) {
    accountRow.scrollIntoView({ block: "center", behavior: "smooth" });
    accountRow.classList.add("settings-row-highlight");
    setTimeout(() => accountRow.classList.remove("settings-row-highlight"), 1200);
  }
}

async function fetchAndRenderSpaceQuota(creds) {
  try {
    let quota = await invoke("get_ima_space_quota", {
      token: creds.token,
      refresh_token: creds.refresh_token,
      refreshToken: creds.refresh_token,
      uid: creds.uid,
      guid: creds.guid
    });

    let fillEl = document.getElementById("quota-fill");
    let textEl = document.getElementById("quota-text");
    if (!fillEl || !textEl) return;

    if (quota) {
      let total = quota.total_quota || 0;
      let used = quota.used_quota || 0;
      let pct = total > 0 ? (used / total) * 100 : 0;
      pct = Math.min(100, Math.max(0, pct));

      fillEl.style.width = pct.toFixed(1) + "%";
      textEl.textContent = formatBytes(used) + " / " + formatBytes(total);
    }
  } catch (err) {
    console.error("Failed to fetch space quota:", err);
  }
}

function formatBytes(bytes) {
  if (!bytes || bytes === 0) return "0.0 MB";
  const mb = bytes / (1024 * 1024);
  if (mb >= 1024) {
    return (mb / 1024).toFixed(1) + " GB";
  }
  return mb.toFixed(1) + " MB";
}

// Show authorized state in settings UI
function showAuthorizedUI(avatar, nickname) {
  if (dom.accountUnauth) dom.accountUnauth.classList.add("hidden");
  if (dom.accountAuth) dom.accountAuth.classList.remove("hidden");
  
  if (dom.accountAvatar) dom.accountAvatar.src = avatar || defaultAvatar;
  if (dom.accountNickname) dom.accountNickname.textContent = nickname || t("微信用户");
  updateRailAvatar();

  // Settings UI logic
  let sUnauth = document.getElementById("setting-account-unauth");
  let sAuth = document.getElementById("setting-account-auth");
  let sQuota = document.getElementById("setting-cloud-quota");
  let sName = document.getElementById("setting-account-name");
  let connPill = document.getElementById("setting-conn-pill");
  let connDesc = document.getElementById("setting-conn-desc");
  let refBtn = document.getElementById("btn-refresh-status");

  if (sUnauth) sUnauth.classList.add("hidden");
  if (sAuth) sAuth.classList.remove("hidden");
  if (sQuota) sQuota.classList.remove("hidden");
  if (sName) sName.innerText = nickname || t("微信用户");

  if (connPill) {
      connPill.classList.remove("disconnected");
      connPill.classList.add("connected");
      connPill.innerHTML = `<svg viewBox="0 0 24 24" style="width: 14px; height: 14px; fill: currentColor;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg><span>${t("已连接")}</span>`;
  }
  if (connDesc) connDesc.innerText = t("Tencent IMA 正常连接中");
  if (refBtn) refBtn.disabled = false;
}
 
// Show unauthorized state in settings UI
function showUnapprovedUI() {
  state.credentials = null;
  if (dom.accountAuth) dom.accountAuth.classList.add("hidden");
  if (dom.accountUnauth) dom.accountUnauth.classList.remove("hidden");
  updateRailAvatar();

  // Settings UI logic
  let sUnauth = document.getElementById("setting-account-unauth");
  let sAuth = document.getElementById("setting-account-auth");
  let sQuota = document.getElementById("setting-cloud-quota");
  let connPill = document.getElementById("setting-conn-pill");
  let connDesc = document.getElementById("setting-conn-desc");
  let refBtn = document.getElementById("btn-refresh-status");

  if (sUnauth) sUnauth.classList.remove("hidden");
  if (sAuth) sAuth.classList.add("hidden");
  if (sQuota) sQuota.classList.add("hidden");

  if (connPill) {
      connPill.classList.remove("connected");
      connPill.classList.add("disconnected");
      connPill.innerHTML = `<svg viewBox="0 0 24 24" style="width: 14px; height: 14px; fill: currentColor;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg><span>${t("未连接")}</span>`;
  }
  if (connDesc) connDesc.innerText = t("未登录，请先在主页扫码");
  if (refBtn) refBtn.disabled = true;
}

async function logoutTencentIMA() {
  try {
    await invoke("clear_ima_credentials");
    state.credentials = null;
    localStorage.removeItem("user_avatar");
    localStorage.removeItem("user_nickname");
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
  
  if (dom.ignoreExts) dom.ignoreExts.value = "tmp, log, asd, part";
  if (dom.ignoreDirs) dom.ignoreDirs.value = ".git, node_modules, dist";
  
  // 5. Clear credentials
  await invoke("clear_ima_credentials");
  state.credentials = null;
  localStorage.removeItem("user_avatar");
  localStorage.removeItem("user_nickname");
  localStorage.removeItem("tourCompleted");
  localStorage.removeItem("hideIntroBanner");
  if (dom.introBannerCard) {
    dom.introBannerCard.classList.remove("hidden");
  }
  showUnapprovedUI();
  
  state.fileEvents = [];
  renderEvents();
  renderHomeRecentEvents();
  renderLargeTables();
  updateHomeStats();
  
  switchTab("events");
  showGlobalToast("应用重置成功！所有配置已还原至出厂设置。");
}

// Custom Premium Toast Notification
function showGlobalToast(message, isError = false) {
  message = t(message);
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

// -------------------------------------------------------------
// Core UI Restored Helper Operations for SwiftUI High-Fidelity
// -------------------------------------------------------------

function updateAutoSyncUI() {
  const toggle = document.getElementById("btn-toggle-autosync");
  const label = document.getElementById("home-sync-mode-label");
  const desc = document.getElementById("home-sync-mode-desc");
  const modeVal = document.getElementById("home-status-mode");
  
  if (state.autoSync) {
    if (toggle) toggle.classList.add("active");
    if (label) label.textContent = t("自动同步");
    if (desc) desc.textContent = t("检测到变更时自动同步");
    if (modeVal) modeVal.textContent = t("自动同步");
  } else {
    if (toggle) toggle.classList.remove("active");
    if (label) label.textContent = t("手动同步");
    if (desc) desc.textContent = t("点击按钮时上传");
    if (modeVal) modeVal.textContent = t("手动同步");
  }
}

// -------------------------------------------------------------
// Update home status card summary values
// -------------------------------------------------------------
function updateHomeStats() {
  const total = state.fileEvents.length;
  const pending = state.fileEvents.filter(e => !e.is_synced).length;
  const monitored = state.monitoredPaths.length;
  
  // Update metric card values
  if (dom.homeStatPending) dom.homeStatPending.textContent = pending;
  if (dom.homeStatTotal) dom.homeStatTotal.textContent = total;
  if (dom.homeStatMonitored) dom.homeStatMonitored.textContent = monitored;
  
  // Update left rail badge
  if (dom.railPendingBadge) {
    if (pending > 0) {
      dom.railPendingBadge.textContent = pending;
      dom.railPendingBadge.classList.remove("hidden");
    } else {
      dom.railPendingBadge.classList.add("hidden");
    }
  }
  
  // Update Status Summary Card
  if (dom.homeStatusQueue) {
    dom.homeStatusQueue.textContent = pending > 0 ? t("{pending} 个文件待同步").replace("{pending}", pending) : t("空");
  }
  if (dom.homeStatusPaths) {
    dom.homeStatusPaths.textContent = t("{monitored} 个").replace("{monitored}", monitored);
  }
  
  // Update Welcome Banner message dynamically based on status
  let homeSyncedBadge = document.getElementById("home-synced-badge");
  if (dom.homeMessageTitle) {
    if (monitored === 0) {
      dom.homeMessageTitle.textContent = t("添加一个目录后，文件变动会自动记录并提醒你处理。");
      if (homeSyncedBadge) homeSyncedBadge.classList.add("hidden");
    } else if (pending > 0) {
      dom.homeMessageTitle.textContent = t("捕获到 {pending} 个新的文件变动，点击右上角进行云端同步。").replace("{pending}", pending);
      if (homeSyncedBadge) homeSyncedBadge.classList.add("hidden");
    } else {
      dom.homeMessageTitle.textContent = t("所有文件均已同步至云端，运行中。");
      if (homeSyncedBadge) homeSyncedBadge.classList.remove("hidden");
    }
  }
}

function renderHomeRecentEvents() {
  if (!dom.homeRecentEventsContainer) return;
  
  // Take first 5 recent events
  const recent = state.fileEvents.slice(0, 5);
  
  if (recent.length === 0) {
    dom.homeRecentEventsContainer.innerHTML = `
      <div class="list-empty">
        <svg viewBox="0 0 24 24" width="36" height="36" fill="var(--text-muted)">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
        </svg>
        <p>开始监控后，这里会显示最新文件变动。</p>
      </div>
    `;
    return;
  }
  
  dom.homeRecentEventsContainer.innerHTML = "";
  recent.forEach(item => {
    let cleanPath = item.path.replace(/\\/g, "/");
    let baseName = cleanPath.split("/").pop() || item.path;
    
    // Format timestamp
    let date = new Date(item.timestamp * 1000);
    let timeStr = date.toLocaleTimeString("zh-CN", { hour12: false, hour: '2-digit', minute: '2-digit' });
    
    // SVG icons (SF Symbols styled)
    let typeClass = item.event_type;
    let typeIcon = "";
    switch(item.event_type) {
      case "created":
        typeIcon = `<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z" fill="currentColor"/></svg>`;
        break;
      case "modified":
        typeIcon = `<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25z" fill="currentColor"/></svg>`;
        break;
      case "deleted":
        typeIcon = `<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12z" fill="currentColor"/></svg>`;
        break;
      case "renamed":
        typeIcon = `<svg viewBox="0 0 24 24"><path d="M12.89 3L14.85 4.96L11.11 8.7H17V10.3H11.11L14.85 14.04L12.89 16L5.89 9L12.89 3Z" fill="currentColor"/></svg>`;
        break;
      default:
        typeIcon = `<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z" fill="currentColor"/></svg>`;
    }
    
    const row = document.createElement("div");
    row.className = "home-recent-event-row";
    row.innerHTML = `
      <div class="home-event-icon-badge ${typeClass}">
        ${typeIcon}
      </div>
      <div class="home-event-info">
        <div class="home-event-name" title="${baseName}">${baseName}</div>
        <div class="home-event-path" title="${item.path}">${item.path}</div>
      </div>
      <div class="home-event-time">${timeStr}</div>
    `;
    dom.homeRecentEventsContainer.appendChild(row);
  });
}

function updateRailAvatar() {
  if (!dom.btnRailAvatar) return;
  
  if (state.credentials) {
    const avatarUrl = state.credentials.avatar || defaultAvatar;
    dom.btnRailAvatar.innerHTML = `<img src="${avatarUrl}" alt="Avatar" style="width: 100%; height: 100%; object-fit: cover; border-radius: 50%;" />`;
    dom.btnRailAvatar.title = t("已绑定: {nickname} (点击查看账号状态)").replace("{nickname}", state.credentials.nickname || t("微信用户"));
  } else {
    dom.btnRailAvatar.innerHTML = `
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <circle cx="6" cy="6" r="3.5" fill="#334155" />
        <circle cx="18" cy="6" r="3.5" fill="#334155" />
        <circle cx="12" cy="12" r="9" fill="#f8fafc" stroke="#334155" stroke-width="1.5" />
        <ellipse cx="8.5" cy="11.5" rx="2" ry="2.8" transform="rotate(-15 8.5 11.5)" fill="#334155" />
        <ellipse cx="15.5" cy="11.5" rx="2" ry="2.8" transform="rotate(15 15.5 11.5)" fill="#334155" />
        <circle cx="8.5" cy="11" r="0.8" fill="#ffffff" />
        <circle cx="15.5" cy="11" r="0.8" fill="#ffffff" />
        <polygon points="12,14 10.5,12.5 13.5,12.5" fill="#334155" />
        <path d="M10.5,15.5 C11,16.2 13,16.2 13.5,15.5" fill="none" stroke="#334155" stroke-width="1" stroke-linecap="round" />
      </svg>
    `;
    dom.btnRailAvatar.title = t("未授权 (点击微信扫码登录)");
  }
}

// -------------------------------------------------------------
// Welcome Intro Card Banner Action Logic
// -------------------------------------------------------------
function setupWelcomeBannerListeners() {
  if (dom.btnCloseIntro) {
    dom.btnCloseIntro.addEventListener("click", () => {
      dom.introBannerCard.classList.add("hidden");
      localStorage.setItem("hideIntroBanner", "true");
    });
  }
  
  if (dom.btnHideIntroPermanently) {
    dom.btnHideIntroPermanently.addEventListener("click", () => {
      dom.introBannerCard.classList.add("hidden");
      localStorage.setItem("hideIntroBanner", "true");
      showGlobalToast("欢迎栏已关闭，你可以在帮助关于面板中重新激活新手引导。");
    });
  }
  
  if (dom.btnViewDocs) {
    dom.btnViewDocs.addEventListener("click", () => {
      switchTab("help");
    });
  }
  
  if (dom.btnStartTour) {
    dom.btnStartTour.addEventListener("click", () => {
      startOnboardingTour();
    });
  }
}

// -------------------------------------------------------------
// Onboarding Tour Engine (SwiftUI High-Fidelity restoration)
// -------------------------------------------------------------
function setupOnboardingTourListeners() {
  if (dom.btnTourSkip) {
    dom.btnTourSkip.addEventListener("click", () => {
      endOnboardingTour();
    });
  }
  
  if (dom.btnTourPrev) {
    dom.btnTourPrev.addEventListener("click", () => {
      if (state.currentTourStep > 0) {
        goToTourStep(state.currentTourStep - 1);
      }
    });
  }
  
  if (dom.btnTourNext) {
    dom.btnTourNext.addEventListener("click", () => {
      if (state.currentTourStep < tourSteps.length - 1) {
        goToTourStep(state.currentTourStep + 1);
      } else {
        endOnboardingTour();
        showGlobalToast("新手指引已完成！祝你使用愉快。");
      }
    });
  }

  // Bind About card button in help pane
  const btnReopenTour = document.getElementById("btn-reopen-tour");
  if (btnReopenTour) {
    btnReopenTour.addEventListener("click", () => {
      startOnboardingTour();
    });
  }
}

function startOnboardingTour() {
  state.tourActive = true;
  dom.globalTourOverlay.classList.remove("hidden");
  goToTourStep(0);
}

function endOnboardingTour() {
  state.tourActive = false;
  dom.globalTourOverlay.classList.add("hidden");
  localStorage.setItem("tourCompleted", "true");
  localStorage.setItem("hideIntroBanner", "true");
  if (dom.introBannerCard) {
    dom.introBannerCard.classList.add("hidden");
  }
}

function goToTourStep(stepIndex) {
  state.currentTourStep = stepIndex;
  const step = tourSteps[stepIndex];
  
  // Set card texts
  dom.tourStepBadge.textContent = t("引导进度_format").replace("{current}", stepIndex + 1).replace("{total}", tourSteps.length);
  dom.tourCardTitle.textContent = t(step.title);
  dom.tourCardText.textContent = t(step.text);
  
  // Set card icon
  const iconCircle = document.getElementById("tour-card-icon-circle");
  if (iconCircle) iconCircle.innerHTML = step.icon;
  
  // Set stepper dots active state
  const dots = dom.tourSteppers.querySelectorAll(".stepper-dot");
  dots.forEach((dot, idx) => {
    if (idx === stepIndex) {
      dot.className = "stepper-dot active";
      dot.style.width = "18px";
      dot.style.backgroundColor = "var(--app-mint)";
    } else {
      dot.className = "stepper-dot";
      dot.style.width = "6px";
      dot.style.backgroundColor = "var(--border-color)";
    }
  });
  
  // Configure action buttons text
  if (stepIndex === 0) {
    dom.btnTourPrev.classList.add("hidden");
  } else {
    dom.btnTourPrev.classList.remove("hidden");
  }
  
  if (stepIndex === tourSteps.length - 1) {
    dom.btnTourNextText.textContent = t("完成");
  } else {
    dom.btnTourNextText.textContent = t("下一步");
  }
  
  // Position Spotlight and pointer arrow dynamically
  updateTourPosition();
}

function updateTourPosition() {
  if (!state.tourActive) return;
  const step = tourSteps[state.currentTourStep];
  
  let target = document.getElementById(step.targetId);
  if (!target) {
    // If target is class selector or not found directly
    target = document.querySelector(`.${step.targetId}`);
  }
  
  if (!target) {
    console.error("Onboarding spotlight target not found:", step.targetId);
    return;
  }
  
  // Highlighting specific tab panes when they are hidden could offset calculations
  // Force switch tabs briefly to compile accurate dimensions if needed
  if (step.targetId === "btn-add-dir-home" || step.targetId === "home-sync-mode-container") {
    if (state.activeTab !== "events") {
      switchTab("events");
      setTimeout(updateTourPosition, 100);
      return;
    }
  }
  
  const rect = target.getBoundingClientRect();
  
  // 1. Position Spotlight Cutout
  dom.tourSpotlight.style.width = `${rect.width + 12}px`;
  dom.tourSpotlight.style.height = `${rect.height + 12}px`;
  dom.tourSpotlight.style.top = `${rect.top - 6}px`;
  dom.tourSpotlight.style.left = `${rect.left - 6}px`;
  
  // 2. Position Pointer Arrow & guide floating Tour card
  if (step.direction === "left") {
    // Pointer is placed to the right of the target pointing left (<-)
    dom.tourPointer.style.left = `${rect.right + 12}px`;
    dom.tourPointer.style.top = `${rect.top + rect.height/2 - 20}px`;
    dom.tourPointerArrow.style.transform = "rotate(0deg)";
    
    // Card is placed to the right of the pointer
    dom.tourCard.style.left = `${rect.right + 62}px`;
    let topVal = rect.top + rect.height/2 - 110;
    if (topVal < 10) topVal = 10;
    if (topVal + 280 > window.innerHeight) topVal = window.innerHeight - 290;
    dom.tourCard.style.top = `${topVal}px`;
  } else if (step.direction === "right") {
    // Pointer is placed to the left of the target pointing right (->)
    dom.tourPointer.style.left = `${rect.left - 52}px`;
    dom.tourPointer.style.top = `${rect.top + rect.height/2 - 20}px`;
    dom.tourPointerArrow.style.transform = "rotate(180deg)";
    
    // Card is placed to the left of the pointer
    dom.tourCard.style.left = `${rect.left - 382}px`;
    let topVal = rect.top + rect.height/2 - 110;
    if (topVal < 10) topVal = 10;
    if (topVal + 280 > window.innerHeight) topVal = window.innerHeight - 290;
    dom.tourCard.style.top = `${topVal}px`;
  }
}

// -------------------------------------------------------------
// Help Sub-panes segmented control listeners
// -------------------------------------------------------------
function setupHelpSegmentsListeners() {
  const segBtns = document.querySelectorAll(".help-segment-btn");
  const panes = document.querySelectorAll(".help-subpane");
  
  segBtns.forEach(btn => {
    btn.addEventListener("click", () => {
      // Toggle button active class
      segBtns.forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      
      // Toggle panes visibility
      const subTab = btn.getAttribute("data-help-tab");
      panes.forEach(pane => {
        if (pane.id === `help-subpane-${subTab}`) {
          pane.classList.remove("hidden");
        } else {
          pane.classList.add("hidden");
        }
      });
    });
  });
}

// -------------------------------------------------------------
// FAQ Collapsible Accordions Interactive Triggers
// -------------------------------------------------------------
function setupFAQAccordionListeners() {
  const accordions = document.querySelectorAll(".faq-accordion-item");
  
  accordions.forEach(item => {
    const header = item.querySelector(".faq-accordion-header");
    header.addEventListener("click", () => {
      const isExpanded = item.classList.contains("expanded");
      
      // Close other accordions for premium clean accordion slide experience
      accordions.forEach(acc => {
        acc.classList.remove("expanded");
      });
      
      if (!isExpanded) {
        item.classList.add("expanded");
      }
    });
  });
}

// -------------------------------------------------------------
// Large Consolidated Tables renders & action triggers
// -------------------------------------------------------------
function setupLargeTablesListeners() {
  // View mode segmented control toggle
  const pendingViewToggle = document.getElementById("pending-view-toggle");
  if (pendingViewToggle) {
    pendingViewToggle.querySelectorAll(".segment-btn").forEach(btn => {
      btn.addEventListener("click", () => {
        pendingViewToggle.querySelectorAll(".segment-btn").forEach(b => b.classList.remove("active"));
        btn.classList.add("active");
        state.pendingViewMode = btn.getAttribute("data-view");
        
        // Render and toggle containers
        if (state.pendingViewMode === "list") {
          dom.pendingListViewContainer.classList.remove("hidden");
          dom.pendingTreeViewContainer.classList.add("hidden");
        } else {
          dom.pendingListViewContainer.classList.add("hidden");
          dom.pendingTreeViewContainer.classList.remove("hidden");
        }
        renderLargeTables();
      });
    });
  }

  // Pending Table search box filtering
  if (dom.pendingSearchBox) {
    dom.pendingSearchBox.addEventListener("input", (e) => {
      state.pendingSearchQuery = e.target.value.toLowerCase().trim();
      renderLargeTables();
    });
  }
  
  // Sync all pending events trigger
  const btnPush = document.getElementById("btn-sync-all-pending-push");
  if (btnPush) {
    btnPush.addEventListener("click", () => {
      syncAll("push");
    });
  }
  
  const btnPull = document.getElementById("btn-sync-all-pending-pull");
  if (btnPull) {
    btnPull.addEventListener("click", () => {
      syncAll("pull");
    });
  }
  
  const btnMark = document.getElementById("btn-mark-all-synced");
  if (btnMark) {
    btnMark.addEventListener("click", async () => {
      if (state.isSyncing) return;
      
      const confirmMark = confirm(t("确定要将所有待同步文件标记为已完成吗？此操作仅修改本地状态，不会上传/下载腾讯云。"));
      if (!confirmMark) return;
      
      try {
        state.isSyncing = true;
        if (dom.syncBtn) dom.syncBtn.disabled = true;
        if (btnPush) btnPush.disabled = true;
        if (btnPull) btnPull.disabled = true;
        if (btnMark) btnMark.disabled = true;
        
        await invoke("mark_all_events_synced");
        
        showGlobalToast("已成功将所有待同步项标记为已同步。");
      } catch (err) {
        console.error("Mark all synced failed:", err);
        showGlobalToast("标记已同步失败: " + err, true);
      } finally {
        state.isSyncing = false;
        if (dom.syncBtn) dom.syncBtn.disabled = false;
        if (btnPush) btnPush.disabled = false;
        if (btnPull) btnPull.disabled = false;
        if (btnMark) btnMark.disabled = false;
        fetchEvents();
      }
    });
  }
  
  // All Records Table search box filtering
  if (dom.allSearchBox) {
    dom.allSearchBox.addEventListener("input", (e) => {
      state.allSearchQuery = e.target.value.toLowerCase().trim();
      renderLargeTables();
    });
  }

  // Pending Category Filter Segmented Control
  const pendingFilterSegmented = document.getElementById("pending-filter-segmented");
  if (pendingFilterSegmented) {
    pendingFilterSegmented.querySelectorAll(".filter-seg-btn").forEach(btn => {
      btn.addEventListener("click", () => {
        pendingFilterSegmented.querySelectorAll(".filter-seg-btn").forEach(b => b.classList.remove("active"));
        btn.classList.add("active");
        state.pendingFilterType = btn.getAttribute("data-filter");
        
        // Reset selections to avoid displaying stale data from other categories
        state.selectedPendingEventId = null;
        state.selectedPendingNode = null;
        
        renderLargeTables();
        updatePendingDetailPanel();
      });
    });
  }

  // Pending empty state redirects
  const btnAddDirPendingEmpty = document.getElementById("btn-add-dir-pending-empty");
  if (btnAddDirPendingEmpty) {
    btnAddDirPendingEmpty.addEventListener("click", () => {
      switchTab("settings");
      addFolder();
    });
  }

  const btnViewAllPendingEmpty = document.getElementById("btn-view-all-pending-empty");
  if (btnViewAllPendingEmpty) {
    btnViewAllPendingEmpty.addEventListener("click", () => {
      switchTab("all");
    });
  }
}

// Consolidated rendering for large tables and tree views
function renderLargeTables() {
  renderPendingTable();
  renderPendingTree();
  renderAllTable();
  updatePendingDetailPanel();
}

// 1. Renders the Pending Table (待同步)
function renderPendingTable() {
  if (!dom.pendingEventsTableBody) return;
  
  let allPending = state.fileEvents.filter(e => !e.is_synced);
  let totalPendingCount = allPending.length;
  
  // Real-time badge updates (Sidebar badge and Global Rail icon badge)
  const countBadge = document.getElementById("pending-count-badge");
  if (countBadge) {
    countBadge.innerText = totalPendingCount;
  }
  if (dom.railPendingBadge) {
    dom.railPendingBadge.innerText = totalPendingCount;
    if (totalPendingCount > 0) {
      dom.railPendingBadge.classList.remove("hidden");
    } else {
      dom.railPendingBadge.classList.add("hidden");
    }
  }
  
  let pendingEvents = allPending;
  
  // Apply category filtering
  if (state.pendingFilterType && state.pendingFilterType !== "all") {
    pendingEvents = pendingEvents.filter(e => e.event_type === state.pendingFilterType);
  }
  
  // Apply search query filtering
  if (state.pendingSearchQuery) {
    pendingEvents = pendingEvents.filter(e => e.path.toLowerCase().includes(state.pendingSearchQuery));
  }
  
  // Render Sidebar empty state if list is empty after filtering
  if (pendingEvents.length === 0) {
    dom.pendingEventsTableBody.innerHTML = `
      <div class="list-empty fade-in-animate" style="padding: 60px 16px; text-align: center; color: var(--text-secondary); display: flex; flex-direction: column; align-items: center; justify-content: center; box-sizing: border-box; width: 100%;">
        <div style="width: 44px; height: 44px; border-radius: 50%; background: var(--app-mint-glow); color: var(--app-mint); display: flex; align-items: center; justify-content: center; margin-bottom: 12px;">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
        </div>
        <p style="font-size: 0.82rem; font-weight: 600; color: var(--text-primary); margin-bottom: 4px;">没有待同步文件</p>
        <p style="font-size: 0.72rem; color: var(--text-secondary);">所有变动都已处理完成。</p>
      </div>
    `;
    return;
  }
  
  dom.pendingEventsTableBody.innerHTML = "";
  pendingEvents.forEach(item => {
    let cleanPath = item.path.replace(/\\/g, "/");
    let baseName = cleanPath.split("/").pop() || item.path;
    
    let date = new Date(item.timestamp * 1000);
    // Compact HH:MM timestamp
    let timeStr = date.toLocaleTimeString("zh-CN", { hour12: false, hour: '2-digit', minute: '2-digit' });
    
    let typeClass = item.event_type;
    let typeLabel = t("未知");
    switch(item.event_type) {
      case "created": typeLabel = t("新增"); break;
      case "modified": typeLabel = t("修改"); break;
      case "deleted": typeLabel = t("删除"); break;
      case "renamed": typeLabel = t("重命名"); break;
    }
    
    const row = document.createElement("div");
    row.className = "pending-list-item fade-in-animate";
    if (state.selectedPendingEventId === item.id) {
      row.classList.add("selected");
    }
    
    row.innerHTML = `
      <div class="pending-item-main" style="width: 100%; display: flex; flex-direction: column;">
        <div class="pending-item-title-row">
          <span class="pending-item-filename" title="${baseName}">${baseName}</span>
          <span class="pending-item-time">${timeStr}</span>
        </div>
        <div class="pending-item-sub-row">
          <span class="event-type-badge ${typeClass}">${typeLabel}</span>
          <span class="pending-item-path" title="${item.path}">${item.path}</span>
        </div>
      </div>
    `;
    
    // Bind selection event handler
    row.addEventListener("click", () => {
      state.selectedPendingEventId = item.id;
      state.selectedPendingNode = {
        type: "file",
        event: item
      };
      
      // Clean up other selection states (list items and tree rows)
      document.querySelectorAll("#tab-pane-pending .pending-list-item").forEach(r => {
        r.classList.remove("selected");
      });
      document.querySelectorAll("#tab-pane-pending .tree-row").forEach(r => {
        r.classList.remove("selected");
      });
      
      row.classList.add("selected");
      updatePendingDetailPanel();
    });
    
    dom.pendingEventsTableBody.appendChild(row);
  });
}

// 2. Renders the All Records Table (全部记录)
function renderAllTable() {
  if (!dom.allEventsTableBody) return;
  
  let allEvents = state.fileEvents;
  
  // Search filtering
  if (state.allSearchQuery) {
    allEvents = allEvents.filter(e => e.path.toLowerCase().includes(state.allSearchQuery));
  }
  
  // Segment tab filtering
  if (state.allFilterType === "synced") {
    allEvents = allEvents.filter(e => e.is_synced);
  } else if (state.allFilterType === "pending") {
    allEvents = allEvents.filter(e => !e.is_synced);
  }
  
  if (allEvents.length === 0) {
    dom.allEventsTableBody.innerHTML = `
      <div class="list-empty" style="padding: 40px 0;">
        <svg viewBox="0 0 24 24" width="36" height="36" fill="var(--text-muted)">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
        </svg>
        <p>暂无相关历史变更记录</p>
      </div>
    `;
    return;
  }
  
  dom.allEventsTableBody.innerHTML = "";
  allEvents.forEach(item => {
    let cleanPath = item.path.replace(/\\/g, "/");
    let baseName = cleanPath.split("/").pop() || item.path;
    
    let date = new Date(item.timestamp * 1000);
    let timeStr = date.toLocaleTimeString("zh-CN", { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
    
    let typeClass = item.event_type;
    let typeLabel = t("未知");
    switch(item.event_type) {
      case "created": typeLabel = t("新增"); break;
      case "modified": typeLabel = t("修改"); break;
      case "deleted": typeLabel = t("删除"); break;
      case "renamed": typeLabel = t("重命名"); break;
    }
    
    const row = document.createElement("div");
    row.className = `events-table-row ${item.is_synced ? 'synced' : 'pending'}`;
    
    let statusPill = item.is_synced ? `
      <span class="status-pill mint">
        <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" fill="currentColor"/></svg>
        <span>${t("已同步")}</span>
      </span>
    ` : `
      <span class="status-pill amber">
        <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="currentColor"/></svg>
        <span>${t("待同步")}</span>
      </span>
    `;
    
    let actionArea = item.is_synced ? `
      <span style="font-size: 0.76rem; color: var(--text-muted); font-weight: 500;">${t("已归档")}</span>
    ` : `
      <button class="pill-btn primary table-action-btn" data-id="${item.id}" style="padding: 4px 10px; font-size: 0.74rem;">同步</button>
    `;
    
    row.innerHTML = `
      <div>${statusPill}</div>
      <div>
        <span class="event-type-badge ${typeClass}">${typeLabel}</span>
      </div>
      <div style="font-weight: 500; color: var(--text-primary); text-align: left;" title="${item.path}">${baseName}
        <span style="display: block; font-size: 0.72rem; color: var(--text-secondary); font-weight: 400; margin-top: 2px;">${item.path}</span>
      </div>
      <div style="color: var(--text-secondary);">${timeStr}</div>
      <div style="text-align: right; display: flex; justify-content: flex-end; align-items: center;">
        ${actionArea}
      </div>
    `;
    
    // Bind table row buttons for unsynced rows
    if (!item.is_synced) {
      const btn = row.querySelector(".table-action-btn");
      if (btn) {
        btn.addEventListener("click", async () => {
          const id = btn.getAttribute("data-id");
          btn.innerHTML = `<div class="spinner" style="width: 10px; height: 10px; border-width: 1px;"></div>`;
          btn.disabled = true;
          
          await new Promise(resolve => setTimeout(resolve, 500));
          try {
            await invoke("mark_event_synced", { id });
            showGlobalToast("历史变动同步成功！");
            await fetchEvents();
          } catch (err) {
            showGlobalToast("同步失败: " + err, true);
            btn.innerHTML = t("同步");
            btn.disabled = false;
          }
        });
      }
    }
    
    dom.allEventsTableBody.appendChild(row);
  });
}

// ==========================================
// Settings UI Logic Injection (Native macOS Replica)
// ==========================================

document.addEventListener("DOMContentLoaded", async () => {
    // Wait for DOM to settle
    setTimeout(async () => {
        // --- 1. Interface Group ---
        const langSelect = document.getElementById("setting-language");
        if (langSelect) {
            langSelect.value = localStorage.getItem("appLanguage") || "system";
            langSelect.addEventListener("change", (e) => {
                switchLanguage(e.target.value);
            });
        }

        const appSystem = document.getElementById("appearance-system");
        const appLight = document.getElementById("appearance-light");
        const appDark = document.getElementById("appearance-dark");
        let curApp = localStorage.getItem("appearance") || "system";
        if (curApp === "light" && appLight) appLight.checked = true;
        else if (curApp === "dark" && appDark) appDark.checked = true;
        else if (appSystem) appSystem.checked = true;

        const updateAppearance = (val) => {
            localStorage.setItem("appearance", val);
            let theme = val;
            if (val === "system") {
                theme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
            }
            
            // Set data-theme on html (documentElement) and body
            document.documentElement.setAttribute('data-theme', theme);
            document.body.setAttribute('data-theme', theme);
            
            // Set dark-mode class on html (documentElement) and body
            if (theme === 'dark') {
                document.documentElement.classList.add('dark-mode');
                document.body.classList.add('dark-mode');
            } else {
                document.documentElement.classList.remove('dark-mode');
                document.body.classList.remove('dark-mode');
            }

            // Inform Tauri backend of the window theme change so native traffic lights / decoration styles match
            invoke("set_window_theme", { theme }).catch((e) => console.error("Failed to set window theme:", e));
        };

        // Apply immediately during initialization
        updateAppearance(curApp);

        if (appSystem) appSystem.addEventListener("change", () => updateAppearance("system"));
        if (appLight) appLight.addEventListener("change", () => updateAppearance("light"));
        if (appDark) appDark.addEventListener("change", () => updateAppearance("dark"));

        // Listen for system theme changes to dynamically update when "Follow System" is selected
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
            const current = localStorage.getItem("appearance") || "system";
            if (current === "system") {
                updateAppearance("system");
            }
        });

        // --- 2. Sync Group ---
        const autoSyncToggle = document.getElementById("setting-auto-sync");
        const syncDesc = document.getElementById("sync-mode-desc");
        if (autoSyncToggle) {
            autoSyncToggle.checked = (localStorage.getItem("autoSync") === "true");
            syncDesc.innerText = autoSyncToggle.checked ? t("自动同步：文件稳定 30 秒后上传到云端") : t("手动同步：点击同步按钮时上传");
            autoSyncToggle.addEventListener("change", (e) => {
                localStorage.setItem("autoSync", e.target.checked);
                syncDesc.innerText = e.target.checked ? t("自动同步：文件稳定 30 秒后上传到云端") : t("手动同步：点击同步按钮时上传");
            });
        }

        const logoutBtnSetting = document.getElementById("btn-logout-ima-setting");
        if (logoutBtnSetting) {
            logoutBtnSetting.addEventListener("click", async () => {
                try {
                    await logoutTencentIMA();
                    refreshAppStatus();
                } catch(e) {
                    showGlobalToast("登出失败: " + e, true);
                }
            });
        }

        const reauthBtnSetting = document.getElementById("btn-reauth-ima-setting");
        if (reauthBtnSetting) {
            reauthBtnSetting.addEventListener("click", openIMALoginWindow);
        }

        // --- 3. Notifications & Export Group ---
        const launchLoginToggle = document.getElementById("setting-launch-at-login");
        if (launchLoginToggle) {
            // Fetch initial state
            try {
                let isLaunch = await invoke("get_launch_at_login");
                launchLoginToggle.checked = isLaunch;
            } catch(e) {}
            launchLoginToggle.addEventListener("change", async (e) => {
                try {
                    await invoke("set_launch_at_login", { enable: e.target.checked });
                    showGlobalToast(e.target.checked ? "已添加开机启动项" : "已移除开机启动项");
                } catch(err) {
                    showGlobalToast("设置开机启动失败: " + err, true);
                    e.target.checked = !e.target.checked;
                }
            });
        }

        const notifyToggle = document.getElementById("setting-notifications");
        if (notifyToggle) {
            let n = localStorage.getItem("notifyOnChanges");
            notifyToggle.checked = (n !== "false"); // true by default
            notifyToggle.addEventListener("change", (e) => {
                localStorage.setItem("notifyOnChanges", e.target.checked);
            });
        }

        const expCsv = document.getElementById("export-csv");
        const expJson = document.getElementById("export-json");
        let defExp = localStorage.getItem("defaultExportFormat") || "csv";
        if (defExp === "json" && expJson) expJson.checked = true;
        
        if (expCsv) expCsv.addEventListener("change", () => localStorage.setItem("defaultExportFormat", "csv"));
        if (expJson) expJson.addEventListener("change", () => localStorage.setItem("defaultExportFormat", "json"));

        const retSelect = document.getElementById("setting-retention");
        if (retSelect) {
            retSelect.value = localStorage.getItem("retentionDays") || "365";
            retSelect.addEventListener("change", (e) => {
                localStorage.setItem("retentionDays", e.target.value);
            });
        }

        // --- 4. Ignore Rules Group ---
        const defaultIgnToggle = document.getElementById("setting-default-ignore");
        const ignFile = document.getElementById("setting-ignore-filenames");
        const ignExt = document.getElementById("setting-ignore-exts");
        const ignDir = document.getElementById("setting-ignore-dirs");
        const btnResetIgn = document.getElementById("btn-reset-ignore");

        const loadIgnoreConfig = async () => {
            let e = await invoke("get_config_value", { key: "enableDefaultIgnoreRules" });
            if (defaultIgnToggle) defaultIgnToggle.checked = (e !== "false");
            
            let fn = await invoke("get_config_value", { key: "customIgnoredFileNames" });
            if (ignFile) ignFile.value = fn || "";

            let exts = await invoke("get_config_value", { key: "customIgnoredExtensions" });
            if (ignExt) ignExt.value = exts || "tmp, log, asd, part";

            let dirs = await invoke("get_config_value", { key: "customIgnoredDirectoryNames" });
            if (ignDir) ignDir.value = dirs || ".git, node_modules, dist";
        };

        const saveIgnoreConfig = async () => {
            if (defaultIgnToggle) await invoke("set_config_value", { key: "enableDefaultIgnoreRules", value: defaultIgnToggle.checked.toString() });
            if (ignFile) await invoke("set_config_value", { key: "customIgnoredFileNames", value: ignFile.value });
            if (ignExt) await invoke("set_config_value", { key: "customIgnoredExtensions", value: ignExt.value });
            if (ignDir) await invoke("set_config_value", { key: "customIgnoredDirectoryNames", value: ignDir.value });
            await invoke("update_ignore_rules").catch(()=>{});
        };

        // Load initially
        loadIgnoreConfig();

        // Save on change
        if (defaultIgnToggle) defaultIgnToggle.addEventListener("change", saveIgnoreConfig);
        if (ignFile) ignFile.addEventListener("blur", saveIgnoreConfig);
        if (ignExt) ignExt.addEventListener("blur", saveIgnoreConfig);
        if (ignDir) ignDir.addEventListener("blur", saveIgnoreConfig);
        if (btnResetIgn) {
            btnResetIgn.addEventListener("click", async () => {
                await invoke("set_config_value", { key: "customIgnoredExtensions", value: "tmp, log, asd, part" });
                await invoke("set_config_value", { key: "customIgnoredDirectoryNames", value: ".git, node_modules, dist" });
                await loadIgnoreConfig();
                await invoke("update_ignore_rules").catch(()=>{});
                showGlobalToast("忽略规则已恢复默认");
            });
        }

        // --- 5. HTTP Logs Dialog ---
        const openLogsDialog = () => {
            if (dom.overlayHttpLogs) {
                dom.overlayHttpLogs.classList.remove("hidden");
                loadAndRenderHttpLogs();
            }
        };
        if (dom.btnShowLogs) {
            dom.btnShowLogs.addEventListener("click", openLogsDialog);
        }
        if (dom.btnShowLogsDedicated) {
            dom.btnShowLogsDedicated.addEventListener("click", openLogsDialog);
        }
        if (dom.btnCloseLogs) {
            dom.btnCloseLogs.addEventListener("click", () => {
                if (dom.overlayHttpLogs) {
                    dom.overlayHttpLogs.classList.add("hidden");
                }
            });
        }
        if (dom.overlayHttpLogs) {
            dom.overlayHttpLogs.addEventListener("click", (e) => {
                if (e.target === dom.overlayHttpLogs) {
                    dom.overlayHttpLogs.classList.add("hidden");
                }
            });
        }
        if (dom.btnClearLogs) {
            dom.btnClearLogs.addEventListener("click", async () => {
                try {
                    await invoke("clear_http_logs");
                    loadAndRenderHttpLogs();
                    showGlobalToast(t("已成功清空日志"));
                } catch(e) {
                    showGlobalToast(t("清空日志失败: ") + e, true);
                }
            });
        }
        
    }, 500);
});

// ==========================================================================
// Pending Tab Dual-View Tree & Details Panel Implementations
// ==========================================================================

// 1. Render hierarchical Pending Tree (待同步树形视图)
function renderPendingTree() {
  if (!dom.pendingTreeViewContainer) return;

  let pendingEvents = state.fileEvents.filter(e => !e.is_synced);

  // Apply category filtering
  if (state.pendingFilterType && state.pendingFilterType !== "all") {
    pendingEvents = pendingEvents.filter(e => e.event_type === state.pendingFilterType);
  }

  // Apply search query filtering
  if (state.pendingSearchQuery) {
    pendingEvents = pendingEvents.filter(e => e.path.toLowerCase().includes(state.pendingSearchQuery));
  }

  if (pendingEvents.length === 0) {
    dom.pendingTreeViewContainer.innerHTML = `
      <div class="list-empty fade-in-animate" style="padding: 60px 16px; text-align: center; color: var(--text-secondary); display: flex; flex-direction: column; align-items: center; justify-content: center; box-sizing: border-box; width: 100%;">
        <div style="width: 44px; height: 44px; border-radius: 50%; background: var(--app-mint-glow); color: var(--app-mint); display: flex; align-items: center; justify-content: center; margin-bottom: 12px;">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
        </div>
        <p style="font-size: 0.82rem; font-weight: 600; color: var(--text-primary); margin-bottom: 4px;">没有待同步文件</p>
        <p style="font-size: 0.72rem; color: var(--text-secondary);">没有符合当前筛选条件的待同步文件。</p>
      </div>
    `;
    return;
  }

  // Build tree containing only pending events
  const treeRoots = buildEventTree(pendingEvents, state.monitoredPaths);

  // Auto-expand tree roots so user gets direct access
  treeRoots.forEach(root => {
    state.expandedPaths.add(root.path);
  });

  dom.pendingTreeViewContainer.innerHTML = "";
  treeRoots.forEach(node => {
    dom.pendingTreeViewContainer.appendChild(renderPendingTreeNodeDOM(node, 0));
  });
}

// 2. Recursive pending tree node renderer
function renderPendingTreeNodeDOM(node, depth) {
  const wrapper = document.createElement("div");
  wrapper.className = "tree-node-wrapper";

  const row = document.createElement("div");
  const indent = depth * 16;
  row.style.paddingLeft = `${indent + 10}px`;

  // Determine selection highlight in detail panel
  const isSelected = state.selectedPendingEventId === node.path || 
                     (node.events && node.events.length > 0 && state.selectedPendingEventId === node.events[0].id);
  if (isSelected) {
    row.classList.add("selected");
  }

  if (node.isDirectory) {
    row.className = "tree-row directory-row";
    
    // Auto-expand directories under search mode, otherwise respect state cache
    const isExpanded = state.pendingSearchQuery ? true : state.expandedPaths.has(node.path);
    
    const arrow = document.createElement("div");
    arrow.className = `tree-arrow ${isExpanded ? 'expanded' : ''}`;
    arrow.innerHTML = `<svg viewBox="0 0 24 24"><path d="M8.59 16.59L13.17 12 8.59 7.41 10 6l6 6-6 6-6 6-1.41-1.41z" fill="currentColor"/></svg>`;
    
    const folderIcon = document.createElement("div");
    folderIcon.className = "tree-icon directory-icon";
    folderIcon.innerHTML = isExpanded 
      ? `<svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-2 12H4V8h16v10z" fill="currentColor"/></svg>`
      : `<svg viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>`;

    const name = document.createElement("div");
    name.className = "tree-row-details";
    name.innerHTML = `<span class="tree-row-name">${node.name}</span>`;

    const badgeStack = document.createElement("div");
    badgeStack.className = "tree-badges-stack";

    if (node.pendingCount > 0) {
      const pBadge = document.createElement("span");
      pBadge.className = "tree-badge pending";
      pBadge.innerText = node.pendingCount;
      badgeStack.appendChild(pBadge);
    }

    row.appendChild(arrow);
    row.appendChild(folderIcon);
    row.appendChild(name);
    row.appendChild(badgeStack);

    // Children tree sub-container supporting CSS Grid Auto-Height Transitions
    const childrenContainer = document.createElement("div");
    childrenContainer.className = `tree-children-container ${isExpanded ? '' : 'collapsed'}`;
    
    const childrenInner = document.createElement("div");
    childrenInner.className = "tree-children-inner";
    
    node.children.forEach(child => {
      childrenInner.appendChild(renderPendingTreeNodeDOM(child, depth + 1));
    });

    node.events.forEach(event => {
      const leafNode = {
        path: event.path,
        name: event.path.split("/").pop() || event.path,
        isDirectory: false,
        events: [event],
        pendingCount: 1,
        totalCount: 1
      };
      childrenInner.appendChild(renderPendingTreeNodeDOM(leafNode, depth + 1));
    });

    childrenContainer.appendChild(childrenInner);

    // Clicking folder node selects the folder AND toggles collapse
    row.addEventListener("click", (e) => {
      e.stopPropagation();
      
      state.selectedPendingEventId = node.path;
      state.selectedPendingNode = {
        type: "directory",
        name: node.name,
        path: node.path,
        pendingCount: node.pendingCount,
        events: getPendingEventsUnderNode(node)
      };
      
      document.querySelectorAll("#tab-pane-pending .tree-row.selected").forEach(r => {
        r.classList.remove("selected");
      });
      document.querySelectorAll("#tab-pane-pending .events-table-row.selected").forEach(r => {
        r.classList.remove("selected");
      });
      row.classList.add("selected");
      
      const isCollapsed = childrenContainer.classList.contains("collapsed");
      if (isCollapsed) {
        state.expandedPaths.add(node.path);
        arrow.classList.add("expanded");
        childrenContainer.classList.remove("collapsed");
        folderIcon.innerHTML = `<svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-2 12H4V8h16v10z" fill="currentColor"/></svg>`;
      } else {
        if (e.target.closest(".tree-arrow") || e.target.closest(".directory-icon")) {
          state.expandedPaths.delete(node.path);
          arrow.classList.remove("expanded");
          childrenContainer.classList.add("collapsed");
          folderIcon.innerHTML = `<svg viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>`;
        }
      }
      
      updatePendingDetailPanel();
    });

    wrapper.appendChild(row);
    wrapper.appendChild(childrenContainer);

  } else {
    // File node rendering
    row.className = "tree-row file-row";
    
    const latestEvent = node.events[0];
    const evType = latestEvent.event_type;
    let evTypeLabel = t("未知");
    let iconSvg = "";
    switch(evType) {
      case "created":
        evTypeLabel = t("新增");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z" fill="currentColor"/></svg>`;
        break;
      case "modified":
        evTypeLabel = t("修改");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z" fill="currentColor"/></svg>`;
        break;
      case "deleted":
        evTypeLabel = t("删除");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z" fill="currentColor"/></svg>`;
        break;
      case "renamed":
        evTypeLabel = t("重命名");
        iconSvg = `<svg viewBox="0 0 24 24"><path d="M19 8l-4 4h3c0 3.31-2.69 6-6 6-1.01 0-1.97-.25-2.8-.7l-1.46 1.46C8.97 19.54 10.43 20 12 20c4.42 0 8-3.58 8-8h3l-4-4zM6 12c0-3.31 2.69-6 6-6 1.01 0 1.97.25 2.8.7l1.46-1.46C15.03 4.46 13.57 4 12 4c-4.42 0-8 3.58-8 8H1l4 4 4-4H6z" fill="currentColor"/></svg>`;
        break;
    }

    const typeIcon = document.createElement("div");
    typeIcon.className = `tree-icon file-icon ${evType}`;
    typeIcon.innerHTML = iconSvg;

    const date = new Date(latestEvent.timestamp * 1000);
    const timeStr = date.toLocaleTimeString("zh-CN", { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

    const nameDetails = document.createElement("div");
    nameDetails.className = "tree-row-details";
    nameDetails.innerHTML = `
      <span class="tree-row-name">${node.name}</span>
      <span class="tree-row-sub">${timeStr}</span>
    `;

    const statusStack = document.createElement("div");
    statusStack.className = "tree-badges-stack";

    const typeText = document.createElement("span");
    typeText.className = `tree-status-text ${evType}`;
    typeText.innerText = evTypeLabel;
    statusStack.appendChild(typeText);

    const dot = document.createElement("span");
    dot.className = "tree-status-dot";
    statusStack.appendChild(dot);

    row.appendChild(typeIcon);
    row.appendChild(nameDetails);
    row.appendChild(statusStack);

    row.style.paddingLeft = `${indent + 14 + 10}px`;

    row.addEventListener("click", (e) => {
      e.stopPropagation();
      
      state.selectedPendingEventId = latestEvent.id;
      state.selectedPendingNode = {
        type: "file",
        event: latestEvent
      };
      
      document.querySelectorAll("#tab-pane-pending .tree-row.selected").forEach(r => {
        r.classList.remove("selected");
      });
      document.querySelectorAll("#tab-pane-pending .events-table-row.selected").forEach(r => {
        r.classList.remove("selected");
      });
      row.classList.add("selected");
      
      updatePendingDetailPanel();
    });

    wrapper.appendChild(row);
  }

  return wrapper;
}

// 3. Helper to recursively collect all pending events under a directory node
function getPendingEventsUnderNode(node) {
  let events = [];
  if (node.events && node.events.length > 0) {
    events = events.concat(node.events.filter(e => !e.is_synced));
  }
  if (node.children) {
    node.children.forEach(child => {
      events = events.concat(getPendingEventsUnderNode(child));
    });
  }
  return events;
}

// 4. Update and dynamically render Detail Panel Content
function updatePendingDetailPanel() {
  if (!dom.pendingDetailPanel) return;

  const node = state.selectedPendingNode;
  const totalPending = state.fileEvents.filter(e => !e.is_synced).length;

  if (!node) {
    if (dom.pendingEmptyState) dom.pendingEmptyState.classList.remove("hidden");
    if (dom.pendingDetailPanel) dom.pendingDetailPanel.classList.add("hidden");

    if (totalPending === 0) {
      if (dom.pendingEmptyStatusHeading) dom.pendingEmptyStatusHeading.innerText = t("所有文件都已同步");
      if (dom.pendingEmptyStatusSubheading) dom.pendingEmptyStatusSubheading.innerText = t("新的文件变动会自动出现在左侧列表。");
    } else {
      if (dom.pendingEmptyStatusHeading) dom.pendingEmptyStatusHeading.innerText = t("未选择文件变动");
      if (dom.pendingEmptyStatusSubheading) dom.pendingEmptyStatusSubheading.innerText = t("请在左侧选择要同步的文件以查看详情。");
    }
    return;
  }

  if (dom.pendingEmptyState) dom.pendingEmptyState.classList.add("hidden");
  if (dom.pendingDetailPanel) dom.pendingDetailPanel.classList.remove("hidden");

  if (node.type === "file") {
    const item = node.event;
    let cleanPath = item.path.replace(/\\/g, "/");
    let baseName = cleanPath.split("/").pop() || item.path;
    let fileExt = baseName.includes('.') ? baseName.split('.').pop().toUpperCase() : t('无');

    let date = new Date(item.timestamp * 1000);
    let timeStr = date.toLocaleString("zh-CN", { hour12: false });

    let typeClass = item.event_type;
    let typeLabel = t("未知");
    switch(item.event_type) {
      case "created": typeLabel = t("新增"); break;
      case "modified": typeLabel = t("修改"); break;
      case "deleted": typeLabel = t("删除"); break;
      case "renamed": typeLabel = t("重命名"); break;
    }

    // Find matching monitored path and its knowledge base binding
    let matchedRoot = null;
    for (const p of state.monitoredPaths) {
      let cleanP = p.replace(/\\/g, "/");
      let cleanPath = item.path.replace(/\\/g, "/");
      if (cleanPath.startsWith(cleanP)) {
        matchedRoot = p;
        break;
      }
    }

    let kbId = matchedRoot ? localStorage.getItem(`kb_binding_${matchedRoot}`) : null;
    let kbName = t("未绑定/无");
    let isBound = false;
    if (kbId && kbId !== "default") {
      isBound = true;
      let kb = state.availableKnowledgeBases.find(k => k.id === kbId || k.kb_id === kbId);
      kbName = kb ? (kb.name || kb.title) : kbId;
    }

    let isDir = item.is_directory;
    let iconClass = isDir ? "directory" : getFileExtClass(baseName);
    let iconSvg = getFileIcon(baseName, isDir);

    dom.pendingDetailPanel.innerHTML = `
      <div class="pending-detail-panel">
        <div class="detail-header">
          <div class="detail-icon-container ${iconClass}">${iconSvg}</div>
          <div style="flex: 1; min-width: 0;">
            <h2 class="outfit-font" style="margin: 0 0 4px 0; font-size: 1.1rem; color: var(--text-primary); font-weight: 700; word-break: break-all;" title="${baseName}">${baseName}</h2>
            <span class="event-type-badge ${typeClass}">${typeLabel}</span>
          </div>
        </div>

        <div class="detail-meta-list">
          <div class="detail-meta-item">
            <span class="detail-meta-label">文件类型</span>
            <span class="detail-meta-value">${isDir ? t("文件夹") : (fileExt + t(" 文件"))}</span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-meta-label">捕获时间</span>
            <span class="detail-meta-value">${timeStr}</span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-meta-label">完整路径</span>
            <span class="detail-meta-value" style="font-family: monospace; font-size: 0.74rem;">${item.path}</span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-meta-label">绑定知识库</span>
            <span class="detail-meta-value" style="font-weight: 600;">${kbName}</span>
          </div>
        </div>

        ${!isBound ? `
          <div class="detail-binding-warning">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" style="flex-shrink:0;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/></svg>
            <div>该文件所属监控根目录暂未绑定腾讯 IMA 知识库，请前往系统设置完成绑定后才能执行同步。</div>
          </div>
        ` : `
          <div class="detail-binding-success">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" style="flex-shrink:0;"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
            <div>知识库绑定正常。随时可以开始单个文件的增量更新同步。</div>
          </div>
        `}

        <div class="detail-actions">
          <button class="action-main" id="detail-btn-sync" ${!isBound ? 'disabled' : ''}>
            <svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor" style="margin-right: 6px;"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM19 18H6c-2.21 0-4-1.79-4-4 0-2.05 1.53-3.76 3.56-3.97l1.07-.11.5-.95C8.08 7.14 9.94 6 12 6c2.62 0 4.88 1.86 5.39 4.43l.3 1.5 1.53.11c1.56.1 2.78 1.41 2.78 2.96 0 1.65-1.35 3-3 3z" fill="currentColor"/></svg>
            <span>立即同步此项</span>
          </button>
          <button class="action-secondary" id="detail-btn-mark">
            标记为已同步
          </button>
        </div>
      </div>
    `;

    // Bind action listeners
    const btnSync = document.getElementById("detail-btn-sync");
    const btnMark = document.getElementById("detail-btn-mark");

    if (btnSync && isBound) {
      btnSync.addEventListener("click", async () => {
        btnSync.disabled = true;
        btnSync.innerHTML = `<div class="spinner" style="width: 12px; height: 12px; border-width: 1.5px; margin-right: 6px;"></div> ${t("正在同步中...")}`;
        
        await new Promise(resolve => setTimeout(resolve, 500));
        try {
          await invoke("sync_single_event", { eventId: item.id, kbId, rootPathStr: matchedRoot });
          showGlobalToast("单项文件已成功上传并同步！");
          
          state.selectedPendingEventId = null;
          state.selectedPendingNode = null;
          
          await fetchEvents();
          updatePendingDetailPanel();
        } catch (err) {
          showGlobalToast("同步失败: " + err, true);
          btnSync.innerHTML = `<span>${t("立即同步此项")}</span>`;
          btnSync.disabled = false;
        }
      });
    }

    if (btnMark) {
      btnMark.addEventListener("click", async () => {
        btnMark.disabled = true;
        try {
          await invoke("mark_event_synced", { id: item.id });
          showGlobalToast("已手动标记该项为已同步。");
          
          state.selectedPendingEventId = null;
          state.selectedPendingNode = null;
          
          await fetchEvents();
          updatePendingDetailPanel();
        } catch (err) {
          showGlobalToast("标记失败: " + err, true);
          btnMark.disabled = false;
        }
      });
    }

  } else if (node.type === "directory") {
    let baseName = node.name;

    // Find matching monitored path and its knowledge base binding
    let matchedRoot = null;
    for (const p of state.monitoredPaths) {
      let cleanP = p.replace(/\\/g, "/");
      let cleanPath = node.path.replace(/\\/g, "/");
      if (cleanPath.startsWith(cleanP)) {
        matchedRoot = p;
        break;
      }
    }

    let kbId = matchedRoot ? localStorage.getItem(`kb_binding_${matchedRoot}`) : null;
    let kbName = t("未绑定/无");
    let isBound = false;
    if (kbId && kbId !== "default") {
      isBound = true;
      let kb = state.availableKnowledgeBases.find(k => k.id === kbId || k.kb_id === kbId);
      kbName = kb ? (kb.name || kb.title) : kbId;
    }

    let eventsToSync = node.events; // recursive pending events list

    dom.pendingDetailPanel.innerHTML = `
      <div class="pending-detail-panel">
        <div class="detail-header">
          <div class="detail-icon-container directory">
            <svg class="detail-icon" viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>
          </div>
          <div style="flex: 1; min-width: 0;">
            <h2 class="outfit-font" style="margin: 0 0 4px 0; font-size: 1.1rem; color: var(--text-primary); font-weight: 700; word-break: break-all;" title="${baseName}">${baseName}</h2>
            <span class="event-type-badge modified" style="background: rgba(233, 146, 47, 0.08); color: var(--app-amber); border-color: rgba(233, 146, 47, 0.15);">文件夹</span>
          </div>
        </div>

        <div class="detail-meta-list">
          <div class="detail-meta-item">
            <span class="detail-meta-label">包含待同步改动</span>
            <span class="detail-meta-value" style="font-weight: 700; color: var(--app-rose); font-size: 0.9rem;">${node.pendingCount} 项变动</span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-meta-label">路径类型</span>
            <span class="detail-meta-value">文件夹 / 目录拓扑</span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-meta-label">完整路径</span>
            <span class="detail-meta-value" style="font-family: monospace; font-size: 0.74rem;">${node.path}</span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-meta-label">绑定知识库</span>
            <span class="detail-meta-value" style="font-weight: 600;">${kbName}</span>
          </div>
        </div>

        ${!isBound ? `
          <div class="detail-binding-warning">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" style="flex-shrink:0;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/></svg>
            <div>该文件夹所属监控根目录暂未绑定腾讯 IMA 知识库，请前往系统设置完成绑定后才能执行同步。</div>
          </div>
        ` : `
          <div class="detail-binding-success">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" style="flex-shrink:0;"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
            <div>知识库绑定正常。可以批量同步该文件夹下所有文件的子变更。</div>
          </div>
        `}

        <div class="detail-actions">
          <button class="action-main" id="detail-btn-sync" ${!isBound || eventsToSync.length === 0 ? 'disabled' : ''}>
            <svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor" style="margin-right: 6px;"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM19 18H6c-2.21 0-4-1.79-4-4 0-2.05 1.53-3.76 3.56-3.97l1.07-.11.5-.95C8.08 7.14 9.94 6 12 6c2.62 0 4.88 1.86 5.39 4.43l.3 1.5 1.53.11c1.56.1 2.78 1.41 2.78 2.96 0 1.65-1.35 3-3 3z" fill="currentColor"/></svg>
            <span>同步目录下所有改动 (${eventsToSync.length})</span>
          </button>
          <button class="action-secondary" id="detail-btn-mark" ${eventsToSync.length === 0 ? 'disabled' : ''}>
            全部标记为已同步
          </button>
        </div>
      </div>
    `;

    const btnSync = document.getElementById("detail-btn-sync");
    const btnMark = document.getElementById("detail-btn-mark");

    if (btnSync && isBound && eventsToSync.length > 0) {
      btnSync.addEventListener("click", async () => {
        btnSync.disabled = true;
        
        let successCount = 0;
        let failCount = 0;
        for (let i = 0; i < eventsToSync.length; i++) {
          let ev = eventsToSync[i];
          btnSync.innerHTML = `<div class="spinner" style="width: 12px; height: 12px; border-width: 1.5px; margin-right: 6px;"></div> ${t("正在同步")}(${i+1}/${eventsToSync.length})...`;
          try {
            await invoke("sync_single_event", { eventId: ev.id, kbId, rootPathStr: matchedRoot });
            successCount++;
          } catch (e) {
            console.error("Failed single event sync in directory:", ev.id, e);
            failCount++;
          }
        }

        showGlobalToast(`成功同步 ${successCount} 个文件变动！${failCount > 0 ? `失败 ${failCount} 个。` : ""}`);

        state.selectedPendingEventId = null;
        state.selectedPendingNode = null;

        await fetchEvents();
        updatePendingDetailPanel();
      });
    }

    if (btnMark && eventsToSync.length > 0) {
      btnMark.addEventListener("click", async () => {
        btnMark.disabled = true;
        for (let ev of eventsToSync) {
          await invoke("mark_event_synced", { id: ev.id });
        }
        showGlobalToast(`已将目录下 ${eventsToSync.length} 个文件变动标记为已同步。`);

        state.selectedPendingEventId = null;
        state.selectedPendingNode = null;

        await fetchEvents();
        updatePendingDetailPanel();
      });
    }
  }
}

// 5. General SVG Icon renderer based on file extension
function getFileIcon(fileName, isDir) {
  if (isDir) {
    return `<svg class="detail-icon" viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" fill="currentColor"/></svg>`;
  }
  let ext = fileName.split('.').pop().toLowerCase();
  switch(ext) {
    case 'md': case 'txt': case 'rtf':
      return `<svg class="detail-icon" viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z" fill="currentColor"/></svg>`;
    case 'png': case 'jpg': case 'jpeg': case 'gif': case 'webp': case 'svg':
      return `<svg class="detail-icon" viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z" fill="currentColor"/></svg>`;
    case 'pdf':
      return `<svg class="detail-icon" viewBox="0 0 24 24"><path d="M20 2H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-8.5 7.5c0 .83-.67 1.5-1.5 1.5H9v2H7.5V8H10c.83 0 1.5.67 1.5 1.5v2zm5 2c0 .83-.67 1.5-1.5 1.5h-2.5V8h2.5c.83 0 1.5.67 1.5 1.5v2zm4.5-3H19v1h1.5V11H19v2h-1.5V8h3v1.5zM9 9.5h1v1H9v-1zm5 1h1v1h-1v-1zM2 6v14c0 1.1.9 2 2 2h14v-2H4V6H2z" fill="currentColor"/></svg>`;
    case 'zip': case 'tar': case 'gz': case 'rar': case '7z':
      return `<svg class="detail-icon" viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-6 3h2v2h-2V9zm0 4h2v2h-2v-2zm-4-4h2v2h-2V9zm0 4h2v2h-2v-2z" fill="currentColor"/></svg>`;
    default:
      return `<svg class="detail-icon" viewBox="0 0 24 24"><path d="M6 2c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6H6zm7 7V3.5L18.5 9H13z" fill="currentColor"/></svg>`;
  }
}

function getFileExtClass(fileName) {
  let ext = fileName.split('.').pop().toLowerCase();
  switch(ext) {
    case 'md': case 'txt': case 'rtf': return 'text';
    case 'png': case 'jpg': case 'jpeg': case 'gif': case 'webp': case 'svg': return 'image';
    case 'pdf': return 'pdf';
    case 'zip': case 'tar': case 'gz': case 'rar': case '7z': return 'zip';
    default: return 'file';
  }
}

// --- 6. HTTP Request Logs Viewer Implementation ---
async function loadAndRenderHttpLogs() {
  if (!dom.httpLogsList) return;
  
  try {
    let logs = await invoke("get_http_logs");
    if (!logs || logs.length === 0) {
      dom.httpLogsList.innerHTML = `
        <div style="padding: 60px 16px; text-align: center; color: var(--text-secondary); display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; height: 100%; box-sizing: border-box;">
          <svg viewBox="0 0 24 24" style="width: 48px; height: 48px; fill: var(--text-secondary);"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z" fill="currentColor"/></svg>
          <div style="font-size: 14px; font-weight: 600; color: var(--text-primary);">${t("暂无日志记录")}</div>
          <div style="font-size: 12px; color: var(--text-secondary);">${t("所有的 IMA 接口请求和响应详情都会记录在这里")}</div>
        </div>
      `;
      return;
    }
    
    dom.httpLogsList.innerHTML = "";
    logs.forEach(entry => {
      let item = document.createElement("div");
      item.className = "log-entry-item";
      item.id = `log-entry-${entry.id}`;
      
      // Determine status pill color
      let statusClass = "unknown";
      if (entry.error) {
        statusClass = "danger";
      } else if (entry.response_code) {
        let code = entry.response_code;
        if (code >= 200 && code < 300) {
          statusClass = "success";
        } else {
          statusClass = "warning";
        }
      }
      
      let shortTime = entry.timestamp || "";
      if (shortTime.includes(" ")) {
        shortTime = shortTime.split(" ")[1] || shortTime;
      }
      
      // Header HTML
      item.innerHTML = `
        <div class="log-entry-header">
          <div class="status-pill ${statusClass}"></div>
          <div class="log-entry-title">${entry.method} ${entry.url}</div>
          <div class="log-entry-time">${shortTime}</div>
          <button class="log-entry-copy-btn" title="${t("复制此请求与响应的完整日志")}">
            <svg viewBox="0 0 24 24" style="width: 14px; height: 14px; fill: currentColor;"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
          </button>
          <svg class="log-entry-chevron" viewBox="0 0 24 24" style="width: 14px; height: 14px;"><path d="M8.59 16.59L13.17 12 8.59 7.41 10 6l6 6-6 6-1.41-1.41z"/></svg>
        </div>
        <div class="log-entry-content hidden">
          <!-- Expanded detailed sections -->
        </div>
      `;
      
      // Expand / Collapse interaction
      let header = item.querySelector(".log-entry-header");
      let content = item.querySelector(".log-entry-content");
      let copyBtn = item.querySelector(".log-entry-copy-btn");
      
      copyBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        let fullText = `【IMA 请求日志】\n` +
          `${t("时间")}: ${entry.timestamp}\n` +
          `${t("方法")}: ${entry.method}\n` +
          `${t("全路径")}: ${entry.url}\n`;
        if (entry.request_headers) fullText += `\n[${t("请求头")}]\n${entry.request_headers}\n`;
        if (entry.request_body) fullText += `\n[${t("请求体")}]\n${entry.request_body}\n`;
        if (entry.response_code) fullText += `\n[HTTP 状态]: ${entry.response_code}\n`;
        if (entry.response_body) fullText += `\n[${t("响应体")}]\n${entry.response_body}\n`;
        if (entry.error) fullText += `\n[${t("错误详情")}]\n${entry.error}\n`;
        
        navigator.clipboard.writeText(fullText).then(() => {
          showGlobalToast(t("复制成功"));
        }).catch(() => {
          showGlobalToast(t("复制失败"), true);
        });
      });
      
      header.addEventListener("click", (e) => {
        if (e.target.closest(".log-entry-copy-btn")) return;
        
        let isExpanded = item.classList.toggle("expanded");
        if (isExpanded) {
          content.classList.remove("hidden");
          // Generate detailed sections if empty or not rendered
          if (content.children.length === 0) {
            renderLogDetails(entry, content);
          }
        } else {
          content.classList.add("hidden");
        }
      });
      
      dom.httpLogsList.appendChild(item);
    });
  } catch(e) {
    dom.httpLogsList.innerHTML = `<div style="padding: 20px; color: var(--app-rose); font-size: 13px;">Error loading logs: ${e}</div>`;
  }
}

function renderLogDetails(entry, container) {
  container.innerHTML = "";
  
  // 1. Full URL Section
  appendLogSection(container, t("全路径"), entry.url);
  
  // 2. Request Headers
  if (entry.request_headers) {
    appendLogSection(container, t("请求头"), entry.request_headers);
  }
  
  // 3. Request Body
  if (entry.request_body) {
    appendLogSection(container, t("请求体"), entry.request_body);
  }
  
  // 4. Response Body
  if (entry.response_body) {
    appendLogSection(container, t("响应体"), entry.response_body);
  }
  
  // 5. Error Detail
  if (entry.error) {
    appendLogSection(container, t("错误详情"), entry.error, true);
  }
  
  // 6. Copy Full Log Details Button
  let copyFullBtn = document.createElement("button");
  copyFullBtn.className = "reports-export-btn";
  copyFullBtn.style.marginTop = "12px";
  copyFullBtn.style.width = "100%";
  copyFullBtn.style.justifyContent = "center";
  copyFullBtn.style.padding = "8px 16px";
  copyFullBtn.innerHTML = `
    <svg viewBox="0 0 24 24" style="width: 14px; height: 14px; fill: currentColor;"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
    <span style="margin-left: 8px;">${t("复制完整日志详情")}</span>
  `;
  copyFullBtn.addEventListener("click", () => {
    let fullText = `【IMA 请求日志】\n` +
      `${t("时间")}: ${entry.timestamp}\n` +
      `${t("方法")}: ${entry.method}\n` +
      `${t("全路径")}: ${entry.url}\n`;
    if (entry.request_headers) fullText += `\n[${t("请求头")}]\n${entry.request_headers}\n`;
    if (entry.request_body) fullText += `\n[${t("请求体")}]\n${entry.request_body}\n`;
    if (entry.response_code) fullText += `\n[HTTP 状态]: ${entry.response_code}\n`;
    if (entry.response_body) fullText += `\n[${t("响应体")}]\n${entry.response_body}\n`;
    if (entry.error) fullText += `\n[${t("错误详情")}]\n${entry.error}\n`;
    
    navigator.clipboard.writeText(fullText).then(() => {
      showGlobalToast(t("复制成功"));
    }).catch(() => {
      showGlobalToast(t("复制失败"), true);
    });
  });
  
  container.appendChild(copyFullBtn);
}

function appendLogSection(container, title, content, isError = false) {
  let section = document.createElement("div");
  section.className = "log-section-container";
  
  section.innerHTML = `
    <div class="log-section-header">
      <span class="log-section-title">${title}</span>
      <button class="log-copy-btn" title="${t("复制此段内容")}">
        <svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 14H8V7h11v14z" fill="currentColor"/></svg>
      </button>
    </div>
    <pre class="log-section-pre" style="${isError ? 'color: var(--app-rose);' : ''}"></pre>
  `;
  
  // Set content text safely inside pre to avoid HTML injection
  section.querySelector(".log-section-pre").innerText = content;
  
  // Wire copy listener
  section.querySelector(".log-copy-btn").addEventListener("click", (e) => {
    e.stopPropagation();
    navigator.clipboard.writeText(content).then(() => {
      showGlobalToast(t("复制成功"));
    }).catch(() => {
      showGlobalToast(t("复制失败"), true);
    });
  });
  
  container.appendChild(section);
}
