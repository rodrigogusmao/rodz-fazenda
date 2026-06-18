'use strict';

// ─── Tema (espelha mri:color via convar) ─────────────────────────────────────
const HEX_RE = /^#[0-9a-f]{6}$/i;

function hexToHsl(hex) {
    const r = parseInt(hex.slice(1, 3), 16) / 255;
    const g = parseInt(hex.slice(3, 5), 16) / 255;
    const b = parseInt(hex.slice(5, 7), 16) / 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    let h = 0, s = 0;
    const l = (max + min) / 2;
    if (max !== min) {
        const d = max - min;
        s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        switch (max) {
            case r: h = ((g - b) / d + (g < b ? 6 : 0)) / 6; break;
            case g: h = ((b - r) / d + 2) / 6; break;
            case b: h = ((r - g) / d + 4) / 6; break;
        }
    }
    return { h: Math.round(h * 360), s: Math.round(s * 100), l: Math.round(l * 100) };
}

function hexToRgb(hex) {
    return {
        r: parseInt(hex.slice(1, 3), 16),
        g: parseInt(hex.slice(3, 5), 16),
        b: parseInt(hex.slice(5, 7), 16),
    };
}

function applyAccentColor(hex) {
    if (!hex || !HEX_RE.test(hex)) return;
    const { h, s, l } = hexToHsl(hex);
    const { r, g, b } = hexToRgb(hex);
    const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    const isDark    = luminance < 0.5;
    const token     = `${h} ${s}% ${l}%`;
    const fgToken   = isDark ? '210 40% 98%' : '240 10% 3.9%';
    const root = document.documentElement;
    root.style.setProperty('--primary',            token);
    root.style.setProperty('--primary-foreground', fgToken);
    root.style.setProperty('--primary-rgb',        `${r}, ${g}, ${b}`);
    root.style.setProperty('--ring',               token);
}

// ─── Estado ──────────────────────────────────────────────────────────────────
let state = {
    farmId:        null,
    farmName:      null,
    farmPrice:     0,
    salePrice:     null,
    employees:     [],
    isOwner:       false,
    corrals:       [],
    animals:       {},
    cowCount:      0,
    pigCount:      0,
    milkCount:     0,
    medicineCount: 0,
    prices:        {},
    currentTab:    'overview',
    animalFilter:  'all',
};

// ─── NUI helpers ─────────────────────────────────────────────────────────────
function nuiPost(action, data = {}) {
    return fetch(`https://rodz-fazenda/${action}`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(data),
    }).catch(() => ({ json: () => Promise.resolve({}) }));
}

// ─── Notifications (via lib.notify do servidor) ───────────────────────────────
function showToast(description, type = 'inform', title = 'Fazenda') {
    nuiPost('notify', { description, type, title });
}

// ─── Tabs ─────────────────────────────────────────────────────────────────────
function switchTab(tab) {
    state.currentTab = tab;
    document.querySelectorAll('.tab-section').forEach(s => s.classList.add('hidden'));
    document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
    document.getElementById(`tab-${tab}`)?.classList.remove('hidden');
    document.querySelector(`[data-tab="${tab}"]`)?.classList.add('active');

    if (tab === 'animals')   renderAnimals();
    if (tab === 'shop')      renderShop();
    if (tab === 'sales')     renderSales();
    if (tab === 'employees') renderEmployees();
}

// ─── Visão Geral ─────────────────────────────────────────────────────────────
function renderSellSection() {
    const idle   = document.getElementById('sell-state-idle');
    const listed = document.getElementById('sell-state-listed');
    if (state.salePrice) {
        idle.classList.add('hidden');
        listed.classList.remove('hidden');
        document.getElementById('farm-sale-price-display').textContent =
            '$' + Number(state.salePrice).toLocaleString('pt-BR');
    } else {
        idle.classList.remove('hidden');
        listed.classList.add('hidden');
    }
}

function renderOverview() {
    document.getElementById('sidebar-farm-name').textContent = state.farmName || '—';
    document.getElementById('stat-cows').textContent     = state.cowCount     || 0;
    document.getElementById('stat-pigs').textContent     = state.pigCount     || 0;
    document.getElementById('stat-milk').textContent     = state.milkCount    || 0;
    document.getElementById('stat-medicine').textContent = state.medicineCount || 0;
    renderSellSection();
    renderCorrals();
}

