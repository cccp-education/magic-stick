class ThemeManager {
    constructor() {
        this.themes = {
            light: { name: 'Light', icon: 'bi-sun', label: 'Light' },
            dark: { name: 'Dark', icon: 'bi-moon', label: 'Dark' },
            'high-contrast': { name: 'High Contrast', icon: 'bi-circle-half', label: 'High Contrast' }
        };
        this.currentTheme = 'light';
        this.init();
    }

    init() {
        this.loadTheme();
        this.setupEventListeners();
        this.updateThemeUI();
        this.listenForSystemThemeChanges();
    }

    loadTheme() {
        const savedTheme = localStorage.getItem('preferred-theme');
        if (savedTheme && this.themes[savedTheme]) {
            this.currentTheme = savedTheme;
        } else {
            this.currentTheme = window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
        }
        this.applyTheme(this.currentTheme);
    }

    setupEventListeners() {
        document.querySelectorAll('.theme-option').forEach(option => {
            option.addEventListener('click', (e) => {
                e.preventDefault();
                this.switchTheme(e.currentTarget.dataset.theme);
            });
        });
    }

    switchTheme(theme) {
        if (!this.themes[theme]) return;
        this.currentTheme = theme;
        this.applyTheme(theme);
        localStorage.setItem('preferred-theme', theme);
        this.updateThemeUI();
        const themeButton = document.getElementById('themeDropdown');
        if (themeButton) themeButton.focus();
    }

    applyTheme(theme) {
        document.documentElement.setAttribute('data-bs-theme', theme);
        this.updateCodeTheme(theme);
    }

    updateCodeTheme(theme) {
        const highlightThemeLink = document.getElementById('highlight-js-theme');
        if (!highlightThemeLink) return;
        const lightTheme = 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/github.min.css';
        const darkTheme = 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/github-dark.min.css';
        highlightThemeLink.href = (theme === 'dark' || theme === 'high-contrast') ? darkTheme : lightTheme;
    }

    updateThemeUI() {
        const currentThemeData = this.themes[this.currentTheme];
        const themeButton = document.getElementById('themeDropdown');
        if (themeButton && currentThemeData) {
            themeButton.setAttribute('aria-label', `Theme actuel : ${currentThemeData.label}`);
            const iconElement = themeButton.querySelector('i');
            if (iconElement) iconElement.className = `bi ${currentThemeData.icon} me-1`;
            const currentThemeSpan = themeButton.querySelector('#current-theme');
            if (currentThemeSpan) currentThemeSpan.textContent = currentThemeData.label;
        }
        document.querySelectorAll('.theme-option').forEach(option => {
            option.classList.toggle('active', option.dataset.theme === this.currentTheme);
        });
    }

    listenForSystemThemeChanges() {
        window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
            if (!localStorage.getItem('preferred-theme')) {
                this.switchTheme(e.matches ? 'dark' : 'light');
            }
        });
    }
}

class ScrollToTopButton {
    constructor(button) {
        this.button = button;
        this.footer = document.querySelector('footer');
        this.init();
    }

    init() {
        window.addEventListener('scroll', () => this.handleScroll(), { passive: true });
        this.button.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' }));
    }

    handleScroll() {
        const scrollY = window.scrollY;
        this.button.classList.toggle('show', scrollY > 300);
        if (this.footer) {
            const footerRect = this.footer.getBoundingClientRect();
            if (footerRect.top < window.innerHeight) {
                this.button.style.bottom = `${window.innerHeight - footerRect.top + 20}px`;
            } else {
                this.button.style.bottom = '20px';
            }
        }
    }
}

class MobileMenuManager {
    constructor(navbar) {
        this.navbarCollapse = navbar.querySelector('.navbar-collapse');
        this.init();
    }

    init() {
        if (!this.navbarCollapse) return;
        const bsCollapse = new bootstrap.Collapse(this.navbarCollapse, { toggle: false });
        this.navbarCollapse.addEventListener('click', (event) => {
            const target = event.target;
            const isSimpleNavLink = target.matches('.nav-link') && !target.matches('[data-bs-toggle="dropdown"]');
            const isDropdownItem = target.matches('.dropdown-item');
            if ((isSimpleNavLink || isDropdownItem) && this.navbarCollapse.classList.contains('show')) {
                bsCollapse.hide();
            }
        });
    }
}

class SmoothScrollWithOffset {
    constructor(navbarSelector = '.navbar') {
        this.navbar = document.querySelector(navbarSelector);
        this.init();
    }

    init() {
        document.querySelectorAll('a[href^="#"]').forEach(anchor => {
            anchor.addEventListener('click', this.handleAnchorClick.bind(this));
        });
    }

