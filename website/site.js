// SPDX-License-Identifier: MPL-2.0
(() => {
    const filters = document.querySelector('.filters');
    const count = document.querySelector('.feature-count');
    const cards = [...document.querySelectorAll('.feature')];
    if (!filters || !count || !cards.length) return;
    const buttons = [...filters.querySelectorAll('button')];
    function applyFilter(status) {
        let visible = 0;
        for (const card of cards) {
            card.hidden = status !== 'all' && card.dataset.status !== status;
            if (!card.hidden) visible++;
        }
        for (const button of buttons) button.setAttribute('aria-pressed', String(button.dataset.filter === status));
        count.textContent = `${visible} ${count.dataset.suffix}`;
    }
    filters.addEventListener('click', (event) => {
        const button = event.target.closest('button[data-filter]');
        if (button && filters.contains(button)) applyFilter(button.dataset.filter);
    });
    filters.hidden = false;
    count.hidden = false;
    applyFilter('all');
})();