const ROLE_LABELS = { ajudante: 'Ajudante', vaqueiro: 'Vaqueiro', capataz: 'Capataz', supervisor: 'Supervisor', gerente: 'Gerente' };
const ROLE_COLORS = { ajudante: '#94a3b8', vaqueiro: '#4ade80', capataz: '#facc15', supervisor: '#fb923c', gerente: '#f87171' };
const ROLE_OPTIONS = Object.entries(ROLE_LABELS).map(([v, l]) => `<option value="${v}">${l}</option>`).join('');

function renderEmployees() {
    const list = document.getElementById('employees-list');
    if (!list) return;
    list.innerHTML = '';

    if (!state.employees.length) {
        list.innerHTML = '<div class="empty-state">Nenhum funcionário contratado.</div>';
        return;
    }

    state.employees.forEach(emp => {
        const roleLabel = ROLE_LABELS[emp.role] || emp.role;
        const roleColor = ROLE_COLORS[emp.role] || '#94a3b8';
        const opts = Object.entries(ROLE_LABELS)
            .map(([v, l]) => `<option value="${v}"${emp.role === v ? ' selected' : ''}>${l}</option>`)
            .join('');

        const card = document.createElement('div');
        card.className = 'employee-card';
        card.innerHTML = `
            <div class="employee-main">
                <div class="employee-info">
                    <span class="employee-name">${emp.name || emp.citizenid}</span>
                    <div class="employee-meta">
                        <span class="role-badge" style="color:${roleColor}">${roleLabel}</span>
                        <span class="employee-salary">$${Number(emp.salary).toLocaleString('pt-BR')}/ciclo</span>
                    </div>
                </div>
                <div class="employee-actions">
                    <button class="emp-btn emp-edit" data-cid="${emp.citizenid}">Editar</button>
                    <button class="emp-btn emp-fire" data-cid="${emp.citizenid}">Demitir</button>
                </div>
            </div>
            <div class="employee-edit-form hidden">
                <div class="hire-row-2" style="margin-top:10px">
                    <div class="hire-field">
                        <label class="hire-label">Cargo</label>
                        <select class="form-select emp-role-select">${opts}</select>
                    </div>
                    <div class="hire-field">
                        <label class="hire-label">Salário ($)</label>
                        <input type="number" class="form-input emp-salary-input" value="${emp.salary}" min="0">
                    </div>
                </div>
                <div class="hire-actions" style="margin-top:8px">
                    <button class="emp-btn emp-save" data-cid="${emp.citizenid}">Salvar</button>
                    <button class="emp-btn emp-cancel-edit">Cancelar</button>
                </div>
            </div>`;
        list.appendChild(card);

        const editForm = card.querySelector('.employee-edit-form');

        card.querySelector('.emp-edit').addEventListener('click', () => {
            editForm.classList.toggle('hidden');
        });

        card.querySelector('.emp-cancel-edit').addEventListener('click', () => {
            editForm.classList.add('hidden');
        });

        card.querySelector('.emp-save').addEventListener('click', async (e) => {
            const cid    = e.currentTarget.dataset.cid;
            const role   = card.querySelector('.emp-role-select').value;
            const salary = parseInt(card.querySelector('.emp-salary-input').value, 10) || 0;
            e.currentTarget.disabled = true;
            const res  = await nuiPost('updateEmployee', { citizenid: cid, role, salary });
            const data = await res.json().catch(() => ({}));
            e.currentTarget.disabled = false;
            showToast(data?.msg || 'Erro.', data?.ok ? 'success' : 'error');
            if (data?.ok) {
                const idx = state.employees.findIndex(x => x.citizenid === cid);
                if (idx !== -1) { state.employees[idx].role = role; state.employees[idx].salary = salary; }
                renderEmployees();
            }
        });

        const fireBtn = card.querySelector('.emp-fire');
        fireBtn.addEventListener('click', async () => {
            const cid = fireBtn.dataset.cid;
            if (fireBtn.dataset.confirm !== '1') {
                fireBtn.dataset.confirm = '1';
                fireBtn.textContent = '⚠ Confirmar?';
                setTimeout(() => { fireBtn.dataset.confirm = ''; fireBtn.textContent = 'Demitir'; }, 3000);
                return;
            }
            fireBtn.disabled = true;
            const res  = await nuiPost('fireEmployee', { citizenid: cid });
            const data = await res.json().catch(() => ({}));
            fireBtn.disabled = false;
            showToast(data?.msg || 'Erro.', data?.ok ? 'success' : 'error');
            if (data?.ok) {
                state.employees = state.employees.filter(x => x.citizenid !== cid);
                renderEmployees();
            }
        });
    });
}

