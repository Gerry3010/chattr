(function() {
    const toggle = document.getElementById('themeToggle');
    const root = document.documentElement;
    
    // Safari detection - force PNG for better compatibility
    const isSafari = /^((?!chrome|android).)*safari/i.test(navigator.userAgent);
    if (isSafari) {
        root.setAttribute('data-browser', 'safari');
        
        // Replace logo source with PNG
        const logoImg = document.querySelector('.logo');
        if (logoImg) {
            logoImg.src = 'assets/icons/logo-nobg.png';
        }
        
        // Remove picture source to force PNG fallback
        const logoSource = document.querySelector('picture source');
        if (logoSource) {
            logoSource.remove();
        }
    }
    
    // Check for saved preference or system preference
    const savedTheme = localStorage.getItem('theme');
    if (savedTheme) {
        root.setAttribute('data-theme', savedTheme);
    }
    
    toggle.addEventListener('click', () => {
        const currentTheme = root.getAttribute('data-theme');
        const systemPrefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        
        let newTheme;
        if (currentTheme === 'dark' || (!currentTheme && systemPrefersDark)) {
            newTheme = 'light';
        } else {
            newTheme = 'dark';
        }
        
        root.setAttribute('data-theme', newTheme);
        localStorage.setItem('theme', newTheme);
    });
})();