    handleAnchorClick(event) {
        const anchor = event.currentTarget;
        const href = anchor.getAttribute('href');
        if (anchor.matches('[data-bs-toggle="dropdown"]')) return;
        if (href === '#' || href === '#home') {
            event.preventDefault();
            window.scrollTo({ top: 0, behavior: 'smooth' });
            return;
        }
        const targetId = href.substring(1);
        const targetElement = document.getElementById(targetId);
        if (targetElement) {
            event.preventDefault();
            const navbarCollapse = this.navbar.querySelector('.navbar-collapse');
            const isMobileMenuOpen = navbarCollapse && navbarCollapse.classList.contains('show');
            if (isMobileMenuOpen) {
                navbarCollapse.addEventListener('hidden.bs.collapse', () => {
                    targetElement.scrollIntoView({ behavior: 'smooth' });
                }, { once: true });
            } else {
                targetElement.scrollIntoView({ behavior: 'smooth' });
            }
        }
    }
}

class NavbarHeightUpdater {
    constructor(navbar) {
        this.navbar = navbar;
        this.init();
    }

    init() {
        if (!this.navbar || !('ResizeObserver' in window)) return;
        const resizeObserver = new ResizeObserver(() => this.updateHeight());
        resizeObserver.observe(this.navbar);
        this.updateHeight();
    }

    updateHeight() {
        const brandElement = this.navbar.querySelector('.navbar-brand');
        let actualNavbarHeight = 0;
        if (brandElement) actualNavbarHeight = brandElement.offsetHeight;
        document.documentElement.style.setProperty('--navbar-height', `${actualNavbarHeight}px`);
    }
}

class BrandVisibilityManager {
    constructor(navbar) {
        this.navbar = navbar;
        this.init();
    }

    init() {
        const heroTitle = document.querySelector('.hero-title');
        const brandText = this.navbar.querySelector('.brand-text');
        if (!heroTitle || !brandText) return;
        const navbarHeight = this.navbar.offsetHeight;
        window.addEventListener('scroll', () => {
            const rect = heroTitle.getBoundingClientRect();
            const start = rect.top - navbarHeight;
            const range = rect.height;
            const progress = Math.max(0, Math.min(1, -start / range));
            heroTitle.style.opacity = 1 - progress;
            brandText.style.opacity = progress;
        }, { passive: true });
    }
}

class CodeBlockManager {
    constructor() { this.init(); }

    init() {
        document.querySelectorAll('pre code').forEach(codeBlock => {
            const preElement = codeBlock.parentElement;
            if (preElement) {
                const copyButton = this.createCopyButton();
                preElement.appendChild(copyButton);
                this.setupCopyEventListener(copyButton, codeBlock);
            }
        });
    }

    createCopyButton() {
        const button = document.createElement('button');
        button.className = 'copy-code-btn';
        button.innerHTML = '<i class="bi bi-clipboard"></i> Copier';
        button.setAttribute('aria-label', 'Copier le code');
        return button;
    }

    setupCopyEventListener(button, codeBlock) {
        button.addEventListener('click', () => {
            navigator.clipboard.writeText(codeBlock.innerText).then(() => {
                button.innerHTML = '<i class="bi bi-check-lg"></i> Copie !';
                button.classList.add('copied');
                setTimeout(() => {
                    button.innerHTML = '<i class="bi bi-clipboard"></i> Copier';
                    button.classList.remove('copied');
                }, 2000);
            }).catch(err => {
                console.error('Failed to copy code: ', err);
                button.innerText = 'Erreur';
            });
        });
    }
}

class TooltipManager {
    constructor() { this.init(); }

    init() {
        const tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
        tooltipTriggerList.map(function (tooltipTriggerEl) {
            return new bootstrap.Tooltip(tooltipTriggerEl);
        });
    }
}

document.addEventListener('DOMContentLoaded', () => {
    if (document.getElementById('themeDropdown')) {
        try { new ThemeManager(); } catch (e) { console.error("Failed to initialize ThemeManager:", e); }
    }

    const navbar = document.querySelector('.navbar');
    if (navbar) {
        try { new MobileMenuManager(navbar); } catch (e) { console.error("Failed to initialize MobileMenuManager:", e); }
        try { new NavbarHeightUpdater(navbar); } catch (e) { console.error("Failed to initialize NavbarHeightUpdater:", e); }
        try { new BrandVisibilityManager(navbar); } catch (e) { console.error("Failed to initialize BrandVisibilityManager:", e); }
    }

    const scrollToTopBtn = document.getElementById('scrollToTopBtn');
    if (scrollToTopBtn) {
        try { new ScrollToTopButton(scrollToTopBtn); } catch (e) { console.error("Failed to initialize ScrollToTopButton:", e); }
    }

    try { new SmoothScrollWithOffset(); } catch (e) { console.error("Failed to initialize SmoothScrollWithOffset:", e); }
    try { new CodeBlockManager(); } catch (e) { console.error("Failed to initialize CodeBlockManager:", e); }
    try { new TooltipManager(); } catch (e) { console.error("Failed to initialize TooltipManager:", e); }
});