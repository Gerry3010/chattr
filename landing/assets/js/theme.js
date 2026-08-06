(function() {
    const toggle = document.getElementById('themeToggle');
    const root = document.documentElement;
    
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
