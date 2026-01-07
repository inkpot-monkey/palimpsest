
export default {
    init: function () {
        console.log("ModelExtension JS initialized");

        // Fava uses a single page app structure. We need to watch for page content changes.
        // The main content is usually in <article>.

        const observer = new MutationObserver((mutations) => {
            if (location.href.includes('/errors')) {
                injectExplainButtons();
            }
        });

        const article = document.querySelector('article');
        if (article) {
            observer.observe(article, { childList: true, subtree: true });
        }

        // Also run once on direct load
        if (location.href.includes('/errors')) {
            injectExplainButtons();
        }

        // Hook into Fava's internal event bus if possible, or just use the observer.
        // Fava usually triggers 'page-loaded' or similar on document.
        document.addEventListener('fava-update', () => {
            if (location.href.includes('/errors')) {
                injectExplainButtons();
            }
        });
    }
};

function injectExplainButtons() {
    // Errors are usually in a table or list.
    // DOM structure of Errors page: .error or table rows.
    // Based on Fava source, looks like ol.errors li

    const errorItems = document.querySelectorAll('ol.errors li');

    errorItems.forEach(li => {
        if (li.querySelector('.ai-explain-btn')) return; // Already processed

        // Text content
        const text = li.textContent.trim();
        const sourceLink = li.querySelector('.source');
        let context = "";
        if (sourceLink) context = sourceLink.textContent;

        const btn = document.createElement('button');
        btn.innerHTML = '🤖 Explain';
        btn.className = 'ai-explain-btn';
        btn.style.marginLeft = '10px';
        btn.style.fontSize = '0.8em';
        btn.style.cursor = 'pointer';
        btn.style.border = '1px solid #ddd';
        btn.style.background = '#fff';
        btn.style.borderRadius = '4px';
        btn.style.padding = '2px 6px';

        btn.onclick = async (e) => {
            e.preventDefault();
            btn.textContent = 'Thinking...';
            btn.disabled = true;

            try {
                const res = await fetch('../extension/ModelExtension/explain', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ message: text, context: context })
                });
                const data = await res.json();

                if (data.success) {
                    showInlineExplanation(li, data.explanation);
                } else {
                    showInlineExplanation(li, 'Error: ' + data.error, true);
                }
            } catch (err) {
                showInlineExplanation(li, 'Network Error: ' + err, true);
            } finally {
                btn.textContent = '🤖 Explain';
                btn.disabled = false;
            }
        };

        li.appendChild(btn);
    });

    injectExplainAllButton();
}

function injectExplainAllButton() {
    const list = document.querySelector('ol.errors');
    if (!list) return;

    // Check if button already exists
    if (document.getElementById('ai-explain-all-btn')) return;

    const btn = document.createElement('button');
    btn.id = 'ai-explain-all-btn';
    btn.innerHTML = '🤖 Explain All Errors';
    btn.style.marginTop = '20px';
    btn.style.padding = '10px 20px';
    btn.style.background = '#18181b';
    btn.style.color = 'white';
    btn.style.border = 'none';
    btn.style.borderRadius = '6px';
    btn.style.cursor = 'pointer';
    btn.style.fontWeight = '500';
    btn.style.display = 'block';

    btn.onclick = async () => {
        const buttons = document.querySelectorAll('.ai-explain-btn');
        btn.disabled = true;
        btn.textContent = 'Processing all errors...';

        for (const b of buttons) {
            if (!b.disabled) {
                b.click();
                // small delay to be nice to the server/UI
                await new Promise(r => setTimeout(r, 500));
            }
        }

        btn.textContent = '✅ All Processed';
        setTimeout(() => {
            btn.disabled = false;
            btn.innerHTML = '🤖 Explain All Errors';
        }, 3000);
    };

    list.parentNode.appendChild(btn);
}

function showInlineExplanation(li, content, isError = false) {
    // Check if already exists
    let box = li.nextElementSibling;
    if (!box || !box.classList.contains('ai-explanation-box')) {
        box = document.createElement('div');
        box.className = 'ai-explanation-box';
        // Style matches SyncExtension output
        box.style.marginTop = '10px';
        box.style.marginBottom = '20px';
        box.style.background = '#f4f4f5';
        box.style.padding = '15px';
        box.style.borderRadius = '6px';
        box.style.fontFamily = 'monospace';
        box.style.fontSize = '0.9em';
        box.style.whiteSpace = 'pre-wrap';
        box.style.border = isError ? '1px solid red' : '1px solid #d4d4d8';
        box.style.color = '#333';

        // Insert AFTER the li
        li.parentNode.insertBefore(box, li.nextSibling);
    }

    box.textContent = content;
}
