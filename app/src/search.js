import { SHARD_API, extractText, allNodes } from './graph.js';
import { setSearchMatches, setSearchOpen, setSelectedNode } from './state.js';

const overlay = document.getElementById('search-overlay');
const input = document.getElementById('search-input');
const status = document.getElementById('search-status');
const detailPanel = document.getElementById('detail-panel');
const detailTitle = document.getElementById('detail-title');
const detailBody = document.getElementById('detail-body');

let open = false;

export function initSearch() {
  document.addEventListener('keydown', e => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
      if (e.key === 'Escape' && open) {
        closeSearch();
        e.preventDefault();
      }
      return;
    }
    if (e.code === 'Space') {
      e.preventDefault();
      if (open) { closeSearch(); } else { openSearch(); }
    }
  });

  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') {
      e.preventDefault();
      const q = input.value.trim();
      if (q) search(q);
    }
  });

  document.addEventListener('mousedown', e => {
    if (open && !overlay.contains(e.target)) {
      closeSearch();
    }
  });
}

function openSearch() {
  open = true;
  setSearchOpen(true);
  setSelectedNode(null);
  overlay.classList.add('open');
  input.focus();
}

function closeSearch() {
  open = false;
  setSearchOpen(false);
  overlay.classList.remove('open');
  input.blur();
  if (!input.value.trim()) {
    setSearchMatches(null);
    status.textContent = '';
    detailPanel.classList.remove('open');
  }
}

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function search(query) {
  status.textContent = 'asking AI...';
  detailTitle.textContent = query;
  detailBody.innerHTML = '<div class="search-loading">Searching...</div>';
  detailPanel.classList.add('open');

  const matches = new Set();
  const lowerQ = query.toLowerCase();
  for (const node of allNodes) {
    if (node.label && node.label.toLowerCase().includes(lowerQ)) {
      matches.add(node);
    }
  }

  try {
    const resp = await fetch(`${SHARD_API}/query`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ keyword: query })
    });
    const data = await resp.json();
    const text = extractText(data);

    if (text) {
      const lines = text.split('\n').filter(l => l.trim());
      const resultHtml = [];

      for (const line of lines) {
        const m = line.match(/^- ([^:]+): (.+)/);
        if (m) {
          const [, id, content] = m;
          const node = allNodes.find(n => n.id === id);
          if (node) {
            matches.add(node);
            for (const child of node.children) matches.add(child);
          }
          const parentNode = allNodes.find(n => n.children.some(c => c.id === id));
          if (parentNode) matches.add(parentNode);

          resultHtml.push(`<div class="search-result" data-id="${escapeHtml(id)}">
            <span class="search-result-id">${escapeHtml(id)}</span>
            <span class="search-result-text">${escapeHtml(content)}</span>
          </div>`);
        } else {
          resultHtml.push(`<div class="search-result-line">${escapeHtml(line)}</div>`);
        }
      }

      detailBody.innerHTML = resultHtml.join('');

      detailBody.querySelectorAll('.search-result[data-id]').forEach(el => {
        el.style.cursor = 'pointer';
        el.addEventListener('click', () => {
          const node = allNodes.find(n => n.id === el.dataset.id);
          if (node) {
            setSelectedNode(node);
            window.dispatchEvent(new CustomEvent('focus-node', { detail: node }));
          }
        });
      });
    } else {
      detailBody.innerHTML = '<div class="search-empty">No results found</div>';
    }
  } catch (e) {
    detailBody.innerHTML = '<div class="search-empty">Could not reach shard API</div>';
  }

  if (matches.size > 0) {
    setSearchMatches(matches);
    status.textContent = `${matches.size} match${matches.size === 1 ? '' : 'es'}`;
  } else {
    setSearchMatches(null);
    status.textContent = 'no matches';
  }
}