function renderCorrals() {
    const list = document.getElementById('corrals-list');
    list.innerHTML = '';

    if (!state.corrals.length) {
        list.innerHTML = '<div class="empty-state">Nenhum curral cadastrado.</div>';
        return;
    }

    state.corrals.forEach(c => {
        const pct = c.totalSlots > 0 ? Math.round((c.activeCount / c.totalSlots) * 100) : 0;
        const el = document.createElement('div');
        el.className = 'corral-card';
        el.innerHTML = `
            <div class="corral-header">
                <span class="corral-badge ${c.type === 'cow' ? 'badge-cow' : 'badge-pig'}">${c.type === 'cow' ? '🐄' : '🐷'}</span>
                <span class="corral-id">${c.label || c.id}</span>
            </div>
            <div class="corral-row"><span>Animais</span><span class="corral-val">${c.activeCount}/${c.totalSlots}</span></div>
            <div class="corral-row"><span>🌾 Ração</span><span class="corral-val">${c.feedStock}</span></div>
            <div class="corral-row"><span>💧 Água</span><span class="corral-val">${c.waterStock}</span></div>
            <div class="corral-bar-track"><div class="corral-bar-fill" style="width:${pct}%"></div></div>
        `;
        list.appendChild(el);
    });
}

// ─── Animais ──────────────────────────────────────────────────────────────────
function renderAnimals() {
    const list = document.getElementById('animals-list');
    list.innerHTML = '';

    const filter  = state.animalFilter;
    const animals = Object.values(state.animals)
        .filter(a => a && a.active && (filter === 'all' || a.type === filter));

    if (!animals.length) {
        list.innerHTML = `<div class="empty-state">Nenhum animal ativo${filter !== 'all' ? ' desse tipo' : ''}.</div>`;
        return;
    }

    animals.forEach(snap => {
        const icon       = snap.type === 'cow' ? '🐄' : '🐷';
        const sellPrice  = calcSellPrice(snap);
        const hClass     = barClass(snap.health);
        const hunClass   = barClass(snap.hunger);
        const thirClass  = barClass(snap.thirst ?? 100);

        const badges = [];
        if (snap.canMilk)                        badges.push('<span class="animal-badge badge-milkable">Ordenha disponível</span>');
        if ((snap.health ?? 100) < 40)           badges.push('<span class="animal-badge badge-sick">Doente</span>');
        else if ((snap.hunger ?? 100) < 30 || (snap.thirst ?? 100) < 30)
                                                  badges.push('<span class="animal-badge badge-hungry">Com fome/sede</span>');

        const el = document.createElement('div');
        el.className = 'animal-card';
        el.innerHTML = `
            <span class="animal-icon">${icon}</span>
            <div class="animal-body">
                <div class="animal-header">
                    <span class="animal-id">${snap.id}</span>
                    ${badges.join('')}
                    <span class="animal-age">${snap.ageDays || 0}d</span>
                </div>
                <div class="animal-bars">
                    <div class="bar-row">
                        <span class="bar-label">Saúde</span>
                        <div class="bar-track"><div class="bar-fill health ${hClass}" style="width:${snap.health ?? 100}%"></div></div>
                        <span class="bar-pct">${Math.round(snap.health ?? 100)}%</span>
                    </div>
                    <div class="bar-row">
                        <span class="bar-label">Fome</span>
                        <div class="bar-track"><div class="bar-fill hunger ${hunClass}" style="width:${snap.hunger ?? 100}%"></div></div>
                        <span class="bar-pct">${Math.round(snap.hunger ?? 100)}%</span>
                    </div>
                    <div class="bar-row">
                        <span class="bar-label">Sede</span>
                        <div class="bar-track"><div class="bar-fill thirst ${thirClass}" style="width:${snap.thirst ?? 100}%"></div></div>
                        <span class="bar-pct">${Math.round(snap.thirst ?? 100)}%</span>
                    </div>
                </div>
            </div>
            <div class="animal-price">
                <div class="animal-price-val">$${sellPrice.toLocaleString('pt-BR')}</div>
                <div class="animal-price-label">val. estimado</div>
            </div>
        `;
        list.appendChild(el);
    });
}

