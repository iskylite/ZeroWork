/* Shared editable connection chrome; protocol providers own their draft and validation. */
(() => {
  const labels = ['连接与认证', '连接路径', '核对与测试'];
  const monitor = '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M12 17v4m-4 0h8"/>';
  const terminal = '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3m6 0h4"/>';
  window.V3ConnectionWizard = {
    header(modal, protocols, current, change) {
      const heading = modal.querySelector('.modal-head h2');
      const wrap = document.createElement('span');
      wrap.className = 'protocol-header';
      const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      icon.setAttribute('viewBox', '0 0 24 24');
      icon.setAttribute('aria-hidden', 'true');
      icon.innerHTML = current.toLowerCase() === 'kvm' ? monitor : terminal;
      wrap.append(icon);
      const select = document.createElement('select');
      select.id = 'connection-protocol';
      select.setAttribute('aria-label', '连接类型');
      for (const value of protocols) select.add(new Option(value.toLowerCase() === 'kvm' ? 'BMC · iKVM' : value.toUpperCase(), value));
      select.value = current;
      select.addEventListener('change', () => change(select.value));
      wrap.append(select);
      heading.after(wrap);
      return select;
    },
    steps(container, step, furthest, change) {
      container.classList.add('connection-steps');
      container.replaceChildren();
      labels.forEach((label, index) => {
        if (index) {
          const line = document.createElement('span');
          line.className = 'step-connector';
          line.setAttribute('aria-hidden', 'true');
          container.append(line);
        }
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'connection-step';
        button.classList.toggle('active', index === step);
        button.classList.toggle('complete', index < step);
        button.disabled = index > furthest;
        if (index === step) button.setAttribute('aria-current', 'step');
        button.innerHTML = `<span class="step-number">${index < step ? '✓' : index + 1}</span><span>${label}</span>`;
        button.addEventListener('click', () => change(index));
        container.append(button);
      });
    }
  };
})();
