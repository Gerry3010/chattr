// Baut die Flowchart-Blöcke aus window.CHATTR_FLOWS (flow-sources.js) und
// rendert sie mit der gebundelten Mermaid-Version. Zwei Modi:
//   #flowAccordion  (index.html)  — <details>-Accordion, max. 1 offen
//   #flowExpanded   (technik.html) — alle Diagramme ausgeklappt
// Re-rendert bei Theme-Wechsel, damit die Diagrammfarben dem Seiten-Theme
// folgen.
(function () {
    const flows = window.CHATTR_FLOWS || [];
    const accordionRoot = document.getElementById('flowAccordion');
    const expandedRoot = document.getElementById('flowExpanded');
    const root = accordionRoot || expandedRoot;
    if (!root || !flows.length || typeof mermaid === 'undefined') return;

    const targets = [];

    flows.forEach(function (flow) {
        if (accordionRoot) {
            const details = document.createElement('details');
            details.className = 'flow-block';
            const summary = document.createElement('summary');
            summary.innerHTML =
                '<span class="flow-icon">' + flow.icon + '</span>' +
                '<span class="flow-title">' + flow.title + '</span>' +
                '<span class="flow-chevron" aria-hidden="true">▾</span>';
            const diagram = document.createElement('div');
            diagram.className = 'flow-diagram';
            details.appendChild(summary);
            details.appendChild(diagram);
            root.appendChild(details);
            // Öffnen/Schließen animiert statt nativ (natives <details>
            // springt hart um). Max. ein Tile offen — das andere schließt
            // parallel in derselben Dauer, damit die Seite nicht hüpft.
            summary.addEventListener('click', function (e) {
                e.preventDefault();
                if (details.open) {
                    animateClose(details);
                } else {
                    root.querySelectorAll('details.flow-block[open]').forEach(function (other) {
                        if (other !== details) animateClose(other);
                    });
                    animateOpen(details);
                }
            });
            targets.push({ el: diagram, source: flow.source });
        } else {
            const block = document.createElement('div');
            block.className = 'flow-block flow-block-expanded';
            block.id = 'flow-' + flow.id;
            block.innerHTML =
                '<h3><span class="flow-icon">' + flow.icon + '</span>' +
                flow.title + '</h3>' +
                '<div class="flow-diagram"></div>';
            root.appendChild(block);
            targets.push({
                el: block.querySelector('.flow-diagram'),
                source: flow.source,
            });
        }
    });

    // --- Accordion-Animation ------------------------------------------------
    // Animiert die Höhe des .flow-diagram-Wrappers (Web Animations API).
    // Bei prefers-reduced-motion wird hart geschaltet wie vorher.
    const OPEN_MS = 280;
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

    function diagramOf(details) {
        return details.querySelector('.flow-diagram');
    }

    function animateOpen(details) {
        details.open = true; // Inhalt sichtbar machen, dann von 0 hochfahren
        if (reducedMotion.matches || !details.animate) return;
        const diagram = diagramOf(details);
        const target = diagram.scrollHeight;
        diagram.style.overflow = 'hidden';
        const anim = diagram.animate(
            { height: ['0px', target + 'px'], opacity: [0, 1] },
            { duration: OPEN_MS, easing: 'ease-in-out' },
        );
        anim.onfinish = anim.oncancel = function () {
            diagram.style.overflow = '';
        };
    }

    function animateClose(details) {
        if (reducedMotion.matches || !details.animate) {
            details.open = false;
            return;
        }
        const diagram = diagramOf(details);
        diagram.style.overflow = 'hidden';
        const anim = diagram.animate(
            { height: [diagram.scrollHeight + 'px', '0px'], opacity: [1, 0] },
            { duration: OPEN_MS, easing: 'ease-in-out' },
        );
        anim.onfinish = anim.oncancel = function () {
            diagram.style.overflow = '';
            details.open = false;
        };
        // Chevron soll sofort zurückdrehen, nicht erst nach der Animation.
        details.classList.add('closing');
        setTimeout(function () { details.classList.remove('closing'); }, OPEN_MS);
    }

    let renderSeq = 0;

    function currentThemeIsDark() {
        const attr = document.documentElement.getAttribute('data-theme');
        if (attr) return attr === 'dark';
        return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }

    // Liest eine CSS-Custom-Property vom :root (theme-abhängig), mit Fallback.
    function cssVar(name, fallback) {
        const v = getComputedStyle(document.documentElement)
            .getPropertyValue(name).trim();
        return v || fallback;
    }

    // Mermaids Standardfarben (helles Lavendel #ECECFF, gelbe Cluster …) passen
    // zu keinem der Seiten-Themes und sind je nach Hintergrund schlecht lesbar.
    // Deshalb Diagramme an die Seiten-Palette binden — garantiert Kontrast in
    // Light UND Dark (Knoten/DB-Zylinder = Karten-BG + Primärtext, Subgraphen =
    // sekundärer BG). Farben zur Render-Zeit lesen, damit sie dem aktiven Theme
    // folgen.
    function themeVariables() {
        const bgCard = cssVar('--bg-card', '#ffffff');
        const bgSecondary = cssVar('--bg-secondary', '#f5f7fa');
        const textPrimary = cssVar('--text-primary', '#435e81');
        const border = cssVar('--primary-light', '#559cad');
        const line = cssVar('--text-secondary', '#6b7280');
        return {
            background: 'transparent',
            // Flowchart-Knoten (inkl. DB-Zylinder)
            primaryColor: bgCard,
            primaryTextColor: textPrimary,
            primaryBorderColor: border,
            mainBkg: bgCard,
            nodeBorder: border,
            nodeTextColor: textPrimary,
            secondaryColor: bgSecondary,
            tertiaryColor: bgSecondary,
            lineColor: line,
            titleColor: textPrimary,
            edgeLabelBackground: bgCard,
            // Subgraph-/Cluster-Kacheln
            clusterBkg: bgSecondary,
            clusterBorder: border,
            // Sequenzdiagramme (Akteure, Signale, Notizen, Schleifen)
            actorBkg: bgCard,
            actorBorder: border,
            actorTextColor: textPrimary,
            signalColor: textPrimary,
            signalTextColor: textPrimary,
            labelBoxBkgColor: bgSecondary,
            labelBoxBorderColor: border,
            labelTextColor: textPrimary,
            loopTextColor: textPrimary,
            noteBkgColor: bgSecondary,
            noteTextColor: textPrimary,
            noteBorderColor: border,
            activationBkgColor: border,
            sequenceNumberColor: bgCard,
        };
    }

    async function render() {
        const seq = ++renderSeq;
        mermaid.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            theme: currentThemeIsDark() ? 'dark' : 'default',
            themeVariables: themeVariables(),
        });
        for (let i = 0; i < targets.length; i++) {
            try {
                const { svg } = await mermaid.render(
                    'flowSvg' + seq + '_' + i,
                    targets[i].source.trim(),
                );
                if (seq === renderSeq) targets[i].el.innerHTML = svg;
            } catch (e) {
                // Ein kaputtes Diagramm darf die Seite nicht brechen.
                console.error('flow diagram render failed', e);
            }
        }
    }

    render();

    // theme.js setzt data-theme auf <html> — bei Wechsel neu rendern.
    new MutationObserver(render).observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['data-theme'],
    });
    window.matchMedia('(prefers-color-scheme: dark)')
        .addEventListener('change', render);
})();
