// Builds the flowchart blocks from window.CHATTR_FLOWS (flow-sources.js) and renders
// them with the bundled Mermaid version. Two modes:
//   #flowAccordion  (index.html)  — <details> accordion, at most 1 open
//   #flowExpanded   (technik.html) — all diagrams expanded
// Re-renders on a theme change, so the diagram colours follow the page theme.
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
            // Open/close animated rather than native (a native <details>
            // snaps). At most one tile open — the other closes in parallel over
            // the same duration, so the page does not hop.
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

    // --- Accordion animation ------------------------------------------------
    // Animates the height of the .flow-diagram wrapper (Web Animations API).
    // With prefers-reduced-motion it switches hard, as before.
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
        // The chevron should turn back at once, not only after the animation.
        details.classList.add('closing');
        setTimeout(function () { details.classList.remove('closing'); }, OPEN_MS);
    }

    let renderSeq = 0;

    function currentThemeIsDark() {
        const attr = document.documentElement.getAttribute('data-theme');
        if (attr) return attr === 'dark';
        return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }

    // Reads a CSS custom property from :root (theme-dependent), with a
    // fallback.
    function cssVar(name, fallback) {
        const v = getComputedStyle(document.documentElement)
            .getPropertyValue(name).trim();
        return v || fallback;
    }

    // Mermaid's default colours (light lavender #ECECFF, yellow clusters …)
    // match none of the page themes and are poorly legible depending on the
    // background. So bind the diagrams to the page palette — guaranteed
    // contrast in light AND dark (nodes/DB cylinders = card background +
    // primary text, subgraphs = secondary background). Read the colours at
    // render time so they follow the active theme.
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
            // See cms/web/assets/js/flow-diagram.js: Mermaid's default for the
            // width of the participant boxes measures long labels too tightly,
            // and the text then sticks out at the side.
            sequence: { width: 260 },
        });
        for (let i = 0; i < targets.length; i++) {
            try {
                const { svg } = await mermaid.render(
                    'flowSvg' + seq + '_' + i,
                    targets[i].source.trim(),
                );
                if (seq === renderSeq) {
                    targets[i].el.innerHTML = svg;
                    makeZoomable(targets[i].el);
                }
            } catch (e) {
                // A broken diagram must not break the page.
                console.error('flow diagram render failed', e);
            }
        }
    }

    // --- Full screen
    // ----------------------------------------------------------- A sequence
    // diagram is ~1500 px wide and up to 2800 px tall. Scaled into a phone
    // column the type is no longer legible. A tap opens it full-bleed;
    // underneath, the page stays as it was. The counterpart to
    // cms/web/assets/js/flow-diagram.js — both sites show the same diagrams, so
    // they behave the same way too.

    let overlay, stage, inner, scale = 1, tx = 0, ty = 0, dragged = false, opener = null;

    function buildOverlay() {
        overlay = document.createElement('div');
        overlay.className = 'mmd-full';
        overlay.setAttribute('role', 'dialog');
        overlay.setAttribute('aria-modal', 'true');
        overlay.setAttribute('aria-label', 'Diagramm in Vollbild');
        overlay.innerHTML =
            '<div class="mmd-full-bar">' +
              '<span class="mmd-full-title"></span>' +
              '<div class="mmd-full-btns">' +
                '<button type="button" data-act="out" aria-label="Verkleinern">−</button>' +
                '<button type="button" data-act="reset" aria-label="Ansicht zurücksetzen">Einpassen</button>' +
                '<button type="button" data-act="in" aria-label="Vergrößern">+</button>' +
                '<button type="button" data-act="close" aria-label="Schließen">✕</button>' +
              '</div>' +
            '</div>' +
            '<div class="mmd-full-stage"><div class="mmd-full-inner"></div></div>' +
            '<div class="mmd-full-hint">Ziehen zum Verschieben · zwei Finger oder Mausrad zum Zoomen</div>';
        document.body.appendChild(overlay);
        stage = overlay.querySelector('.mmd-full-stage');
        inner = overlay.querySelector('.mmd-full-inner');

        overlay.querySelector('.mmd-full-btns').addEventListener('click', function (e) {
            const act = e.target.getAttribute('data-act');
            if (act === 'close') closeFull();
            else if (act === 'reset') fit();
            else if (act === 'in') zoomBy(1.25);
            else if (act === 'out') zoomBy(1 / 1.25);
        });
        stage.addEventListener('click', function (e) {
            if (e.target === stage && !dragged) closeFull();
        });
        document.addEventListener('keydown', function (e) {
            if (!overlay.classList.contains('open')) return;
            if (e.key === 'Escape') closeFull();
            else if (e.key === '+' || e.key === '=') zoomBy(1.25);
            else if (e.key === '-') zoomBy(1 / 1.25);
            else if (e.key === '0') fit();
        });

        const pointers = new Map();
        let startDist = 0, startScale = 1, last = null;
        const dist = function () {
            const p = [...pointers.values()];
            return Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
        };
        const mid = function () {
            const p = [...pointers.values()];
            return { x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2 };
        };
        stage.addEventListener('pointerdown', function (e) {
            pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
            stage.setPointerCapture(e.pointerId);
            dragged = false;
            if (pointers.size === 2) { startDist = dist(); startScale = scale; }
            else last = { x: e.clientX, y: e.clientY };
        });
        stage.addEventListener('pointermove', function (e) {
            if (!pointers.has(e.pointerId)) return;
            pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
            if (pointers.size === 2 && startDist) {
                // Zoom around the MIDPOINT between the fingers, not around the
                // centre of the stage — otherwise the content wanders out from
                // under the fingers.
                const m = mid();
                zoomAtPoint(clamp(startScale * (dist() / startDist)) / scale, m.x, m.y);
            } else if (last) {
                tx += e.clientX - last.x; ty += e.clientY - last.y;
                last = { x: e.clientX, y: e.clientY };
                if (Math.abs(tx) + Math.abs(ty) > 3) dragged = true;
                apply();
            }
        });
        ['pointerup', 'pointercancel'].forEach(function (t) {
            stage.addEventListener(t, function (e) {
                pointers.delete(e.pointerId);
                if (pointers.size < 2) startDist = 0;
                // When ONE finger is lifted the other stays down — and `last`
                // then still pointed to where THAT finger had touched down. The
                // next drag counted the whole distance since then as a pan, and
                // the content jumped away. That was exactly the "jumps on
                // release": two fingers never lift at the same instant. Reset
                // the reference point.
                if (pointers.size === 1) {
                    last = pointers.values().next().value;
                }
                if (pointers.size === 0) last = null;
            });
        });
        stage.addEventListener('wheel', function (e) {
            e.preventDefault();
            zoomAtPoint(e.deltaY < 0 ? 1.12 : 1 / 1.12, e.clientX, e.clientY);
        }, { passive: false });
    }

    function clamp(s) { return Math.min(8, Math.max(0.2, s)); }

    // Zoom around a FIXED point (mouse pointer, or the midpoint between two
    // fingers). Without it everything scales around the centre of the stage,
    // and what one is looking at wanders off while zooming. The arithmetic: the
    // content point under the focus is (f − t) / s; after scaling it should lie
    // there again, so t' = f − (f − t) · s'/s.
    function zoomAtPoint(factor, clientX, clientY) {
        const r = stage.getBoundingClientRect();
        const fx = clientX - r.left - r.width / 2;
        const fy = clientY - r.top - r.height / 2;
        const next = clamp(scale * factor);
        if (next === scale) return;
        tx = fx - (fx - tx) * (next / scale);
        ty = fy - (fy - ty) * (next / scale);
        scale = next;
        apply();
    }

    function zoomBy(f) {
        const r = stage.getBoundingClientRect();
        zoomAtPoint(f, r.left + r.width / 2, r.top + r.height / 2);
    }
    function apply() {
        inner.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
    }

    // Fit to the WIDTH, not to width and height: fitted completely, a sequence
    // diagram is back at factor 0.3 and thereby as illegible as in the page —
    // so exactly the problem the full screen is meant to solve.
    function fit() {
        const svg = inner.querySelector('svg');
        if (!svg) return;
        const vb = (svg.getAttribute('viewBox') || '').split(/[\s,]+/).map(Number);
        const w = vb[2] || svg.clientWidth, h = vb[3] || svg.clientHeight;
        scale = Math.min(2, (stage.clientWidth - 24) / w);
        tx = 0;
        const hoehe = h * scale;
        ty = hoehe > stage.clientHeight ? (hoehe - stage.clientHeight) / 2 : 0;
        apply();
    }

    function openFull(host) {
        if (!overlay) buildOverlay();
        const svg = host.querySelector('svg');
        if (!svg) return;
        const clone = svg.cloneNode(true);
        clone.removeAttribute('style');
        clone.removeAttribute('width');
        clone.removeAttribute('height');
        // Without an explicit size the SVG, as a flex child, stretches to the
        // full width of the stage, and the zoom computes with a different width
        // than the fit — the result would be a diagram cut off.
        const vb = (clone.getAttribute('viewBox') || '').split(/[\s,]+/).map(Number);
        if (vb.length === 4 && vb[2] && vb[3]) {
            clone.style.width = vb[2] + 'px';
            clone.style.height = vb[3] + 'px';
            clone.style.flex = 'none';
        }
        inner.innerHTML = '';
        inner.appendChild(clone);
        const block = host.closest('.flow-block');
        const h = block && block.querySelector('h3, summary');
        overlay.querySelector('.mmd-full-title').textContent =
            h ? h.textContent.trim() : 'Ablaufdiagramm';
        overlay.classList.add('open');
        document.body.classList.add('mmd-full-lock');
        fit();
        overlay.querySelector('[data-act="close"]').focus();
    }

    function closeFull() {
        overlay.classList.remove('open');
        document.body.classList.remove('mmd-full-lock');
        inner.innerHTML = '';
        if (opener) opener.focus();
    }

    function makeZoomable(host) {
        if (host.dataset.zoomable === '1') return;
        host.dataset.zoomable = '1';
        host.tabIndex = 0;
        host.setAttribute('role', 'button');
        host.setAttribute('aria-label', 'Diagramm in Vollbild öffnen');
        host.addEventListener('click', function () { opener = host; openFull(host); });
        host.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault(); opener = host; openFull(host);
            }
        });
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