function calcSellPrice(snap) {
    const p = state.prices || {};
    if (snap.type === 'cow') {
        const start    = p.cowSellStart || p.cowSell || 0;
        const max      = p.cowSellMax   || start;
        const stepH    = Math.max(1, p.cowSellAgeStepHours || 24);
        const stepV    = Math.max(0, p.cowSellAgeStepValue  || 0);
        const ageHours = (snap.ageDays || 0) * 24;
        return Math.min(max, start + Math.floor(ageHours / stepH) * stepV);
    }
    if (snap.type === 'pig') {
        const base   = p.pigSell || 0;
        const steps  = Math.min(snap.ageDays || 0, 10);
        return Math.round(base * (1.0 + steps * 0.05));
    }
    return 0;
}

function barClass(pct) {
    if (pct < 30) return 'low';
    if (pct < 60) return 'medium';
    return '';
}

// ─── Loja ─────────────────────────────────────────────────────────────────────
function renderShop() {
    const p = state.prices || {};
    document.getElementById('shop-cow-price').textContent     = `$${(p.cowBuy || 0).toLocaleString('pt-BR')} / unid. (dinheiro sujo)`;
    document.getElementById('shop-pig-price').textContent     = `$${(p.pigBuy || 0).toLocaleString('pt-BR')} / unid. (dinheiro sujo)`;
    document.getElementById('shop-feed-price').textContent    = `$${(p.feedBuy || 0).toLocaleString('pt-BR')} / saco`;
    document.getElementById('shop-water-price').textContent   = `$${(p.waterBuy || 0).toLocaleString('pt-BR')} / balde`;
    document.getElementById('shop-medicine-price').textContent = `$${(p.medicineBuy || 0).toLocaleString('pt-BR')} / dose`;

    loadCorrals('cow', 'buy-cow-corral');
    loadCorrals('pig', 'buy-pig-corral');
}

async function loadCorrals(type, selectId) {
    const sel = document.getElementById(selectId);
    sel.innerHTML = '<option value="">Carregando...</option>';
    try {
        const res  = await nuiPost('getCorrals', { type });
        const data = await res.json();
        sel.innerHTML = '';
        if (data?.ok && data.corrals?.length) {
            data.corrals.forEach(c => {
                const opt    = document.createElement('option');
                opt.value    = c.value;
                opt.textContent = c.label;
                if (c.available <= 0) { opt.disabled = true; opt.textContent += ' (cheio)'; }
                sel.appendChild(opt);
            });
        } else {
            sel.innerHTML = `<option value="" disabled>${data?.msg || 'Nenhum curral disponível'}</option>`;
        }
    } catch {
        sel.innerHTML = '<option value="" disabled>Erro ao carregar</option>';
    }
}

// ─── Vendas ───────────────────────────────────────────────────────────────────
function renderSales() {
    const milk = state.milkCount || 0;
    const p    = state.prices    || {};
    document.getElementById('milk-count-text').textContent = `${milk} unidade${milk !== 1 ? 's' : ''}`;
    document.getElementById('milk-price-hint').textContent = `$${(p.milkSell || 0).toLocaleString('pt-BR')} por unidade`;
    document.getElementById('sale-cow-count').textContent  = state.cowCount || 0;
    document.getElementById('sale-pig-count').textContent  = state.pigCount || 0;
    const cInput = document.getElementById('sell-cow-qty');
    const pInput = document.getElementById('sell-pig-qty');
    if (cInput) cInput.max = state.cowCount || 1;
    if (pInput) pInput.max = state.pigCount || 1;
}

// ─── Mensagens do Lua ─────────────────────────────────────────────────────────
window.addEventListener('message', e => {
    const { type, ...data } = e.data;

    if (type === 'show') {
        if (data.accentColor) applyAccentColor(data.accentColor);

        state.farmId        = data.farmId;
        state.farmName      = data.farmName;
        state.farmPrice     = data.farmPrice     || 0;
        state.salePrice     = data.salePrice     ?? null;
        state.employees     = data.employees     || [];
        state.isOwner       = data.isOwner       ?? false;
        state.corrals       = data.corrals       || [];
        state.animals       = data.animals       || {};
        state.cowCount      = data.cowCount      || 0;
        state.pigCount      = data.pigCount      || 0;
        state.milkCount     = data.milkCount     || 0;
        state.medicineCount = data.medicineCount || 0;
        state.prices        = data.prices        || {};

        const app = document.getElementById('app');
        if (app) app.classList.remove('hidden');

        switchTab(data.tab || 'overview');
        renderOverview();
        return;
    }

    if (type === 'hide') {
        document.getElementById('app').classList.add('hidden');
        return;
    }

    if (type === 'notify') {
        nuiPost('notify', { description: data.description || '', type: data.notifyType || 'inform', title: data.title || 'Fazenda' });
        return;
    }

    if (type === 'updateAnimals') {
        state.animals  = data.animals  ?? state.animals;
        state.cowCount = data.cowCount ?? state.cowCount;
        state.pigCount = data.pigCount ?? state.pigCount;
        renderOverview();
        if (state.currentTab === 'animals') renderAnimals();
        if (state.currentTab === 'sales')   renderSales();
        return;
    }

    if (type === 'switchTab') {
        switchTab(data.tab || 'overview');
        return;
    }

});

