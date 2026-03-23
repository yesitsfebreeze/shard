import { SHARD_API, extract_text, all_nodes } from './graph.js';
import { set_search_matches, set_search_open, set_selected_node } from './state.js';

const overlay = document.getElementById('search-overlay');
const input = document.getElementById('search-input');
const status = document.getElementById('search-status');
const detail_panel = document.getElementById('detail-panel');
const detail_title = document.getElementById('detail-title');
const detail_body = document.getElementById('detail-body');

let open = false;

export function init_search() {
  document.addEventListener('keydown', e => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
      if (e.key === 'Escape' && open) {
        close_search();
        e.preventDefault();
      }
      return;
    }
    if (e.code === 'Space') {
      e.preventDefault();
      if (open) { close_search(); } else { open_search(); }
    }
  });

  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') {
      e.preventDefault();
      const query = input.value.trim();
      if (query) search(query);
    }
  });

  document.addEventListener('mousedown', e => {
    if (open && !overlay.contains(e.target)) {
      close_search();
    }
  });
}

function open_search() {
  open = true;
  set_search_open(true);
  set_selected_node(null);
  overlay.classList.add('open');
  input.focus();
}

function close_search() {
  open = false;
  set_search_open(false);
  overlay.classList.remove('open');
  input.blur();
  if (!input.value.trim()) {
    set_search_matches(null);
    status.textContent = '';
    detail_panel.classList.remove('open');
  }
}

function escape_html(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function search(query) {
  status.textContent = 'asking AI...';
  detail_title.textContent = query;
  detail_body.innerHTML = '<div class="search-loading">Searching...</div>';
  detail_panel.classList.add('open');

  const matches = new Set();
  const lower_q = query.toLowerCase();
  for (const node of all_nodes) {
    if (node.label && node.label.toLowerCase().includes(lower_q)) {
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
    const text = extract_text(data);

    if (text) {
      const lines = text.split('\n').filter(l => l.trim());
      const result_html = [];

      for (const line of lines) {
        const match = line.match(/^- ([^:]+): (.+)/);
        if (match) {
          const [, id, content] = match;
          const node = all_nodes.find(n => n.id === id);
          if (node) {
            matches.add(node);
            for (const child of node.children) matches.add(child);
          }
          const parent_node = all_nodes.find(n => n.children.some(c => c.id === id));
          if (parent_node) matches.add(parent_node);

          result_html.push(`<div class="search-result" data-id="${escape_html(id)}">
            <span class="search-result-id">${escape_html(id)}</span>
            <span class="search-result-text">${escape_html(content)}</span>
          </div>`);
        } else {
          result_html.push(`<div class="search-result-line">${escape_html(line)}</div>`);
        }
      }

      detail_body.innerHTML = result_html.join('');

      detail_body.querySelectorAll('.search-result[data-id]').forEach(el => {
        el.style.cursor = 'pointer';
        el.addEventListener('click', () => {
          const node = all_nodes.find(n => n.id === el.dataset.id);
          if (node) {
            set_selected_node(node);
            window.dispatchEvent(new CustomEvent('focus-node', { detail: node }));
          }
        });
      });
    } else {
      detail_body.innerHTML = '<div class="search-empty">No results found</div>';
    }
  } catch (e) {
    detail_body.innerHTML = '<div class="search-empty">Could not reach shard API</div>';
  }

  if (matches.size > 0) {
    set_search_matches(matches);
    status.textContent = `${matches.size} match${matches.size === 1 ? '' : 'es'}`;
  } else {
    set_search_matches(null);
    status.textContent = 'no matches';
  }
}
