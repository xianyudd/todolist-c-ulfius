async function fetchTodos() {
  const res = await fetch('/api/todos');
  return await res.json();
}

async function addTodo(text) {
  const res = await fetch('/api/todos', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text })
  });
  if (!res.ok) throw new Error('添加失败');
  return await res.json();
}

async function updateTodo(id, patch) {
  const res = await fetch(`/api/todos/${id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch)
  });
  if (!res.ok) throw new Error('更新失败');
  return await res.json();
}

async function deleteTodo(id) {
  const res = await fetch(`/api/todos/${id}`, { method: 'DELETE' });
  if (!res.ok) throw new Error('删除失败');
  return await res.json();
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => {
    if (k === 'class') {
      node.className = v;
    } else if (k === 'checked') {
      node.checked = !!v;                 // ✅ 用 DOM 属性
    } else if (k === 'value') {
      node.value = v;
    } else if (k.startsWith('on') && typeof v === 'function') {
      node.addEventListener(k.substring(2), v);
    } else {
      node.setAttribute(k, v);
    }
  });
  for (const c of children) {
    if (typeof c === 'string') node.appendChild(document.createTextNode(c));
    else if (c) node.appendChild(c);
  }
  return node;
}


async function render() {
  const list = document.getElementById('todo-list');
  list.innerHTML = '';
  const todos = await fetchTodos();
  for (const t of todos) {
    const item = el('li', { class: 'todo' },
      el('div', { class: 'left' },
        el('input', {
          type: 'checkbox',
          checked: !!t.done,                                   // ✅ 传布尔值
          onchange: async (e) => {
            await updateTodo(t.id, { done: e.target.checked }); 
            await render();                                    // 小细节：等更新完成再重渲染
          }
        }),
        el('span', { class: 'text' + (t.done ? ' done' : '') }, t.text)
      ),
      el('div', { class: 'actions' },
        el('button', {
          onclick: async () => {
            const nt = prompt('编辑待办：', t.text);
            if (nt !== null && nt.trim() !== '') {
              await updateTodo(t.id, { text: nt.trim() });
              render();
            }
          }
        }, '编辑'),
        el('button', { onclick: async () => { await deleteTodo(t.id); render(); } }, '删除')
      )
    );
    list.appendChild(item);
  }
}

document.getElementById('add-btn').addEventListener('click', async () => {
  const input = document.getElementById('todo-input');
  const txt = input.value.trim();
  if (!txt) return;
  await addTodo(txt);
  input.value = '';
  render();
});

document.getElementById('todo-input').addEventListener('keydown', async (e) => {
  if (e.key === 'Enter') {
    document.getElementById('add-btn').click();
  }
});

render();