// ─── Event Listeners ──────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {

    // Tabs
    document.querySelectorAll('.nav-btn').forEach(btn => {
        btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    // Fechar
    document.getElementById('close-btn').addEventListener('click', () => nuiPost('closeMenu'));
    document.addEventListener('keydown', e => { if (e.key === 'Escape') nuiPost('closeMenu'); });

    // Animal filter
    document.querySelectorAll('.filter-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            state.animalFilter = btn.dataset.filter;
            renderAnimals();
        });
    });

    // ── Comprar Vaca ──
    document.getElementById('btn-buy-cow').addEventListener('click', async () => {
        const qty      = Math.max(1, parseInt(document.getElementById('buy-cow-qty').value) || 1);
        const corralId = document.getElementById('buy-cow-corral').value;
        if (!corralId) { showToast('Selecione um curral de destino.', 'error'); return; }
        const btn = document.getElementById('btn-buy-cow');
        btn.disabled = true;
        const res  = await nuiPost('buyAnimal', { type: 'cow', qty, corralId });
        const data = await res.json().catch(() => ({}));
        btn.disabled = false;
        if (!data) return;
        showToast(data.msg || '', data.ok ? 'success' : 'error');
        if (data.ok) {
            if (data.animals)  state.animals  = data.animals;
            if (data.cowCount !== undefined) state.cowCount = data.cowCount;
            renderOverview();
            loadCorrals('cow', 'buy-cow-corral');
        }
    });

    // ── Comprar Porco ──
    document.getElementById('btn-buy-pig').addEventListener('click', async () => {
        const qty      = Math.max(1, parseInt(document.getElementById('buy-pig-qty').value) || 1);
        const corralId = document.getElementById('buy-pig-corral').value;
        if (!corralId) { showToast('Selecione um curral de destino.', 'error'); return; }
        const btn = document.getElementById('btn-buy-pig');
        btn.disabled = true;
        const res  = await nuiPost('buyAnimal', { type: 'pig', qty, corralId });
        const data = await res.json().catch(() => ({}));
        btn.disabled = false;
        if (!data) return;
        showToast(data.msg || '', data.ok ? 'success' : 'error');
        if (data.ok) {
            if (data.animals)  state.animals  = data.animals;
            if (data.pigCount !== undefined) state.pigCount = data.pigCount;
            renderOverview();
            loadCorrals('pig', 'buy-pig-corral');
        }
    });

    // ── Comprar Insumos ──
    async function buySupply(action, inputId, btnId) {
        const qty = Math.max(1, parseInt(document.getElementById(inputId).value) || 1);
        const btn = document.getElementById(btnId);
        btn.disabled = true;
        const res  = await nuiPost(action, { qty });
        const data = await res.json().catch(() => ({}));
        btn.disabled = false;
        if (data?.msg) showToast(data.msg, data.ok ? 'success' : 'error');
    }

    document.getElementById('btn-buy-feed').addEventListener('click',     () => buySupply('buyFeed',     'buy-feed-qty',     'btn-buy-feed'));
    document.getElementById('btn-buy-water').addEventListener('click',    () => buySupply('buyWater',    'buy-water-qty',    'btn-buy-water'));
    document.getElementById('btn-buy-medicine').addEventListener('click', () => buySupply('buyMedicine', 'buy-medicine-qty', 'btn-buy-medicine'));

    // ── Vender Leite ──
    document.getElementById('btn-sell-milk').addEventListener('click', async () => {
        if (!state.isOwner) { showToast('Apenas o dono da fazenda pode vender leite.', 'error'); return; }
        if ((state.milkCount || 0) <= 0) { showToast('Você não tem leite para vender.', 'error'); return; }
        const btn = document.getElementById('btn-sell-milk');
        btn.disabled = true;
        const res  = await nuiPost('sellMilk', {});
        const data = await res.json().catch(() => ({}));
        btn.disabled = false;
        if (!data) return;
        showToast(data.msg || '', data.ok ? 'success' : 'error');
        if (data.ok) {
            state.milkCount = 0;
            renderOverview();
            renderSales();
        }
    });

    // ── Vender Vacas via Caminhão ──
    document.getElementById('btn-sell-cows').addEventListener('click', async () => {
        const qty = Math.max(1, parseInt(document.getElementById('sell-cow-qty').value) || 1);
        if ((state.cowCount || 0) <= 0) { showToast('Sem vacas disponíveis para vender.', 'error'); return; }
        const btn = document.getElementById('btn-sell-cows');
        btn.disabled = true;
        const res  = await nuiPost('requestTruck', { type: 'cow', qty });
        const data = await res.json().catch(() => ({}));
        btn.disabled = false;
        if (data && !data.ok && data.msg) showToast(data.msg, 'error');
    });

    // ── Vender Porcos via Caminhão ──
    document.getElementById('btn-sell-pigs').addEventListener('click', async () => {
        const qty = Math.max(1, parseInt(document.getElementById('sell-pig-qty').value) || 1);
        if ((state.pigCount || 0) <= 0) { showToast('Sem porcos disponíveis para vender.', 'error'); return; }
        const btn = document.getElementById('btn-sell-pigs');
        btn.disabled = true;
        const res  = await nuiPost('requestTruck', { type: 'pig', qty });
        const data = await res.json().catch(() => ({}));
        btn.disabled = false;
        if (data && !data.ok && data.msg) showToast(data.msg, 'error');
    });

    // ── Contratar funcionário ──
    document.getElementById('btn-toggle-hire').addEventListener('click', () => {
        document.getElementById('hire-form').classList.toggle('hidden');
    });
    document.getElementById('btn-hire-cancel').addEventListener('click', () => {
        document.getElementById('hire-form').classList.add('hidden');
    });
    document.getElementById('btn-hire-confirm').addEventListener('click', async () => {
        const target = document.getElementById('hire-target').value.trim();
        const role   = document.getElementById('hire-role').value;
        const salary = parseInt(document.getElementById('hire-salary').value, 10) || 0;
        if (!target) { showToast('Informe o ID ou Citizenid do jogador.', 'error'); return; }
        const btn = document.getElementById('btn-hire-confirm');
        btn.disabled    = true;
        btn.textContent = 'Contratando...';
        const res  = await nuiPost('hireEmployee', { target, role, salary });
        const data = await res.json().catch(() => ({}));
        btn.disabled    = false;
        btn.textContent = 'Confirmar';
        showToast(data?.msg || 'Erro.', data?.ok ? 'success' : 'error');
        if (data?.ok && data.employee) {
            state.employees.push(data.employee);
            document.getElementById('hire-target').value  = '';
            document.getElementById('hire-salary').value  = '';
            document.getElementById('hire-form').classList.add('hidden');
            renderEmployees();
        }
    });

    // ── Listar fazenda para venda ──
    document.getElementById('btn-list-farm').addEventListener('click', async () => {
        const input = document.getElementById('farm-sale-price-input');
        const price = parseInt(input.value, 10);
        if (!price || price <= 0) {
            showToast('Informe um preço válido.', 'error');
            return;
        }
        const btn = document.getElementById('btn-list-farm');
        btn.disabled    = true;
        btn.textContent = 'Listando...';
        const res  = await nuiPost('listFarmForSale', { price });
        const data = await res.json().catch(() => ({}));
        btn.disabled    = false;
        btn.textContent = 'Listar';
        showToast(data?.msg || 'Erro.', data?.ok ? 'success' : 'error');
        if (data?.ok) {
            state.salePrice = price;
            input.value = '';
            renderSellSection();
        }
    });

    // ── Cancelar listagem ──
    document.getElementById('btn-cancel-listing').addEventListener('click', async () => {
        const btn = document.getElementById('btn-cancel-listing');
        btn.disabled    = true;
        btn.textContent = 'Cancelando...';
        const res  = await nuiPost('cancelFarmListing', {});
        const data = await res.json().catch(() => ({}));
        btn.disabled    = false;
        btn.textContent = 'Cancelar';
        showToast(data?.msg || 'Erro.', data?.ok ? 'success' : 'error');
        if (data?.ok) {
            state.salePrice = null;
            renderSellSection();
        }
    });
});
